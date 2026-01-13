import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:toeic_master_front/core/api.dart';
import 'package:toeic_master_front/core/api_client.dart';
import 'package:toeic_master_front/core/token_storage.dart';
import 'package:dio/dio.dart';

import 'package:image_picker/image_picker.dart';

/// ====== Models ======
class School {
  final int id;
  final String name;
  final String address;
  final double latitude;
  final double longitude;
  final double avgRating;
  final int reviewCount;

  const School({
    required this.id,
    required this.name,
    required this.address,
    required this.latitude,
    required this.longitude,
    required this.avgRating,
    required this.reviewCount,
  });

  factory School.fromJson(Map<String, dynamic> json) {
    return School(
      id: (json['id'] as num).toInt(),
      name: (json['name'] ?? '') as String,
      address: (json['address'] ?? '') as String,
      latitude: (json['latitude'] as num).toDouble(),
      longitude: (json['longitude'] as num).toDouble(),
      avgRating: (json['avgRating'] as num?)?.toDouble() ?? 0.0,
      reviewCount: (json['reviewCount'] as num?)?.toInt() ?? 0,
    );
  }
}

class ReviewItem {
  final int id;
  final String authorNickname;
  final bool recommended; // 추천/비추천
  final bool facilityGood; // 시설 좋아요/별로예요
  final bool quiet; // 조용해요/시끄러워요
  final bool accessible; // 자가용/대중교통
  final int rating;
  final String content;
  final int likeCount;
  final List<String> imageUrls;
  final bool liked;

  const ReviewItem({
    required this.id,
    required this.authorNickname,
    required this.recommended,
    required this.facilityGood,
    required this.quiet,
    required this.accessible,
    required this.rating,
    required this.content,
    required this.likeCount,
    required this.imageUrls,
    required this.liked,
  });

  factory ReviewItem.fromJson(Map<String, dynamic> json) {
    final images = (json['images'] as List<dynamic>?) ?? const [];
    final urls = <String>[];
    for (final e in images) {
      final m = e as Map<String, dynamic>;
      final u = m['imageUrl'] as String?;
      if (u != null && u.isNotEmpty) urls.add(u);
    }

    return ReviewItem(
      id: (json['id'] as num?)?.toInt() ?? 0,
      authorNickname: (json['authorNickname'] ?? '') as String,
      recommended: (json['recommended'] ?? false) as bool,
      facilityGood: (json['facilityGood'] ?? false) as bool,
      quiet: (json['quiet'] ?? false) as bool,
      accessible: (json['accessible'] ?? false) as bool,
      rating: (json['rating'] as num?)?.toInt() ?? 0,
      content: (json['content'] ?? '') as String,
      likeCount: (json['likeCount'] as num?)?.toInt() ?? 0,
      imageUrls: urls,
      liked: (json['liked'] ?? false) as bool,

    );
  }
}

/// ====== Page ======
class TestCenterPage extends StatefulWidget {
  final ValueNotifier<int> scoreNotifier;

  const TestCenterPage({super.key, required this.scoreNotifier,});

  @override
  State<TestCenterPage> createState() => _TestCenterPageState();
}

class _TestCenterPageState extends State<TestCenterPage> {
  final Map<int, bool> _likedByMe = {};      // reviewId -> liked
  final Map<int, int> _likeCountById = {};   // reviewId -> likeCount

  late final ApiClient _apiClient;
  late final Api _api;

  NaverMapController? _mapController;

  final FocusNode _searchFocusNode = FocusNode();
  Timer? _debounce;

  int _restoreToken = 0;
  bool _isRestoringAll = false;

  // 자동완성 후보(전체 학교 캐시) + 현재 추천 목록
  List<School> _allSchoolsCache = [];
  List<School> _suggestions = [];
  bool _showSuggestions = false;

  final TextEditingController _searchController = TextEditingController();

  bool _isMovingToMyLocation = false;
  bool _isLoadingSchools = false;
  bool _isSchoolSheetOpen = false;

  List<School> _schools = [];
  final Map<int, NMarker> _schoolMarkers = {}; // schoolId -> marker

  Position? _myPosition;

  String? _myNickname;

  // ===== AI 추천 고사장 =====
  List<School> _aiRecommendedSchools = [];
  bool _isLoadingAiSchools = false;

  Future<void> _loadAiRecommendedSchools() async {
    setState(() => _isLoadingAiSchools = true);
    try {
      final res = await _apiClient.dio.get(
        '/api/schools/recommendations',
        queryParameters: {'topK': 2},
      );

      debugPrint('추천 응답 raw: ${res.data}');

      final decoded = res.data as Map<String, dynamic>;
      final data = decoded['data'] as List<dynamic>? ?? [];

      final list = data
          .map((e) => School.fromJson(e as Map<String, dynamic>))
          .toList();

      debugPrint('추천 파싱 결과 length=${list.length}');

      if (!mounted) return;
      setState(() => _aiRecommendedSchools = list);
    } catch (e) {
      debugPrint('AI 고사장 추천 실패: $e');
    } finally {
      if (mounted) setState(() => _isLoadingAiSchools = false);
    }
  }

  Future<void> _likeReview(int reviewId) async {
    await _apiClient.dio.post('/api/reviews/$reviewId/like');
  }

  Future<void> _unlikeReview(int reviewId) async {
    await _apiClient.dio.delete('/api/reviews/$reviewId/like');
  }

  Future<void> _refreshScore() async {
    try {
      // ✅ 서버에서 최신 score 다시 받아오기
      final res = await _apiClient.dio.get('/api/users/me');
      final decoded = res.data as Map<String, dynamic>;
      final data = decoded['data'];

      int? total;
      if (data is Map<String, dynamic>) {
        final v = data['score']; // 백엔드 필드명이 score라고 가정 (StudyPage도 score 쓰는 흐름)
        if (v is num) total = v.toInt();
      }

      if (total != null) {
        widget.scoreNotifier.value = total; // ✅ 즉시 반영
      }
    } catch (e) {
      // 실패해도 기능엔 영향 없게 조용히
      debugPrint('점수 새로고침 실패: $e');
    }
  }

  void _closeSchoolSheetIfOpen() {
    if (_isSchoolSheetOpen) {
      _isSchoolSheetOpen = false; // ✅ 중요: 닫기 전에 먼저 내려줘야 재오픈 가드에 안 걸림
      Navigator.of(context).pop();
    }
  }

  @override
  void initState() {
    super.initState();
    _apiClient = ApiClient(TokenStorage());
    _api = Api(_apiClient);

    _loadMyPositionSilently();
    _loadMyNicknameSilently();

    _loadAiRecommendedSchools();

    _searchController.addListener(_onSearchTextControllerChanged);

    _searchFocusNode.addListener(() {
      if (!_searchFocusNode.hasFocus) {
        setState(() => _showSuggestions = false);
      } else {
        // 포커스 얻으면 현재 텍스트 기준으로 다시 후보 표시
        _updateSuggestions(_searchController.text);
      }
    });
  }

  Future<void> _restoreAllSchoolsIfNeeded() async {
    // 이미 전체 상태면 굳이 다시 안 해도 되지만, 안전하게 적용해도 OK
    setState(() {
      _showSuggestions = false;
    });

    // 캐시가 있으면 캐시로 즉시 복구 (서버 호출 X)
    if (_allSchoolsCache.isNotEmpty) {
      await _applySchoolsToMap(_allSchoolsCache);
      return;
    }

    // 캐시가 없다면 서버에서 다시 받아오기
    setState(() => _isLoadingSchools = true);
    try {
      final schools = await _fetchAllSchools();
      if (!mounted) return;
      _allSchoolsCache = schools;
      await _applySchoolsToMap(schools);
    } finally {
      if (mounted) setState(() => _isLoadingSchools = false);
    }
  }

  Future<void> _loadMyNicknameSilently() async {
    try {
      final res = await _apiClient.dio.get('/api/users/me');
      final decoded = res.data as Map<String, dynamic>;
      final data = decoded['data'];

      String? nickname;
      if (data is Map<String, dynamic>) {
        nickname = (data['nickname'] ?? data['name'] ?? data['userNickname']) as String?;
      }

      if (!mounted) return;
      setState(() => _myNickname = nickname);
    } catch (_) {
      // 로그인 안 했거나 /me 엔드포인트 없으면 null로 둠
    }
  }


  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(_onSearchTextControllerChanged); // ✅ 추가
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  /// ====== 위치 로드 ======
  Future<void> _loadMyPositionSilently() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (!mounted) return;
      setState(() => _myPosition = pos);
    } catch (_) {
      // ignore
    }
  }

  Future<void> _performSearch(String keyword) async {
    final q = keyword.trim();
    if (q.isEmpty) return;

    setState(() {
      _isLoadingSchools = true;
      _showSuggestions = false;
    });

    try {
      final schools = await _searchSchoolsByName(q);
      if (!mounted) return;
      await _applySchoolsToMap(schools);

      if (schools.isNotEmpty && _mapController != null) {
        await _mapController!.updateCamera(
          NCameraUpdate.scrollAndZoomTo(
            target: NLatLng(schools.first.latitude, schools.first.longitude),
            zoom: 14,
          ),
        );
      }
    } catch (e) {
      _showSnack('검색 실패: $e');
    } finally {
      if (mounted) setState(() => _isLoadingSchools = false);
    }
  }

  void _onSearchTextControllerChanged() {
    final q = _searchController.text.trim();

    // ✅ 텍스트가 비면 AI 추천을 다시 보여주기 위해 리빌드
    if (q.isEmpty) {
      // 추천 리스트 숨기고
      if (_showSuggestions) {
        setState(() => _showSuggestions = false);
      } else {
        setState(() {}); // ✅ 그냥 리빌드
      }
    }
  }

  void _updateSuggestions(String raw) {
    final q = raw.trim();
    if (q.isEmpty) {
      setState(() {
        _suggestions = [];
        _showSuggestions = false;
      });
      return;
    }

    final list = _allSchoolsCache
        .where((s) => s.name.contains(q)) // ✅ "문" 포함이면 다 뜸
        .take(8) // 너무 길면 UI 부담 → 8개 정도만
        .toList();

    setState(() {
      _suggestions = list;
      _showSuggestions = list.isNotEmpty && _searchFocusNode.hasFocus;
    });
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 180), () {
      if (!mounted) return;
      _updateSuggestions(text);
    });
  }


  /// ====== API: 전체 학교 ======
  Future<List<School>> _fetchAllSchools() async {
    final res = await _apiClient.dio.get('/api/schools');
    final data = (res.data as Map<String, dynamic>)['data'] as List<dynamic>? ?? [];
    return data.map((e) => School.fromJson(e as Map<String, dynamic>)).toList();
  }


  /// ====== API: 학교 검색 ======
  Future<List<School>> _searchSchoolsByName(String name) async {
    final res = await _apiClient.dio.get(
      '/api/schools/search',
      queryParameters: {'name': name},
    );
    final data = (res.data as Map<String, dynamic>)['data'] as List<dynamic>? ?? [];
    return data.map((e) => School.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// ====== API: 주변 학교 ======
  Future<List<School>> _fetchNearbySchools({
    required double lat,
    required double lng,
  }) async {
    final res = await _apiClient.dio.get(
      '/api/schools/nearby',
      queryParameters: {'lat': lat, 'lng': lng},
    );
    final data = (res.data as Map<String, dynamic>)['data'] as List<dynamic>? ?? [];
    return data.map((e) => School.fromJson(e as Map<String, dynamic>)).toList();
  }

  /// ====== API: 리뷰 목록 ======
  Future<List<ReviewItem>> _fetchReviewsForSchool(int schoolId) async {
    final res = await _apiClient.dio.get(
      '/api/schools/$schoolId/reviews',
      queryParameters: {
        'page': 0,
        'size': 50,
        'sort': 'createdAt,desc',
      },
    );

    final decoded = res.data as Map<String, dynamic>;
    final data = decoded['data'];

    List<dynamic> list;
    if (data is List) {
      list = data;
    } else if (data is Map<String, dynamic>) {
      if (data['content'] is List) {
        list = data['content'] as List<dynamic>;
      } else if (data['data'] is List) {
        list = data['data'] as List<dynamic>;
      } else {
        list = const [];
      }
    } else {
      list = const [];
    }

    return list.map((e) => ReviewItem.fromJson(e as Map<String, dynamic>)).toList();
  }


  /// ====== API: 리뷰 작성 ======
  Future<int> _createReview({
    required int schoolId,
    required int rating,
    required String content,
    required bool recommended,
    required bool facilityGood,
    required bool quiet,
    required bool accessible,
  }) async {
    final body = {
      'rating': rating,
      'content': content,
      'recommended': recommended,
      'facilityGood': facilityGood,
      'quiet': quiet,
      'accessible': accessible,
    };

    final res = await _apiClient.dio.post(
      '/api/schools/$schoolId/reviews',
      data: body,
    );

    final decoded = res.data as Map<String, dynamic>;
    final data = decoded['data'];

    if (data is Map<String, dynamic>) {
      final idNum = data['id'] as num?;
      if (idNum != null) return idNum.toInt();
    }

    throw Exception('리뷰 작성 응답에서 reviewId를 찾을 수 없음');
  }

  /// ====== API: 리뷰 수정 ======
  Future<void> _updateReview({
    required int reviewId,
    required int rating,
    required String content,
    required bool recommended,
    required bool facilityGood,
    required bool quiet,
    required bool accessible,
  }) async {
    final body = {
      'rating': rating,
      'content': content,
      'recommended': recommended,
      'facilityGood': facilityGood,
      'quiet': quiet,
      'accessible': accessible,
    };

    await _apiClient.dio.put(
      '/api/reviews/$reviewId',
      data: body,
    );
  }

  Future<bool?> _showAlreadyReviewedDialog() async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('알림'),
          content: const Text('이미 리뷰를 작성한 장소입니다.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('닫기'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF5E9B4B),
                foregroundColor: Colors.white,
              ),
              child: const Text('수정하기'),
            ),
          ],
        );
      },
    );
  }

  Future<bool?> _showEditReviewDialog({
    required School school,
    required ReviewItem review,
  }) async {
    bool recommended = review.recommended;
    bool facilityGood = review.facilityGood;
    bool quiet = review.quiet;
    bool accessible = review.accessible;
    String? contentError;

    File? pickedImage;
    String contentText = review.content;

    bool submitting = false;

    Future<void> pickImage(StateSetter setStateDialog) async {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(source: ImageSource.gallery);
      if (xfile == null) return;
      setStateDialog(() => pickedImage = File(xfile.path));
    }

    return await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setStateDialog) {
            return Dialog(
              insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
              backgroundColor: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF8DBB6A), width: 1),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('리뷰 수정', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 14),

                      const Text('이 고사장을 추천하나요?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _toggleButton(
                            label: '추천',
                            selected: recommended == true,
                            onTap: submitting ? () {} : () => setStateDialog(() => recommended = true),
                          ),
                          const SizedBox(width: 10),
                          _toggleButton(
                            label: '비추천',
                            selected: recommended == false,
                            onTap: submitting ? () {} : () => setStateDialog(() => recommended = false),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      const Text('시험장 시설은 어땠나요?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _toggleButton(
                            label: '좋아요',
                            selected: facilityGood == true,
                            onTap: submitting ? () {} : () => setStateDialog(() => facilityGood = true),
                          ),
                          const SizedBox(width: 10),
                          _toggleButton(
                            label: '별로예요',
                            selected: facilityGood == false,
                            onTap: submitting ? () {} : () => setStateDialog(() => facilityGood = false),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      const Text('전체적으로 조용한 환경인가요?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _toggleButton(
                            label: '조용해요',
                            selected: quiet == true,
                            onTap: submitting ? () {} : () => setStateDialog(() => quiet = true),
                          ),
                          const SizedBox(width: 10),
                          _toggleButton(
                            label: '시끄러워요',
                            selected: quiet == false,
                            onTap: submitting ? () {} : () => setStateDialog(() => quiet = false),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      const Text('교통은 어떤가요?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Column(
                        children: [
                          _toggleButton(
                            label: '자가용도 괜찮아요',
                            selected: accessible == true,
                            onTap: submitting ? () {} : () => setStateDialog(() => accessible = true),
                          ),
                          const SizedBox(width: 10),
                          _toggleButton(
                            label: '대중교통을 추천해요',
                            selected: accessible == false,
                            onTap: submitting ? () {} : () => setStateDialog(() => accessible = false),
                          ),
                        ],
                      ),

                      const SizedBox(height: 18),

                      const Text('사진 업로드(선택)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          ElevatedButton(
                            onPressed: submitting ? null : () => pickImage(setStateDialog),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.grey[200],
                              foregroundColor: Colors.black87,
                              elevation: 0,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            child: const Text('파일 선택'),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              pickedImage == null ? '선택한 파일이 없습니다' : pickedImage!.path.split('/').last,
                              style: const TextStyle(color: Colors.black54),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (pickedImage != null) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: '선택 취소',
                              onPressed: submitting ? null : () => setStateDialog(() => pickedImage = null),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ],
                      ),

                      const SizedBox(height: 18),

                      const Text('리뷰 내용', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      TextField(
                        minLines: 4,
                        maxLines: 6,
                        enabled: !submitting,
                        controller: TextEditingController(text: contentText),
                        onChanged: (v) => contentText = v,
                        decoration: InputDecoration(
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),

                      const SizedBox(height: 18),

                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: submitting ? null : () => Navigator.pop(dialogContext, false),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.black87,
                                side: const BorderSide(color: Colors.black26),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                              ),
                              child: const Text('취소', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: submitting
                                  ? null
                                  : () async {
                                final text = contentText.trim();
                                if (text.isEmpty) {
                                  setStateDialog(() => contentError = '글을 작성하세요'); // ✅ 여기
                                  return;
                                }

                                setStateDialog(() => submitting = true);

                                try {
                                  final rating = recommended ? 5 : 1;

                                  await _updateReview(
                                    reviewId: review.id,
                                    rating: rating,
                                    content: text,
                                    recommended: recommended,
                                    facilityGood: facilityGood,
                                    quiet: quiet,
                                    accessible: accessible,
                                  );

                                  if (pickedImage != null) {
                                    await _uploadReviewImage(reviewId: review.id, imageFile: pickedImage!);
                                  }

                                  await _refreshScore(); // ✅ 리뷰 수정 직후도 반영(만약 점수 정책이 있으면)

                                  if (!mounted) return;
                                  Navigator.pop(dialogContext, true);
                                } catch (e) {
                                  _showSnack('수정 실패: $e');
                                  if (mounted) setStateDialog(() => submitting = false);
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF5E9B4B),
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                              ),
                              child: submitting
                                  ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                                  : const Text('수정하기', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// ====== API: 리뷰 이미지 업로드 (multipart) ======
  Future<void> _uploadReviewImage({
    required int reviewId,
    required File imageFile,
  }) async {
    final formData = FormData.fromMap({
      'files': [
        await MultipartFile.fromFile(
          imageFile.path,
          filename: imageFile.path.split('/').last,
        ),
      ],
    });

    await _apiClient.dio.post(
      '/api/reviews/$reviewId/images',
      data: formData,
      options: Options(
        headers: {Headers.contentTypeHeader: null}, // boundary 자동
      ),
    );
  }

  /// ====== (4)+(5) 합쳐서: 리뷰 작성 + 이미지 업로드 ======
  Future<void> _submitReview({
    required int schoolId,
    required bool recommended,
    required bool facilityGood,
    required bool quiet,
    required bool accessible,
    required String content,
    File? imageFile,
  }) async {
    final rating = recommended ? 5 : 1;

    final reviewId = await _createReview(
      schoolId: schoolId,
      rating: rating,
      content: content,
      recommended: recommended,
      facilityGood: facilityGood,
      quiet: quiet,
      accessible: accessible,
    );

    if (imageFile != null) {
      await _uploadReviewImage(reviewId: reviewId, imageFile: imageFile);
    }
  }

  /// ====== 지도/마커 적용 ======
  Future<void> _applySchoolsToMap(List<School> schools) async {
    if (_mapController == null) return;

    for (final m in _schoolMarkers.values) {
      try {
        await _mapController!.deleteOverlay(m.info);
      } catch (_) {}
    }
    _schoolMarkers.clear();

    setState(() => _schools = schools);

    for (final s in schools) {
      final marker = NMarker(
        id: 'school_${s.id}',
        position: NLatLng(s.latitude, s.longitude),
      );

      marker.setOnTapListener((overlay) async {
        await _onSchoolMarkerTapped(s);
      });

      await _mapController!.addOverlay(marker);
      _schoolMarkers[s.id] = marker;
    }
  }

  Future<void> _loadSchoolsAndPlaceMarkers() async {
    if (_mapController == null) return;

    setState(() => _isLoadingSchools = true);
    try {
      final schools = await _fetchAllSchools();
      if (!mounted) return;

      // ✅ 자동완성용 전체 학교 캐시 저장
      _allSchoolsCache = schools;

      await _applySchoolsToMap(schools);
    } finally {
      if (mounted) setState(() => _isLoadingSchools = false);
    }
  }

  Future<void> _onSchoolMarkerTapped(School school) async {
    try {
      final reviews = await _fetchReviewsForSchool(school.id);
      if (!mounted) return;
      _showSchoolBottomSheet(school: school, reviews: reviews);
    } catch (e) {
      _showSnack('리뷰 불러오기 실패: $e');
    }
  }

  /// ====== UI ======
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [

          NaverMap(
            options: const NaverMapViewOptions(
              initialCameraPosition: NCameraPosition(
                target: NLatLng(36.3504, 127.3845),
                zoom: 12,
              ),
            ),
            onMapReady: (controller) async {
              _mapController = controller;
              await _loadSchoolsAndPlaceMarkers();
            },
          ),

          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: _buildSearchBar(),
            ),
          ),

          if (_isLoadingSchools)
            const Positioned(
              top: 120,
              left: 0,
              right: 0,
              child: Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              ),
            ),
        ],
      ),

      floatingActionButton: FloatingActionButton(
        onPressed: _isMovingToMyLocation ? null : _moveToMyLocation,
        backgroundColor: Colors.white,
        child: _isMovingToMyLocation
            ? const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
            : const Icon(Icons.location_on, color: Colors.green),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          elevation: 2,
          borderRadius: BorderRadius.circular(14),
          child: TextField(
            focusNode: _searchFocusNode,
            controller: _searchController,
            decoration: InputDecoration(
              hintText: '고사장 검색',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  // ✅ 1) 혹시 남아있는 debounce 취소
                  _debounce?.cancel();

                  // ✅ 2) 텍스트/추천 UI 초기화
                  _searchController.clear();
                  _updateSuggestions('');
                  setState(() => _showSuggestions = false);

                  // ✅ 3) 포커스 복구 (이게 중요!)
                  FocusScope.of(context).requestFocus(_searchFocusNode);

                  // ✅ 4) 전체 학교 복구는 "스케줄링"만
                  _scheduleRestoreAllSchools();
                },
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: Colors.white.withOpacity(0.95),
            ),
            onChanged: (text) async {
              setState(() {}); // suffixIcon 반영

              final q = text.trim();

              // ✅ 글자가 완전히 비면 "전체 학교"로 복구
              if (q.isEmpty) {
                _debounce?.cancel();      // 추천 debounce 중이면 취소
                _updateSuggestions('');   // 추천 목록 숨김
                _scheduleRestoreAllSchools();
                return;
              }

              // ✅ 글자가 있으면 자동완성만 갱신 (검색은 엔터/탭으로만)
              _onSearchChanged(text);
            },
            onSubmitted: (q) async {
              await _performSearch(q);
            },
          ),
        ),

        // ✅ 검색어 없을 때만 AI 추천 고사장 표시
        if (_searchController.text.isEmpty)
          _buildAiSchoolRecommendationSection(),

        // ✅ 검색 도우미(자동완성) 목록
        if (_showSuggestions)
          Container(
            margin: const EdgeInsets.only(top: 8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.97),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.black12),
              boxShadow: const [
                BoxShadow(
                  blurRadius: 10,
                  spreadRadius: 0,
                  offset: Offset(0, 6),
                  color: Color(0x22000000),
                )
              ],
            ),
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView.separated(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              itemCount: _suggestions.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final s = _suggestions[i];
                return ListTile(
                  dense: true,
                  title: Text(
                    s.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    _guessRegionFromAddress(s.address),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () async {
                    // ✅ 추천창 먼저 닫기
                    setState(() => _showSuggestions = false);

                    // ✅ 텍스트 반영
                    _searchController.text = s.name;
                    _searchController.selection = TextSelection.fromPosition(
                      TextPosition(offset: _searchController.text.length),
                    );

                    // ✅ 키보드 닫기
                    FocusScope.of(context).unfocus();

                    await _performSearch(s.name);
                  },
                );
              },
            ),
          ),
      ],
    );
  }

  Future<void> _moveToMyLocation() async {
    if (_mapController == null) return;

    setState(() => _isMovingToMyLocation = true);

    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        _showSnack('위치 서비스가 꺼져있습니다. 켜주세요.');
        return;
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied) {
        _showSnack('위치 권한이 거부되었습니다.');
        return;
      }
      if (permission == LocationPermission.deniedForever) {
        _showSnack('설정에서 위치 권한을 허용해주세요.');
        await Geolocator.openAppSettings();
        return;
      }

      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      if (!mounted) return;

      setState(() => _myPosition = pos);

      final myLatLng = NLatLng(pos.latitude, pos.longitude);
      await _mapController!.updateCamera(
        NCameraUpdate.scrollAndZoomTo(
          target: myLatLng,
          zoom: 15,
        ),
      );

      setState(() => _isLoadingSchools = true);
      try {
        final nearby = await _fetchNearbySchools(
          lat: pos.latitude,
          lng: pos.longitude,
        );
        if (!mounted) return;
        await _applySchoolsToMap(nearby);
      } finally {
        if (mounted) setState(() => _isLoadingSchools = false);
      }
    } catch (e) {
      _showSnack('내 위치로 이동 실패: $e');
    } finally {
      if (mounted) setState(() => _isMovingToMyLocation = false);
    }
  }

  void _scheduleRestoreAllSchools() {
    final token = ++_restoreToken;

    // 이미 복구 중이면 굳이 또 안 돌려도 됨
    if (_isRestoringAll) return;

    // 다음 프레임에 실행 (입력 처리 먼저 끝내기)
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // 실행 시점에 다시 텍스트가 생겼으면 취소
      if (!mounted) return;
      if (_searchController.text.trim().isNotEmpty) return;
      if (token != _restoreToken) return;

      _isRestoringAll = true;
      try {
        await _restoreAllSchoolsIfNeeded();
      } finally {
        _isRestoringAll = false;
      }
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// ====== (1) 마커 클릭 시: 장소/리뷰 바텀시트 ======
  void _showSchoolBottomSheet({
    required School school,
    required List<ReviewItem> reviews,
  }) {
    if (_isSchoolSheetOpen) return;
    _isSchoolSheetOpen = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        final distanceText = _distanceTextToSchool(school);

        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Stack(
              children: [
                // ✅ 배경(빈 공간)만 터치하면 닫기
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => Navigator.pop(context),
                  ),
                ),

                // ✅ 실제 바텀시트
                DraggableScrollableSheet(
                  initialChildSize: 0.62,
                  minChildSize: 0.35,
                  maxChildSize: 0.88,
                  builder: (context, scrollController) {
                    return Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                        border: Border.all(color: const Color(0xFF8DBB6A), width: 1),
                      ),
                      child: Column(
                        children: [
                          const SizedBox(height: 10),
                          Container(
                            width: 44,
                            height: 5,
                            decoration: BoxDecoration(
                              color: Colors.grey[400],
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                          Expanded(
                            child: ListView(
                              controller: scrollController,
                              padding: const EdgeInsets.fromLTRB(18, 14, 18, 18),
                              children: [
                                Text(
                                  school.name,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  '$distanceText · ${_guessRegionFromAddress(school.address)}',
                                  style: const TextStyle(fontSize: 14, color: Colors.black54),
                                ),
                                const SizedBox(height: 14),

                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      '리뷰 ${school.reviewCount}개',
                                      style: const TextStyle(fontSize: 14, color: Colors.black54),
                                    ),
                                    ElevatedButton(
                                      onPressed: () async {
                                        Navigator.pop(context); // 현재 열려있는 바텀시트 닫기

                                        // ✅ 현재 학교 리뷰에서 "내 리뷰" 탐색
                                        ReviewItem? myReview;
                                        final myNick = _myNickname;
                                        if (myNick != null && myNick.isNotEmpty) {
                                          for (final r in reviews) {
                                            if (r.authorNickname == myNick) {
                                              myReview = r;
                                              break;
                                            }
                                          }
                                        }

                                        bool? ok;

                                        if (myReview != null) {
                                          final goEdit = await _showAlreadyReviewedDialog();
                                          if (goEdit == true) {
                                            ok = await _showEditReviewDialog(
                                              school: school,
                                              review: myReview,
                                            );
                                          } else {
                                            ok = false;
                                          }
                                        } else {
                                          ok = await _showWriteReviewDialog(school: school);
                                        }

                                        if (ok == true) {
                                          _showSnack('리뷰 제출이 완료되었습니다');
                                          await _loadSchoolsAndPlaceMarkers();

                                          final updatedSchool = _schools.firstWhere(
                                                (s) => s.id == school.id,
                                            orElse: () => school,
                                          );
                                          final newReviews = await _fetchReviewsForSchool(school.id);

                                          if (!mounted) return;
                                          _showSchoolBottomSheet(
                                            school: updatedSchool,
                                            reviews: newReviews,
                                          );
                                        }
                                      },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF5E9B4B),
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(22),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 18,
                                          vertical: 10,
                                        ),
                                        elevation: 0,
                                      ),
                                      child: const Text(
                                        '리뷰 작성하기',
                                        style: TextStyle(fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                  ],
                                ),

                                const SizedBox(height: 14),
                                const Divider(height: 1),

                                const SizedBox(height: 14),
                                for (final r in reviews) ...[
                                  _buildReviewCard(school: school, r: r, setSheetState: setSheetState),
                                  const Divider(height: 20),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    ).whenComplete(() {
      _isSchoolSheetOpen = false;
    });
  }

  String _distanceTextToSchool(School s) {
    final pos = _myPosition;
    if (pos == null) return '거리 정보 없음';
    final meters = Geolocator.distanceBetween(
      pos.latitude,
      pos.longitude,
      s.latitude,
      s.longitude,
    );
    final km = meters / 1000.0;
    return '${km.toStringAsFixed(1)}km';
  }

  String _guessRegionFromAddress(String address) {
    final parts = address.trim().split(' ');
    if (parts.length >= 2) return '${parts[0]} ${parts[1]}';
    if (parts.isNotEmpty) return parts[0];
    return '';
  }

  Widget _buildAiSchoolRecommendationSection() {
    // 로딩 중
    if (_isLoadingAiSchools) {
      return Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F8E9),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF8DBB6A)),
        ),
        child: Row(
          children: const [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: 10),
            Text('AI 추천 고사장 불러오는 중...'),
          ],
        ),
      );
    }

    // 추천이 비어있음(백엔드가 0개 내려줌)
    if (_aiRecommendedSchools.isEmpty) {
      return Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFFF1F8E9),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFF8DBB6A)),
        ),
        child: Row(
          children: [
            const Icon(Icons.auto_awesome, size: 18, color: Color(0xFF5E9B4B)),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                '아직 추천할 고사장이 없어요.\n리뷰를 작성하면 더 정확한 추천을 받을 수 있어요!',
                style: TextStyle(fontSize: 13, color: Colors.black87),
              ),
            ),
            TextButton(
              onPressed: _loadAiRecommendedSchools,
              child: const Text('새로고침'),
            ),
          ],
        ),
      );
    }

    // 정상 추천
    return _buildAiSchoolRecommendation();
  }

  Widget _buildAiSchoolRecommendation() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF1F8E9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF8DBB6A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: const [
              Icon(Icons.auto_awesome, size: 18, color: Color(0xFF5E9B4B)),
              SizedBox(width: 6),
              Text(
                '나에게 맞는 AI 추천 고사장',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),

          Row(
            children: _aiRecommendedSchools.map((s) {
              return Expanded(
                child: _buildAiSchoolCard(s),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildAiSchoolCard(School s) {
    return InkWell(
      onTap: () async {
        await _mapController?.updateCamera(
          NCameraUpdate.scrollAndZoomTo(
            target: NLatLng(s.latitude, s.longitude),
            zoom: 15,
          ),
        );

        final reviews = await _fetchReviewsForSchool(s.id);
        if (!mounted) return;
        _showSchoolBottomSheet(school: s, reviews: reviews);
      },
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.black12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween, // ✅ 핵심
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                Text(
                  _guessRegionFromAddress(s.address),
                  style: const TextStyle(fontSize: 12, color: Colors.black54),
                ),
              ],
            ),
            Text(
              '리뷰 ${s.reviewCount}개',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReviewCard({
    required School school,
    required ReviewItem r,
    required StateSetter setSheetState,
  }) {
    final firstImage = r.imageUrls.isNotEmpty ? r.imageUrls.first : null;
    final isMine = (_myNickname != null &&
        _myNickname!.isNotEmpty &&
        r.authorNickname == _myNickname);

    // ✅ 로컬 상태 초기화(처음 그릴 때만)
    _likedByMe.putIfAbsent(r.id, () => r.liked);
    _likeCountById.putIfAbsent(r.id, () => r.likeCount);

    final isLiked = _likedByMe[r.id] ?? false;
    final likeCount = _likeCountById[r.id] ?? r.likeCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: Colors.white,
              child: Text(
                r.authorNickname.isNotEmpty ? r.authorNickname.characters.first : '🙂',
                style: const TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                r.authorNickname,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                overflow: TextOverflow.ellipsis,
              ),
            ),

            if (isMine)
              TextButton.icon(
                onPressed: () async {
                  _closeSchoolSheetIfOpen();
                  await Future.delayed(const Duration(milliseconds: 50));

                  final ok = await _showEditReviewDialog(school: school, review: r);

                  if (ok == true) {
                    _showSnack('리뷰가 수정되었습니다');
                    await _loadSchoolsAndPlaceMarkers();

                    final updatedSchool = _schools.firstWhere(
                          (s) => s.id == school.id,
                      orElse: () => school,
                    );

                    final newReviews = await _fetchReviewsForSchool(school.id);
                    if (!mounted) return;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _showSchoolBottomSheet(school: updatedSchool, reviews: newReviews);
                    });
                  }
                },
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('수정'),
              ),
          ],
        ),
        const SizedBox(height: 10),

        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _pill(
              r.recommended ? '추천' : '비추천',
              borderColor: r.recommended ? Colors.blue : Colors.red,
              textColor: r.recommended ? Colors.blue : Colors.red,
            ),
            _pill(
              r.facilityGood ? '시설이 좋아요' : '시설이 별로예요',
              borderColor: r.facilityGood ? Colors.blue : Colors.red,
              textColor: r.facilityGood ? Colors.blue : Colors.red,
            ),
            _pill(
              r.quiet ? '조용해요' : '시끄러워요',
              borderColor: r.quiet ? Colors.blue : Colors.red,
              textColor: r.quiet ? Colors.blue : Colors.red,
            ),
            _pill(
              r.accessible ? '자가용도 괜찮아요' : '대중교통을 추천해요',
              borderColor: Colors.green,
              textColor: Colors.green,
            ),
          ],
        ),

        const SizedBox(height: 14),

        if (firstImage != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              firstImage,
              width: 160,
              height: 120,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: 160,
                height: 120,
                color: Colors.grey[200],
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
          const SizedBox(height: 10),
        ],

        Row(
          children: [
            IconButton(
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
              onPressed: () async {
                final prevLiked = _likedByMe[r.id] ?? false;
                final prevCount = _likeCountById[r.id] ?? r.likeCount;

                // ✅ UI 즉시 반영 (바텀시트 내부 리빌드)
                setSheetState(() {
                  final nextLiked = !prevLiked;
                  _likedByMe[r.id] = nextLiked;
                  _likeCountById[r.id] = nextLiked ? (prevCount + 1) : (prevCount - 1);
                });

                // ✅ 서버 반영(실패 시 롤백)
                try {
                  if (!prevLiked) {
                    await _likeReview(r.id);
                  } else {
                    await _unlikeReview(r.id);
                  }
                } catch (e) {
                  setSheetState(() {
                    _likedByMe[r.id] = prevLiked;
                    _likeCountById[r.id] = prevCount;
                  });
                  _showSnack('좋아요 처리 실패: $e');
                }
              },
              icon: Icon(
                isLiked ? Icons.thumb_up : Icons.thumb_up_alt_outlined,
                size: 18,
                color: isLiked ? Colors.blue : Colors.black45,
              ),
            ),
            Text('$likeCount', style: const TextStyle(color: Colors.black54)),
          ],
        )

      ],
    );
  }

  Widget _pill(
      String text, {
        required Color borderColor,
        required Color textColor,
      }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor, width: 1.4),
        color: Colors.transparent,
      ),
      child: Text(
        text,
        style: TextStyle(color: textColor, fontWeight: FontWeight.w600),
      ),
    );
  }

  Future<bool?> _showWriteReviewDialog({required School school}) async {
    bool recommended = true;
    bool facilityGood = true;
    bool quiet = true;
    bool accessible = true;

    File? pickedImage;
    String contentText = '';
    String? contentError;

    bool submitting = false;

    Future<void> pickImage(StateSetter setStateDialog) async {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(source: ImageSource.gallery);
      if (xfile == null) return;
      setStateDialog(() => pickedImage = File(xfile.path));
    }

    return await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setStateDialog) {
            return Dialog(
              insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
              backgroundColor: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: const Color(0xFF8DBB6A), width: 1),
                ),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('리뷰 작성', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 14),

                      const Text('이 고사장을 추천하나요?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _toggleButton(
                            label: '추천',
                            selected: recommended == true,
                            onTap: submitting ? () {} : () => setStateDialog(() => recommended = true),
                          ),
                          const SizedBox(width: 10),
                          _toggleButton(
                            label: '비추천',
                            selected: recommended == false,
                            onTap: submitting ? () {} : () => setStateDialog(() => recommended = false),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      const Text('시험장 시설은 어땠나요?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _toggleButton(
                            label: '좋아요',
                            selected: facilityGood == true,
                            onTap: submitting ? () {} : () => setStateDialog(() => facilityGood = true),
                          ),
                          const SizedBox(width: 10),
                          _toggleButton(
                            label: '별로예요',
                            selected: facilityGood == false,
                            onTap: submitting ? () {} : () => setStateDialog(() => facilityGood = false),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      const Text('전체적으로 조용한 환경인가요?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _toggleButton(
                            label: '조용해요',
                            selected: quiet == true,
                            onTap: submitting ? () {} : () => setStateDialog(() => quiet = true),
                          ),
                          const SizedBox(width: 10),
                          _toggleButton(
                            label: '시끄러워요',
                            selected: quiet == false,
                            onTap: submitting ? () {} : () => setStateDialog(() => quiet = false),
                          ),
                        ],
                      ),

                      const SizedBox(height: 16),

                      const Text('교통은 어떤가요?', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Column(
                        children: [
                          _toggleButton(
                            label: '자가용도 괜찮아요',
                            selected: accessible == true,
                            onTap: submitting ? () {} : () => setStateDialog(() => accessible = true),
                          ),
                          const SizedBox(width: 10),
                          _toggleButton(
                            label: '대중교통을 추천해요',
                            selected: accessible == false,
                            onTap: submitting ? () {} : () => setStateDialog(() => accessible = false),
                          ),
                        ],
                      ),

                      const SizedBox(height: 18),

                      const Text('사진 업로드', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          ElevatedButton(
                            onPressed: submitting ? null : () => pickImage(setStateDialog),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.grey[200],
                              foregroundColor: Colors.black87,
                              elevation: 0,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            child: const Text('파일 선택'),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              pickedImage == null ? '선택한 파일이 없습니다' : pickedImage!.path.split('/').last,
                              style: const TextStyle(color: Colors.black54),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (pickedImage != null) ...[
                            const SizedBox(width: 8),
                            IconButton(
                              tooltip: '선택 취소',
                              onPressed: submitting ? null : () => setStateDialog(() => pickedImage = null),
                              icon: const Icon(Icons.close, size: 18),
                            ),
                          ],
                        ],
                      ),

                      const SizedBox(height: 18),

                      const Text('리뷰 쓰기', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      TextField(
                        minLines: 4,
                        maxLines: 6,
                        enabled: !submitting,
                        onChanged: (v) {
                          contentText = v;
                          if (contentError != null && v.trim().isNotEmpty) {
                            setStateDialog(() => contentError = null); // ✅ 입력하면 에러 제거
                          }
                        },
                        decoration: InputDecoration(
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                      ),

// ✅ TextField 바로 아래에 빨간 에러 문구
                      // ✅ 버튼 위에 빨간 경고
                      if (contentError != null) ...[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            contentError!,
                            style: const TextStyle(
                              color: Colors.red,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],

                      const SizedBox(height: 18),

                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: submitting
                                  ? null
                                  : () {
                                Navigator.pop(dialogContext, false); 
                              },
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.black87,
                                side: const BorderSide(color: Colors.black26),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                              ),
                              child: const Text('취소', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ElevatedButton(
                              onPressed: submitting
                                  ? null
                                  : () async {
                                final text = contentText.trim();
                                if (text.isEmpty) {
                                  setStateDialog(() => contentError = '리뷰 내용을 작성하세요');
                                  return;
                                }

                                setStateDialog(() => submitting = true);

                                try {
                                  await _submitReview(
                                    schoolId: school.id,
                                    recommended: recommended,
                                    facilityGood: facilityGood,
                                    quiet: quiet,
                                    accessible: accessible,
                                    content: text,
                                    imageFile: pickedImage,
                                  );

                                  await _refreshScore(); // ✅ 리뷰 작성 직후 점수 즉시 반영

                                  if (!mounted) return;
                                  Navigator.pop(dialogContext, true); 
                                } catch (e) {
                                  _showSnack('제출 실패: $e');
                                  if (mounted) setStateDialog(() => submitting = false);
                                }
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF5E9B4B),
                                foregroundColor: Colors.white,
                                elevation: 0,
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
                              ),
                              child: submitting
                                  ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                                  : const Text('제출하기', style: TextStyle(fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }


  Widget _toggleButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.black, width: 1.2),
          color: selected ? Colors.black : Colors.white,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : Colors.black,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}
