import 'dart:io';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';

import 'package:toeic_master_front/core/api.dart';
import 'package:toeic_master_front/core/api_client.dart';
import 'package:toeic_master_front/core/token_storage.dart';

/// ===============================
/// Models
/// ===============================
class TestSchedule {
  final String title;
  final TimeOfDay startTime;
  final TimeOfDay endTime;
  final DateTime date;

  TestSchedule({
    required this.title,
    required this.startTime,
    required this.endTime,
    required this.date,
  });
}

class MyGalleryItem {
  final int imageId;
  final String imageUrl;
  final int reviewId;
  final int schoolId;
  final String schoolName;
  final DateTime createdAt;

  MyGalleryItem({
    required this.imageId,
    required this.imageUrl,
    required this.reviewId,
    required this.schoolId,
    required this.schoolName,
    required this.createdAt,
  });

  factory MyGalleryItem.fromJson(Map<String, dynamic> json) {
    return MyGalleryItem(
      imageId: (json['imageId'] as num).toInt(),
      imageUrl: (json['imageUrl'] ?? '') as String,
      reviewId: (json['reviewId'] as num).toInt(),
      schoolId: (json['schoolId'] as num).toInt(),
      schoolName: (json['schoolName'] ?? '') as String,
      createdAt: DateTime.tryParse((json['createdAt'] ?? '') as String) ?? DateTime.now(),
    );
  }
}

/// ===============================
/// MyPage
/// ===============================
class MyPage extends StatefulWidget {
  // ✅ 부모(main.dart)에서 내려주는 현재 상태
  final bool isLoggedIn;
  final String email;
  final String nickname;
  final String myGoal;
  final File? profileImage;

  // ✅ 부모 상태를 갱신하기 위한 콜백
  final void Function(String email, String nickname, String goal, File? profileImage) onLogin;
  final VoidCallback onLogout;
  final void Function(String nickname, String goal, File? profileImage) onProfileUpdated;

  final ValueNotifier<int> scoreNotifier;

  const MyPage({
    super.key,
    required this.isLoggedIn,
    required this.email,
    required this.nickname,
    required this.myGoal,
    required this.profileImage,
    required this.onLogin,
    required this.onLogout,
    required this.onProfileUpdated,
    required this.scoreNotifier,
  });

  @override
  State<MyPage> createState() => _MyPageState();
}

class _MyPageState extends State<MyPage> {

  int _score = 0;

  // ✅ 이 페이지 내부에서 “유저별 저장소”는 그대로 유지(로컬 UI용)
  final Map<String, Map<String, dynamic>> _userDataStorage = {};

  String? _profileImageUrl; // ✅ 서버에 저장된 프로필 이미지 URL

  // ✅ 페이지 내부 표시용 로컬 상태(부모 값과 동기화)
  late String _nickname;
  late String _myGoal;
  late String _email;
  File? _profileImage;

  // (백엔드 프로필 bio를 myGoal로 매핑해서 사용)
  String _bio = '';

  // ✅ 나의 성향(로컬 저장) !! 아직 백앤드랑 연결 안 함 !!
  String _tendencyQ1 = '';
  String _tendencyQ2 = '';
  String _tendencyQ3 = '';
  String _tendencyQ4 = '';

  final Map<DateTime, List<TestSchedule>> _events = {};
  final CalendarFormat _calendarFormat = CalendarFormat.month;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;

  late final TokenStorage _tokenStorage;
  late final Api _api;

  late final ApiClient _apiClient;

  // ✅ 내 리뷰 갤러리 상태
  final List<MyGalleryItem> _gallery = [];
  bool _galleryLoading = false;
  bool _galleryRefreshing = false;
  bool _galleryHasMore = true;
  int _galleryPage = 0;
  final int _gallerySize = 30;
  final ScrollController _galleryScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _tokenStorage = TokenStorage();
    _apiClient = ApiClient(_tokenStorage); // ✅ 추가
    _api = Api(_apiClient);

    _syncFromParent();
    _bootstrapAuth();

    _galleryScrollController.addListener(_onGalleryScroll);
  }

  @override
  void dispose() {
    _galleryScrollController.dispose();
    super.dispose();
  }

  String _tKey(String email, int idx) => 'my_tendency_${email}_q$idx';

  Future<void> _loadTendencies(String email) async {
    if (email.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();

    if (!mounted) return;
    setState(() {
      _tendencyQ1 = prefs.getString(_tKey(email, 1)) ?? '';
      _tendencyQ2 = prefs.getString(_tKey(email, 2)) ?? '';
      _tendencyQ3 = prefs.getString(_tKey(email, 3)) ?? '';
      _tendencyQ4 = prefs.getString(_tKey(email, 4)) ?? '';
    });
  }

  Future<void> _saveTendencies(String email) async {
    if (email.trim().isEmpty) return;
    final prefs = await SharedPreferences.getInstance();

    await prefs.setString(_tKey(email, 1), _tendencyQ1);
    await prefs.setString(_tKey(email, 2), _tendencyQ2);
    await prefs.setString(_tKey(email, 3), _tendencyQ3);
    await prefs.setString(_tKey(email, 4), _tendencyQ4);
  }

  // ✅ 서버에 저장할 tendency(JSON string) 만들기
  String _encodeTendency(String q1, String q2, String q3, String q4) {
    final map = {
      'q1': q1.trim(),
      'q2': q2.trim(),
      'q3': q3.trim(),
      'q4': q4.trim(),
    };
    return jsonEncode(map); // 서버에는 string 하나로 저장됨
  }

// ✅ 서버에서 받은 tendency(JSON string) -> 4칸 복원
  Map<String, String> _decodeTendency(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return {
          'q1': decoded['q1']?.toString() ?? '',
          'q2': decoded['q2']?.toString() ?? '',
          'q3': decoded['q3']?.toString() ?? '',
          'q4': decoded['q4']?.toString() ?? '',
        };
      }
    } catch (_) {
      // 과거 데이터가 "그냥 이어붙인 문자열"일 수도 있으니 fallback
    }
    return {'q1': '', 'q2': '', 'q3': '', 'q4': ''};
  }

  Widget _tendencyField({
    required TextEditingController controller,
    required String label,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: 2,
          decoration: const InputDecoration(
            hintText: '입력하세요',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ],
    );
  }

  Widget _buildTendencyCard() {
    String pretty(String s) => s.trim().isEmpty ? '작성해주세요.' : s.trim();

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 5),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '나의 성향',
            style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 12),
          ),
          const SizedBox(height: 10),

          const Text(
            '시험 전날과 시험 당일 아침에 보통 어떤 상태인가요?',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(pretty(_tendencyQ1), style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 12),

          const Text(
            '시험 볼 때 가장 집중이 잘 깨지는 상황은 언제인가요?',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(pretty(_tendencyQ2), style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 12),

          const Text(
            '내 멘탈이 가장 흔들리는 순간은?',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(pretty(_tendencyQ3), style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 12),

          const Text(
            '더 적고 싶은 자신의 성향을 작성해주세요.',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(pretty(_tendencyQ4), style: const TextStyle(fontSize: 12, color: Colors.black54)),
        ],
      ),
    );
  }

  void _openGalleryViewer({required int initialIndex}) {
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          insetPadding: EdgeInsets.zero,
          backgroundColor: Colors.black,
          child: Stack(
            children: [
              PageView.builder(
                controller: PageController(initialPage: initialIndex),
                itemCount: _gallery.length,
                itemBuilder: (context, i) {
                  final g = _gallery[i];
                  return Stack(
                    children: [
                      Center(
                        child: InteractiveViewer(
                          child: Image.network(
                            g.imageUrl,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                            const Icon(Icons.broken_image_outlined, color: Colors.white),
                          ),
                        ),
                      ),

                      // ⬇️ 하단 학교명 + 날짜
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 18,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              g.schoolName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${g.createdAt.year}.${g.createdAt.month.toString().padLeft(2, '0')}.${g.createdAt.day.toString().padLeft(2, '0')}',
                              style: const TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),

              // ❌ 좌측 상단 닫기 버튼 (유지)
              Positioned(
                top: 14,
                left: 12,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 26),
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),

              // ❌❌ 우측 상단 X 버튼 (추가!)
              Positioned(
                top: 14,
                right: 12,
                child: GestureDetector(
                  onTap: () => Navigator.pop(ctx),
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.5),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _onGalleryScroll() {
    if (!_galleryHasMore || _galleryLoading || _galleryRefreshing) return;

    // 스크롤이 아래쪽에 가까워지면 다음 페이지 로드
    final pos = _galleryScrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 300) {
      _loadMyGallery(nextPage: true);
    }
  }

  Future<void> _refreshMyGallery() async {
    if (!widget.isLoggedIn) return;
    if (_galleryRefreshing) return;

    setState(() {
      _galleryRefreshing = true;
      _galleryHasMore = true;
      _galleryPage = 0;
      _gallery.clear();
    });

    try {
      await _loadMyGallery(nextPage: false);
    } finally {
      if (mounted) setState(() => _galleryRefreshing = false);
    }
  }

  Future<void> _loadMyGallery({required bool nextPage}) async {
    if (!widget.isLoggedIn) return;
    if (_galleryLoading) return;
    if (!_galleryHasMore) return;

    setState(() => _galleryLoading = true);

    try {
      final pageToLoad = nextPage ? _galleryPage + 1 : 0;

      final res = await _apiClient.dio.get(
        '/api/users/me/gallery',
        queryParameters: {
          'page': pageToLoad,
          'size': _gallerySize,
        },
      );

      final decoded = res.data as Map<String, dynamic>;
      final data = decoded['data'] as Map<String, dynamic>?;

      final content = (data?['content'] as List<dynamic>?) ?? const [];
      final last = (data?['last'] as bool?) ?? true;

      final items = content
          .map((e) => MyGalleryItem.fromJson(e as Map<String, dynamic>))
          .where((x) => x.imageUrl.trim().isNotEmpty)
          .toList();

      if (!mounted) return;
      setState(() {
        _gallery.addAll(items);
        _galleryPage = pageToLoad;
        _galleryHasMore = !last && items.isNotEmpty;
      });
    } catch (e) {
      if (mounted) _showSnack('내 리뷰 사진 불러오기 실패: $e');
    } finally {
      if (mounted) setState(() => _galleryLoading = false);
    }
  }

  Future<void> _bootstrapAuth() async {
    final token = await _tokenStorage.readAccessToken();
    if (token == null || token.isEmpty) return;

    try {
      final profileRes = await _api.getMyProfile();
      final data = profileRes['data'] as Map<String, dynamic>?;

      final email = (data?['email'] ?? '') as String;
      final nickname = (data?['nickname'] ?? '닉네임') as String;
      final bio = (data?['bio'] ?? '') as String;
      final tendencyRaw = (data?['tendency'] ?? '') as String;
      final profileImageUrl = (data?['profileImageUrl'] as String?)?.trim();
      final score = (data?['score'] as num?)?.toInt() ?? 0;

      if (!mounted) return;

      setState(() {
        _email = email;
        _nickname = nickname;
        _bio = bio;
        _myGoal = bio.isEmpty ? '목표를 적어보세요' : bio;
        _profileImageUrl = (profileImageUrl != null && profileImageUrl.isNotEmpty)
            ? profileImageUrl
            : null;
        _score = score;
      });

      widget.scoreNotifier.value = score;

      await _loadTendencies(_email); // 로컬 먼저 로드(오프라인 캐시)

      if (tendencyRaw.trim().isNotEmpty) {
        final parsed = _decodeTendency(tendencyRaw);

        if (!mounted) return;
        setState(() {
          _tendencyQ1 = parsed['q1'] ?? '';
          _tendencyQ2 = parsed['q2'] ?? '';
          _tendencyQ3 = parsed['q3'] ?? '';
          _tendencyQ4 = parsed['q4'] ?? '';
        });

        // 로컬 캐시도 서버 값으로 덮어써서 동기화
        await _saveTendencies(_email);

      }

      // 부모에 로그인 상태 반영
      widget.onLogin(_email, _nickname, _myGoal, _profileImage);
      await _refreshMyGallery();
    } catch (_) {
      // 토큰이 만료/무효면 정리
      await _tokenStorage.clear();
    }
  }

  int _levelFromScore(int s) {
    if (s >= 1000) return 5;
    if (s >= 700) return 4;
    if (s >= 450) return 3;
    if (s >= 250) return 2;
    if (s >= 100) return 1;
    return 0;
  }

  int _nextThreshold(int level) {
    const thresholds = [100, 250, 450, 700, 1000];
    if (level >= thresholds.length) return thresholds.last;
    return thresholds[level];
  }

  double _progressInLevel(int s) {
    const starts = [0, 100, 250, 450, 700, 1000];
    final level = _levelFromScore(s);
    final start = starts[level];
    final next = _nextThreshold(level);
    if (next == start) return 1.0;
    return ((s - start) / (next - start)).clamp(0.0, 1.0);
  }

  @override
  void didUpdateWidget(covariant MyPage oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.isLoggedIn != widget.isLoggedIn ||
        oldWidget.email != widget.email ||
        oldWidget.nickname != widget.nickname ||
        oldWidget.myGoal != widget.myGoal ||
        oldWidget.profileImage?.path != widget.profileImage?.path) {
      _syncFromParent();
    }
    if (!oldWidget.isLoggedIn && widget.isLoggedIn) {
      _refreshMyGallery();
    }
    if (oldWidget.isLoggedIn && !widget.isLoggedIn) {
      setState(() {
        _gallery.clear();
        _galleryHasMore = true;
        _galleryPage = 0;
      });
    }
  }

  void _syncFromParent() {
    _nickname = widget.nickname;
    _myGoal = widget.myGoal;
    _email = widget.email;
    _profileImage = widget.profileImage;

    // myGoal이 bio 역할이므로 동기화
    _bio = (_myGoal == '목표를 적어보세요') ? '' : _myGoal;
  }

  Future<void> _pickImage(StateSetter setDialogState, BuildContext dialogContext) async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) return;

    final file = File(pickedFile.path);

    // 1) 로컬 미리보기 즉시 반영
    setDialogState(() => _profileImage = file);
    setState(() {});

    try {
      // 2) 서버 업로드
      final uploadRes = await _api.uploadMyProfileImage(file);

      // 3) 서버가 내려준 URL을 상태에 반영 (중요!)
      final data = uploadRes['data'] as Map<String, dynamic>?;
      final url = (data?['profileImageUrl'] as String?)?.trim();

      if (!mounted) return;
      setState(() {
        _profileImageUrl = (url != null && url.isNotEmpty) ? url : _profileImageUrl;
      });

      // 부모에도 반영 (StudyPage 등 즉시 갱신)
      widget.onProfileUpdated(_nickname, _myGoal, _profileImage);

      // 4) ✅ 사진 수정 완료 → 정보 수정 창 닫기
      Navigator.of(dialogContext).pop();

      _showSnack('프로필 사진이 저장됐어요.');
    } catch (e) {
      _showSnack('프로필 사진 업로드 실패: $e');
    }
  }



  Future<void> _logout() async {
    await _tokenStorage.clear();

    if (!mounted) return;
    setState(() {
      _email = '';
      _nickname = '닉네임';
      _myGoal = '목표를 적어보세요';
      _bio = '';
      _profileImage = null;
      _gallery.clear();
      _galleryHasMore = true;
      _galleryPage = 0;
    });

    widget.scoreNotifier.value = 0;

    widget.onLogout();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn = widget.isLoggedIn;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        toolbarHeight: 44,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/examtalk_logo.png',
              height: 30, // StudyPage랑 동일
            ),
            const SizedBox(width: 5),
            const Text(
              '마이페이지',
              style: TextStyle(
                fontSize : 20,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ],
        ),
        actions: widget.isLoggedIn
            ? [
          Padding(
            padding: const EdgeInsets.only(right: 16.0),
            child: Center(
              child: InkWell(
                onTap: _logout,
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey[300]!),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.logout, size: 14, color: Colors.grey),
                      SizedBox(width: 4),
                      Text(
                        '로그아웃',
                        style: TextStyle(
                          color: Colors.grey,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ]
            : null,
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            isLoggedIn ? _buildLoggedInHeader() : _buildLoggedOutHeader(),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 20),
              child: Text('내 리뷰', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            _buildReviewGallery(),
            const Divider(thickness: 8, color: Color(0xFFF5F5F5)),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 10),
              child: Text('내 시험 일정', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            if (_events.isNotEmpty) _buildEventList(),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16.0), child: _buildCalendar()),
            const SizedBox(height: 50),
          ],
        ),
      ),
    );
  }

  Widget _buildScoreCard() {
    return ValueListenableBuilder<int>(
      valueListenable: widget.scoreNotifier,
      builder: (context, score, _) {
        final level = _levelFromScore(score);
        final next = _nextThreshold(level);
        final progress = _progressInLevel(score);
        final remain = (next - score).clamp(0, 1 << 30);

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 10,
                offset: const Offset(0, 5),
              )
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '합격 게이지',
                style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 12),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('Lv.$level', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(width: 10),
                  Text('$score 점',
                      style: const TextStyle(fontSize: 16, color: Color(0xFF436B2D), fontWeight: FontWeight.bold)),
                  const Spacer(),
                  Text(remain > 0 ? '다음까지 $remain점' : 'MAX', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 10,
                  backgroundColor: const Color(0xFFEFEFEF),
                  valueColor: const AlwaysStoppedAnimation(Color(0xFF7CB342)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLoggedInHeader() {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      width: double.infinity,
      color: const Color(0xFFE1E8DC),
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 24),
      child: Column(
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 35,
                backgroundColor: Colors.white,
                backgroundImage: _profileImage != null
                    ? FileImage(_profileImage!)
                    : (_profileImageUrl != null && _profileImageUrl!.isNotEmpty
                    ? NetworkImage(_profileImageUrl!)
                    : null) as ImageProvider?,
                child: (_profileImage == null && (_profileImageUrl == null || _profileImageUrl!.isEmpty))
                    ? const Icon(Icons.face, size: 50, color: Colors.lightGreen)
                    : null,
              ),

              const SizedBox(width: 15),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_nickname, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    Text(_email, style: const TextStyle(color: Colors.black54, fontSize: 14)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Container(
            margin: const EdgeInsets.only(bottom: 18),
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 5))
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('나의 목표', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold, fontSize: 12)),
                const SizedBox(height: 8),
                Text(_myGoal, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF436B2D))),
              ],
            ),
          ),
          _buildTendencyCard(),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _showEditInfoDialog,
              icon: const Icon(Icons.edit, size: 16),
              label: const Text('내 정보 수정하기'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.black87,
                side: const BorderSide(color: Colors.black12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                backgroundColor: Colors.white.withValues(alpha: 0.5),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showEditInfoDialog() async {
    bool imageChanged = false;
    final nameController = TextEditingController(text: _nickname);
    final goalController = TextEditingController(text: _myGoal == '목표를 적어보세요' ? '' : _myGoal);
    final t1Controller = TextEditingController(text: _tendencyQ1);
    final t2Controller = TextEditingController(text: _tendencyQ2);
    final t3Controller = TextEditingController(text: _tendencyQ3);
    final t4Controller = TextEditingController(text: _tendencyQ4);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: const Text('정보 수정', style: TextStyle(fontWeight: FontWeight.bold)),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.65,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // (기존) 프로필 이미지
                  GestureDetector(
                    onTap: () async {
                      await _pickImage(setDialogState, context);
                    },
                    child: Stack(
                      children: [
                        CircleAvatar(
                          radius: 35,
                          backgroundColor: Colors.white,
                          backgroundImage: _profileImage != null
                              ? FileImage(_profileImage!)
                              : (_profileImageUrl != null && _profileImageUrl!.isNotEmpty
                              ? NetworkImage(_profileImageUrl!)
                              : null) as ImageProvider?,
                          child: (_profileImage == null &&
                              (_profileImageUrl == null || _profileImageUrl!.isEmpty))
                              ? const Icon(Icons.face, size: 50, color: Colors.lightGreen)
                              : null,
                        ),
                        const Positioned(
                          right: 0,
                          bottom: 0,
                          child: CircleAvatar(
                            radius: 12,
                            backgroundColor: Colors.green,
                            child: Icon(Icons.edit, size: 12, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),
                  TextField(controller: nameController, decoration: const InputDecoration(labelText: '닉네임')),
                  const SizedBox(height: 16),
                  TextField(controller: goalController, decoration: const InputDecoration(labelText: '나의 목표(=소개 bio)')),

                  // ✅ 성향 섹션(기존 기능 아래에 붙임)
                  const SizedBox(height: 20),
                  const Divider(height: 1),
                  const SizedBox(height: 16),

                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '나의 성향 작성',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 12),

                  _tendencyField(
                    controller: t1Controller,
                    label: '시험 전날과 시험 당일 아침에 보통 어떤 상태인가요?',
                  ),
                  const SizedBox(height: 12),

                  _tendencyField(
                    controller: t2Controller,
                    label: '시험 볼 때 가장 집중이 잘 깨지는 상황은 언제인가요?',
                  ),
                  const SizedBox(height: 12),

                  _tendencyField(
                    controller: t3Controller,
                    label: '내 멘탈이 가장 흔들리는 순간은?',
                  ),
                  const SizedBox(height: 12),

                  _tendencyField(
                    controller: t4Controller,
                    label: '더 적고 싶은 자신의 성향을 작성해주세요.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            Row(
              children: [
                Expanded(child: TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소'))),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      final newNickname = nameController.text.trim().isEmpty ? '닉네임' : nameController.text.trim();
                      final newBio = goalController.text.trim();
                      final tendencyToSave = _encodeTendency(
                        t1Controller.text,
                        t2Controller.text,
                        t3Controller.text,
                        t4Controller.text,
                      );

                      try {
                        await _api.updateMyProfile(
                          nickname: newNickname,
                          bio: newBio,
                          tendency: tendencyToSave,
                        );

                        if (!mounted) return;
                        setState(() {
                          _nickname = newNickname;
                          _bio = newBio;
                          _myGoal = newBio.isEmpty ? '목표를 적어보세요' : newBio;
                        });

                        // ✅ 성향 반영 + 로컬 저장
                        _tendencyQ1 = t1Controller.text.trim();
                        _tendencyQ2 = t2Controller.text.trim();
                        _tendencyQ3 = t3Controller.text.trim();
                        _tendencyQ4 = t4Controller.text.trim();
                        await _saveTendencies(_email);

                        widget.onProfileUpdated(_nickname, _myGoal, _profileImage);

                        Navigator.pop(context);
                        _showSnack('프로필이 저장됐어요.');
                      } catch (e) {
                        _showSnack('프로필 저장 실패: $e');
                      }
                    },

                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFCDE1AF), foregroundColor: Colors.black),
                    child: const Text('저장하기'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showLoginWarning() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('알림'),
        content: const Text('로그인 후 사용하세요.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('확인', style: TextStyle(color: Colors.green)),
          ),
        ],
      ),
    );
  }

  Widget _buildLoggedOutHeader() {
    return Container(
      width: double.infinity,
      color: const Color(0xFFE1E8DC),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () async {
              final result = await Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => LoginPage(api: _api, tokenStorage: _tokenStorage)),
              );

              // 로그인 성공 시: LoginResult 반환
              if (result != null && result is LoginResult) {
                final email = result.email;
                final nickname = result.nickname;
                final bio = result.bio;

                setState(() {
                  _email = email;
                  _nickname = nickname.isEmpty ? '닉네임' : nickname;
                  _bio = bio;
                  _myGoal = bio.isEmpty ? '목표를 적어보세요' : bio;

                  // (로컬 캐시 유지)
                  _userDataStorage[email] = {'nickname': _nickname, 'goal': _myGoal, 'image': _profileImage};
                });

                await _loadTendencies(_email);

                // ✅ 부모에게 로그인 상태 전달
                widget.onLogin(_email, _nickname, _myGoal, _profileImage);
              }
            },
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.green.withValues(alpha: 0.5), width: 1.5),
                  ),
                  child: CircleAvatar(
                    radius: 35,
                    backgroundColor: Colors.grey[400],
                    child: Icon(Icons.person, size: 50, color: Colors.grey[700]),
                  ),
                ),
                const SizedBox(width: 15),
                const Text('로그인하세요', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _buildCalendar() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFE1E8DC).withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(15),
      ),
      child: TableCalendar(
        firstDay: DateTime.utc(2020, 1, 1),
        lastDay: DateTime.utc(2030, 12, 31),
        focusedDay: _focusedDay,
        calendarFormat: _calendarFormat,
        eventLoader: (day) => _events[DateTime(day.year, day.month, day.day)] ?? [],
        selectedDayPredicate: (day) => isSameDay(_selectedDay, day),
        onDaySelected: (selectedDay, focusedDay) {
          if (widget.isLoggedIn) {
            setState(() {
              _selectedDay = selectedDay;
              _focusedDay = focusedDay;
            });
            _showAddEventDialog(selectedDay);
          } else {
            _showLoginWarning();
          }
        },
        headerStyle: const HeaderStyle(formatButtonVisible: false, titleCentered: true),
        calendarStyle: const CalendarStyle(
          todayDecoration: BoxDecoration(color: Colors.green, shape: BoxShape.circle),
          markerDecoration: BoxDecoration(color: Colors.red, shape: BoxShape.circle),
          selectedDecoration: BoxDecoration(color: Colors.transparent, shape: BoxShape.circle),
          selectedTextStyle: TextStyle(color: Colors.black),
        ),
      ),
    );
  }

  Widget _buildEventList() {
    final allEvents = _events.values.expand((e) => e).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Column(
        children: List.generate(allEvents.length, (index) {
          final event = allEvents[index];
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[100]!),
            ),
            child: ListTile(
              onTap: () => _showEventDetailDialog(event),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              title: Text(event.title, style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold, fontSize: 16)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.calendar_today, size: 14, color: Colors.grey),
                      const SizedBox(width: 6),
                      Text('${event.date.year}.${event.date.month}.${event.date.day}', style: const TextStyle(color: Colors.black87, fontSize: 13)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      _buildTimeTag('시작', event.startTime.format(context)),
                      const SizedBox(width: 10),
                      _buildTimeTag('종료', event.endTime.format(context)),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _buildTimeTag(String label, String time) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: Colors.grey[100], borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.bold)),
          const SizedBox(width: 4),
          Text(time, style: const TextStyle(fontSize: 12, color: Colors.black87, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  Widget _buildReviewGallery() {
    if (!widget.isLoggedIn) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16.0),
        child: Text('로그인하면 내가 올린 리뷰 사진을 볼 수 있어요.', style: TextStyle(color: Colors.black54)),
      );
    }

    if (_galleryRefreshing && _gallery.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16.0),
        child: Center(
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: CircularProgressIndicator(),
          ),
        ),
      );
    }

    if (_gallery.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('아직 올린 리뷰 사진이 없어요.', style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 10),

            Row(
              children: [
                const Spacer(),   // ✅ 왼쪽 공간 채우기 → 버튼이 오른쪽으로 감
                OutlinedButton(
                  onPressed: _refreshMyGallery,
                  child: const Text('새로고침'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: RefreshIndicator(
        onRefresh: _refreshMyGallery,
        child: GridView.builder(
          controller: _galleryScrollController,
          shrinkWrap: true,
          physics: const AlwaysScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: _gallery.length + (_galleryHasMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index >= _gallery.length) {
              // ✅ 다음 페이지 로딩 표시
              return const Center(
                child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }

            final item = _gallery[index];

            return GestureDetector(
              onTap: () => _openGalleryViewer(initialIndex: index),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      item.imageUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: Colors.grey[300],
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image_outlined, color: Colors.white),
                      ),
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return Container(
                          color: Colors.grey[200],
                          alignment: Alignment.center,
                          child: const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      },
                    ),

                    // ✅ 아래쪽에 학교명 살짝 오버레이 (원하면 제거 가능)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        color: Colors.black.withOpacity(0.35),
                        child: Text(
                          item.schoolName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }


  void _showAddEventDialog(DateTime date) {
    final titleController = TextEditingController();
    TimeOfDay startTime = const TimeOfDay(hour: 13, minute: 0);
    TimeOfDay endTime = const TimeOfDay(hour: 15, minute: 0);

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: titleController, decoration: const InputDecoration(hintText: '제목')),
              const SizedBox(height: 20),
              _buildTimePickerRow('시작', startTime, (time) => setDialogState(() => startTime = time)),
              _buildTimePickerRow('종료', endTime, (time) => setDialogState(() => endTime = time)),
              const SizedBox(height: 30),
              ElevatedButton(
                onPressed: () {
                  if (titleController.text.isNotEmpty) {
                    setState(() {
                      final key = DateTime(date.year, date.month, date.day);
                      _events.putIfAbsent(key, () => []);
                      _events[key]!.add(TestSchedule(title: titleController.text, startTime: startTime, endTime: endTime, date: date));
                    });
                    Navigator.pop(context);
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFCDE1AF), foregroundColor: Colors.black),
                child: const Text('일정 추가'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEventDetailDialog(TestSchedule event) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(event.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            Text('시작 ${event.date.year}.${event.date.month.toString().padLeft(2, '0')}.${event.date.day.toString().padLeft(2, '0')} ${event.startTime.format(context)}'),
            Text('종료 ${event.date.year}.${event.date.month.toString().padLeft(2, '0')}.${event.date.day.toString().padLeft(2, '0')} ${event.endTime.format(context)}'),
            const SizedBox(height: 30),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  final key = DateTime(event.date.year, event.date.month, event.date.day);
                  _events[key]?.remove(event);
                  if (_events[key]?.isEmpty ?? false) _events.remove(key);
                });
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFCDE1AF), foregroundColor: Colors.black),
              child: const Text('삭제'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimePickerRow(String label, TimeOfDay time, Function(TimeOfDay) onTimeSelected) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
          InkWell(
            onTap: () async {
              final picked = await showTimePicker(context: context, initialTime: time);
              if (picked != null) onTimeSelected(picked);
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: Colors.grey[200], borderRadius: BorderRadius.circular(10)),
              child: Text(time.format(context)),
            ),
          )
        ],
      ),
    );
  }
}

/// ===============================
/// Login / Signup Pages
/// ===============================
class LoginResult {
  final String email;
  final String nickname;
  final String bio;

  LoginResult({
    required this.email,
    required this.nickname,
    required this.bio,
  });
}

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.api,
    required this.tokenStorage,
  });

  final Api api;
  final TokenStorage tokenStorage;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _pwController = TextEditingController();

  bool _loading = false;

  String _prettyDioError(Object e) {
    if (e is DioException) {
      final status = e.response?.statusCode;
      final msg = e.response?.data?['message'] ?? e.message ?? '요청 실패';
      return '($status) $msg';
    }
    return e.toString();
  }

  Future<void> _handleLogin() async {
    final email = _emailController.text.trim();
    final pw = _pwController.text;

    if (email.isEmpty || pw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('이메일/비밀번호를 입력하세요.')));
      return;
    }

    setState(() => _loading = true);

    try {
      final token = await widget.api.login(email: email, password: pw);
      await widget.tokenStorage.saveAccessToken(token);

      // 로그인 후 내 프로필까지 가져와서 닉네임/바이오 세팅
      final profileRes = await widget.api.getMyProfile();
      final data = profileRes['data'] as Map<String, dynamic>?;

      final nickname = (data?['nickname'] ?? '닉네임') as String;
      final bio = (data?['bio'] ?? '') as String;
      final profileEmail = (data?['email'] ?? email) as String;

      if (!mounted) return;
      Navigator.pop(
        context,
        LoginResult(email: profileEmail, nickname: nickname, bio: bio),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('로그인 실패: ${_prettyDioError(e)}')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE1E8DC),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(icon: const Icon(Icons.close, color: Colors.black, size: 30), onPressed: () => Navigator.pop(context)),
          const SizedBox(width: 10),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.only(left: 30.0, right: 30.0, bottom: 80.0),
          child: Column(
            children: [
              const Text('로그인', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
              const SizedBox(height: 40),
              Container(
                padding: const EdgeInsets.all(30),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                child: Column(
                  children: [
                    TextField(
                      controller: _emailController,
                      decoration: const InputDecoration(labelText: '이메일', labelStyle: TextStyle(color: Colors.grey)),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _pwController,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '비밀번호', labelStyle: TextStyle(color: Colors.grey)),
                    ),
                    const SizedBox(height: 40),
                    ElevatedButton(
                      onPressed: _loading ? null : _handleLogin,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: _loading
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('로그인 하기', style: TextStyle(color: Colors.white)),
                    ),
                    const SizedBox(height: 20),
                    GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => SignUpPage(api: widget.api)),
                      ),
                      child: RichText(
                        text: const TextSpan(
                          style: TextStyle(color: Colors.grey, fontSize: 14),
                          children: [
                            TextSpan(text: '계정이 없으신가요? '),
                            TextSpan(text: '회원가입', style: TextStyle(decoration: TextDecoration.underline, fontWeight: FontWeight.bold)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key, required this.api});

  final Api api;

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _nicknameController = TextEditingController();
  final TextEditingController _pwController = TextEditingController();
  final TextEditingController _pwConfirmController = TextEditingController();

  bool _isPasswordCorrect = true;
  bool _isPasswordLengthValid = true;
  bool _loading = false;

  void _checkPassword() {
    setState(() {
      _isPasswordLengthValid = _pwController.text.length >= 6;
      _isPasswordCorrect =
          _pwController.text == _pwConfirmController.text;
    });
  }

  String _prettyDioError(Object e) {
    if (e is DioException) {
      final status = e.response?.statusCode;
      final msg = e.response?.data?['message'] ?? e.message ?? '요청 실패';
      return '($status) $msg';
    }
    return e.toString();
  }

  Future<void> _handleSignup() async {
    final email = _emailController.text.trim();
    final nickname = _nicknameController.text.trim();
    final pw = _pwController.text;

    if (pw.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('비밀번호는 6자 이상이어야 합니다.')),
      );
      return;
    }

    if (email.isEmpty || nickname.isEmpty || pw.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('이메일/닉네임/비밀번호를 모두 입력하세요.')));
      return;
    }
    if (!_isPasswordCorrect) return;

    setState(() => _loading = true);

    try {
      await widget.api.signup(email: email, password: pw, nickname: nickname);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('회원가입 성공! 로그인 해주세요.')));
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('회원가입 실패: ${_prettyDioError(e)}')));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFE1E8DC),
      appBar: AppBar(backgroundColor: Colors.transparent, elevation: 0, iconTheme: const IconThemeData(color: Colors.black)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 30.0),
          child: Column(
            children: [
              const Text('회원가입', style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
              const SizedBox(height: 40),
              Container(
                padding: const EdgeInsets.all(30),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)),
                child: Column(
                  children: [
                    TextField(controller: _nicknameController, decoration: const InputDecoration(labelText: '닉네임')),
                    const SizedBox(height: 20),
                    TextField(controller: _emailController, decoration: const InputDecoration(labelText: '이메일')),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _pwController,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: '비밀번호',
                        errorText: _isPasswordLengthValid
                            ? null
                            : '비밀번호는 6자 이상 입력하세요',
                      ),
                      onChanged: (_) => _checkPassword(),
                    ),

                    const SizedBox(height: 20),
                    TextField(
                      controller: _pwConfirmController,
                      obscureText: true,
                      decoration: InputDecoration(
                        labelText: '비밀번호 확인',
                        errorText: _isPasswordCorrect ? null : '같은 비밀번호가 아닙니다.',
                        errorStyle: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                      onChanged: (_) => _checkPassword(),
                    ),
                    const SizedBox(height: 40),
                    ElevatedButton(
                      onPressed: _loading ? null : (_isPasswordCorrect ? _handleSignup : null),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green,
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: _loading
                          ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('가입하기', style: TextStyle(color: Colors.white)),
                    )
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
