import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:toeic_master_front/pages/chat_page.dart';
import 'package:toeic_master_front/core/api.dart';
import 'package:toeic_master_front/core/api_client.dart';
import 'package:toeic_master_front/core/token_storage.dart';

class StudyPage extends StatefulWidget {
  final bool isLoggedIn;
  final String nickname;

  const StudyPage({
    super.key,
    required this.isLoggedIn,
    required this.nickname,
  });

  @override
  State<StudyPage> createState() => _StudyPageState();
}

class _StudyPageState extends State<StudyPage> {
  bool _isSearching = true;

  String? _selectedExamType; // null = 전체
  String? _selectedRegion;   // null = 전체

  static const List<String> _examTypes = [
    'TOEIC', 'TOEFL', 'TEPS', 'OPIc'
  ];

  static const List<String> _regions = [
    '서울', '대전', '부산', '인천', '광주', '대구', '울산', '세종',
    '경기', '강원', '충북', '충남', '전북', '전남', '경북', '경남', '제주'
  ];
  
  String _searchQuery = '';

  late final TokenStorage _tokenStorage;
  late final Api _api;

  List<Map<String, dynamic>> _allStudies = [];
  bool _isLoadingStudies = false;
  int _currentPage = 0;
  bool _hasMoreStudies = true;

  List<Map<String, dynamic>> _myStudies = [];
  bool _isLoadingMyStudies = false;
  int? _currentUserId;

  @override
  void initState() {
    super.initState();
    _tokenStorage = TokenStorage();
    _api = Api(ApiClient(_tokenStorage));
    _initPage();
  }

  Future<void> _initPage() async {
    if (widget.isLoggedIn) {
      await _loadCurrentUserId();
    }
    _loadStudies();
  }

  Future<void> _loadCurrentUserId() async {
    if (_currentUserId != null) return;
    try {
      final profileRes = await _api.getMyProfile();
      final profileData = profileRes['data'] as Map<String, dynamic>?;
      _currentUserId = profileData?['id'] as int?;
    } catch (e) {
      debugPrint('사용자 ID 로드 실패: $e');
    }
  }

  @override
  void didUpdateWidget(covariant StudyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isLoggedIn != widget.isLoggedIn) {
      if (widget.isLoggedIn) {
        _loadCurrentUserId();
        _loadMyStudies();
      } else {
        setState(() {
          _myStudies = [];
          _currentUserId = null;
        });
      }
    }
  }

  void _resetAndReloadStudies() {
    _currentPage = 0;
    _hasMoreStudies = true;
    _loadStudies(refresh: true);
  }

  Widget _buildFilterButton({
    required String title,
    required String value,
    required VoidCallback onTap,
  }) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        side: BorderSide(color: Colors.grey[300]!),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        backgroundColor: Colors.white,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              '$title: $value',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w600),
            ),
          ),
          const Icon(Icons.keyboard_arrow_down, color: Colors.black54),
        ],
      ),
    );
  }

  /// return 값:
  /// - null: 취소
  /// - ''  : '전체' 선택
  /// - 그 외: 선택 값
  Future<String?> _showSelectSheet({
    required String title,
    required List<String> items,
    required String? current,
  }) async {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        final allItems = ['전체', ...items];
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.65,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView.builder(
                    itemCount: allItems.length,
                    itemBuilder: (context, index) {
                      final v = allItems[index];
                      final isAll = v == '전체';
                      final selected = isAll ? (current == null) : (current == v);

                      return ListTile(
                        title: Text(v),
                        trailing: selected ? const Icon(Icons.check, color: Colors.green) : null,
                        onTap: () => Navigator.pop(context, isAll ? '' : v),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _loadStudies({bool refresh = false}) async {
    if (_isLoadingStudies) return;
    if (!refresh && !_hasMoreStudies) return;

    setState(() => _isLoadingStudies = true);

    try {
      final page = refresh ? 0 : _currentPage;
      final res = await _api.getStudies(
        keyword: _searchQuery.isNotEmpty ? _searchQuery : null,
        examType: _selectedExamType,   // null이면 전체
        region: _selectedRegion,       // null이면 전체 (※ api.dart 지원 필요)
        page: page,
        size: 20,
      );

      final data = res['data'] as Map<String, dynamic>?;
      final content = (data?['content'] as List<dynamic>?) ?? [];
      final isLast = (data?['last'] as bool?) ?? true;

      if (!mounted) return;
      setState(() {
        if (refresh) {
          _allStudies = content.cast<Map<String, dynamic>>();
          _currentPage = 1;
        } else {
          _allStudies.addAll(content.cast<Map<String, dynamic>>());
          _currentPage = page + 1;
        }
        _hasMoreStudies = !isLast;
        _isLoadingStudies = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingStudies = false);
      _showSnack('스터디 목록 로딩 실패: ${_prettyError(e)}');
    }
  }

  Future<void> _loadMyStudies() async {
    if (!widget.isLoggedIn) return;
    if (_isLoadingMyStudies) return;

    setState(() => _isLoadingMyStudies = true);

    try {
      if (_currentUserId == null) {
        final profileRes = await _api.getMyProfile();
        final profileData = profileRes['data'] as Map<String, dynamic>?;
        _currentUserId = profileData?['id'] as int?;
      }

      final res = await _api.getMyStudies();
      final data = (res['data'] as List<dynamic>?) ?? [];

      if (!mounted) return;
      setState(() {
        _myStudies = data.cast<Map<String, dynamic>>();
        _isLoadingMyStudies = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingMyStudies = false);
      _showSnack('내 스터디 로딩 실패: ${_prettyError(e)}');
    }
  }

  String _prettyError(Object e) {
    if (e is DioException) {
      final status = e.response?.statusCode;
      final msg = e.response?.data?['message'] ?? e.message ?? '요청 실패';
      return '($status) $msg';
    }
    return e.toString();
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final greetingName = widget.nickname.isNotEmpty ? widget.nickname : '닉네임';

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('스터디', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        elevation: 0,
      ),
      body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.isLoggedIn ? '$greetingName 님 합격하세요!' : '로그인하세요',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 15),
                Row(
                  children: [
                    _buildTabButton('스터디 찾기', _isSearching, () {
                      setState(() => _isSearching = true);
                    }),
                    const SizedBox(width: 10),
                    _buildTabButton('내 스터디', !_isSearching, () {
                      if (!widget.isLoggedIn) {
                        _showLoginWarning();
                        return;
                      }
                      setState(() => _isSearching = false);
                      _loadMyStudies();
                    }),
                  ],
                ),
                const SizedBox(height: 15),
                _isSearching ? _buildSearchTab() : _buildMyStudyTab(),
              ],
            ),
          ),
          if (_isSearching)
            Positioned(
              right: 20,
              bottom: 20,
              child: FloatingActionButton.extended(
                heroTag: 'study_create_fab',
                onPressed: () {
                  if (widget.isLoggedIn) {
                    _showCreateStudyDialog();
                  } else {
                    _showLoginWarning();
                  }
                },
                label: const Text('스터디 만들기', style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
                backgroundColor: const Color(0xFFCDE1AF),
                elevation: 2,
              ),
            ),
        ],
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('확인', style: TextStyle(color: Colors.green))),
        ],
      ),
    );
  }

  Widget _buildTabButton(String label, bool isSelected, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: isSelected ? Colors.grey[300] : Colors.grey[100],
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? Colors.black : Colors.grey,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchTab() {
    return Expanded(
      child: Column(
        children: [
          TextField(
            onChanged: (value) {
              setState(() => _searchQuery = value);
              if (value.trim().isEmpty) {
                _currentPage = 0;
                _hasMoreStudies = true;
                _loadStudies(refresh: true);
              }
            },
            onSubmitted: (_) => _loadStudies(refresh: true),
            decoration: InputDecoration(
              hintText: '스터디 검색',
              suffixIcon: IconButton(
                icon: const Icon(Icons.search),
                onPressed: () => _loadStudies(refresh: true),
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Colors.green),
              ),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          const SizedBox(height: 15),
          Row(
            children: [
              Expanded(
                child: _buildFilterButton(
                  title: '지역',
                  value: _selectedRegion ?? '전체',
                  onTap: () async {
                    final picked = await _showSelectSheet(
                      title: '지역 선택',
                      items: _regions,
                      current: _selectedRegion,
                    );
                    if (picked == null) return; // 취소
                    setState(() => _selectedRegion = picked.isEmpty ? null : picked);
                    _resetAndReloadStudies();
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _buildFilterButton(
                  title: '시험 종류',
                  value: _selectedExamType ?? '전체',
                  onTap: () async {
                    final picked = await _showSelectSheet(
                      title: '시험 종류 선택',
                      items: _examTypes,
                      current: _selectedExamType,
                    );
                    if (picked == null) return;
                    setState(() => _selectedExamType = picked.isEmpty ? null : picked);
                    _resetAndReloadStudies();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 15),
          Expanded(
            child: _isLoadingStudies && _allStudies.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : Builder(
                    builder: (context) {
                      final filteredStudies = _currentUserId != null
                          ? _allStudies.where((s) => s['authorId'] != _currentUserId).toList()
                          : _allStudies;

                      if (filteredStudies.isEmpty && !_hasMoreStudies) {
                        return const Center(child: Text('검색 결과가 없습니다.'));
                      }

                      return RefreshIndicator(
                        onRefresh: () => _loadStudies(refresh: true),
                        child: ListView.builder(
                          itemCount: filteredStudies.length + (_hasMoreStudies ? 1 : 0),
                          itemBuilder: (context, index) {
                            if (index == filteredStudies.length) {
                              _loadStudies();
                              return const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(child: CircularProgressIndicator()),
                              );
                            }
                            final study = filteredStudies[index];
                            return _buildStudyListItem(study, isSearchTab: true);
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildMyStudyTab() {
    if (_isLoadingMyStudies) {
      return const Expanded(child: Center(child: CircularProgressIndicator()));
    }

    final myCreatedStudies = _myStudies.where((s) => s['authorId'] == _currentUserId).toList();
    final myJoinedStudies = _myStudies.where((s) => s['authorId'] != _currentUserId).toList();

    return Expanded(
      child: RefreshIndicator(
        onRefresh: _loadMyStudies,
        child: ListView(
          children: [
            if (_myStudies.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: Text('참여 중인 스터디가 없습니다.')),
              ),
            ...myJoinedStudies.map((s) => _buildStudyListItem(s, isSearchTab: false)),
            if (myCreatedStudies.isNotEmpty) ...[
              const SizedBox(height: 20),
              const Text('내가 만든 스터디', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green)),
              const SizedBox(height: 10),
            ],
            ...myCreatedStudies.map((s) => _buildStudyListItem(s, isSearchTab: false, isOwner: true)),
          ],
        ),
      ),
    );
  }

  String _formatStudySubtitle(Map<String, dynamic> study) {
    final examType = study['examType'] ?? '';
    final region = study['region'] ?? '';
    final targetScore = study['targetScore'];
    final meetingFrequency = study['meetingFrequency'] ?? '';
    final studyType = _studyTypeToKorean(study['studyType']);

    final parts = <String>[
      if (examType.isNotEmpty) examType,
      if (region.isNotEmpty) region,
      if (targetScore != null) '$targetScore+',
      if (meetingFrequency.isNotEmpty) meetingFrequency,
      if (studyType.isNotEmpty) studyType,
    ];
    return parts.join(' · ');
  }

  String _studyTypeToKorean(String? studyType) {
    switch (studyType) {
      case 'ONLINE': return '온라인';
      case 'OFFLINE': return '오프라인';
      case 'HYBRID': return '혼합';
      default: return '';
    }
  }

  static const Map<String, String> _studyTypeKoToEn = {
    '온라인': 'ONLINE', '오프라인': 'OFFLINE', '혼합': 'HYBRID',
  };

  Widget _buildStudyListItem(Map<String, dynamic> study, {required bool isSearchTab, bool isOwner = false}) {
    final currentMembers = study['currentMembers'] ?? 0;
    final maxMembers = study['maxMembers'] ?? 0;
    final displayCount = '$currentMembers/$maxMembers명';
    final status = study['status'];
    final isClosed = status == 'CLOSED';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.grey[200]!))),
      child: ListTile(
        onTap: () {
          if (isSearchTab) {
            _showStudyDetail(study);
          } else {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatPage(studyTitle: study['title'] as String, studyId: study['id'] as int),
              ),
            );
          }
        },
        title: Row(
          children: [
            Expanded(child: Text(study['title'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold))),
            if (isClosed)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(4)),
                child: const Text('마감', style: TextStyle(fontSize: 10, color: Colors.grey)),
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_formatStudySubtitle(study), style: const TextStyle(fontSize: 12, color: Colors.grey)),
            if (isOwner) ...[
              const SizedBox(height: 8),
              Row(children: [
                _buildSmallButton('회원 관리', () => _showMemberManagement(study)),
                const SizedBox(width: 8),
                _buildSmallButton('신규 가입 요청', () => _showApplicationRequests(study)),
              ]),
            ],
          ],
        ),
        trailing: Text(displayCount, style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildSmallButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(8)),
        child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
      ),
    );
  }

  void _showStudyDetail(Map<String, dynamic> study) {
    final studyId = study['id'] as int;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: const Text(''), backgroundColor: Colors.white, elevation: 0),
          body: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 50),
                Text(study['title'] ?? '', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                Text(_formatStudySubtitle(study), style: const TextStyle(fontSize: 14, color: Colors.grey)),
                const SizedBox(height: 10),
                Text('${study['currentMembers'] ?? 0}/${study['maxMembers'] ?? 0}명',
                    style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                const SizedBox(height: 10),
                Text('작성자: ${study['authorNickname'] ?? ''}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 20),
                Text(study['content'] ?? '설명이 없습니다.', style: const TextStyle(fontSize: 14)),
                const Spacer(),
                if (study['status'] != 'CLOSED')
                  Center(
                    child: ElevatedButton(
                      onPressed: () {
                        if (widget.isLoggedIn) { _showApplyForm(study, studyId); }
                        else { _showLoginWarning(); }
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7CB342), minimumSize: const Size(200, 50), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                      child: const Text('가입 신청', style: TextStyle(color: Colors.white, fontSize: 18)),
                    ),
                  )
                else
                  const Center(child: Text('모집이 마감된 스터디입니다.', style: TextStyle(color: Colors.grey, fontSize: 16))),
                const SizedBox(height: 50),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showApplyForm(Map<String, dynamic> study, int studyId) {
    final controller = TextEditingController();
    bool isSubmitting = false;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StatefulBuilder(
          builder: (context, setPageState) => Scaffold(
            appBar: AppBar(title: const Text(''), backgroundColor: Colors.white, elevation: 0),
            body: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 20),
                  const Text('가입 신청서', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                  Text(study['title'] ?? '', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  Text(_formatStudySubtitle(study), style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 20),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(border: Border.all(color: Colors.grey)),
                      padding: const EdgeInsets.all(8),
                      child: TextField(controller: controller, maxLines: null, decoration: const InputDecoration(hintText: '가입 신청서를 작성해주세요.\n방장이 읽고 수락을 결정합니다.', border: InputBorder.none)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Center(
                    child: ElevatedButton(
                      onPressed: isSubmitting ? null : () async {
                        setPageState(() => isSubmitting = true);
                        try {
                          await _api.applyToStudy(studyId, message: controller.text);
                          if (!context.mounted) return;
                          Navigator.pop(context); Navigator.pop(context);
                          _showSnack('가입 신청이 제출되었습니다.');
                        } catch (e) {
                          if (!context.mounted) return;
                          setPageState(() => isSubmitting = false);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('신청 실패: ${_prettyError(e)}')));
                        }
                      },
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7CB342), minimumSize: const Size(120, 45), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
                      child: isSubmitting ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('제출', style: TextStyle(color: Colors.white, fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showMemberManagement(Map<String, dynamic> study) {
    final studyId = study['id'] as int;
    List<Map<String, dynamic>> members = [];
    bool isLoading = true;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StatefulBuilder(
          builder: (context, setPageState) {
            if (isLoading) {
              _api.getStudyMembers(studyId).then((res) {
                final data = (res['data'] as List<dynamic>?) ?? [];
                setPageState(() { members = data.cast<Map<String, dynamic>>(); isLoading = false; });
              }).catchError((e) { setPageState(() => isLoading = false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('멤버 로딩 실패: ${_prettyError(e)}'))); });
            }
            return Scaffold(
              appBar: AppBar(title: const Text(''), backgroundColor: Colors.white, elevation: 0),
              body: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('회원 관리', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                    Text(study['title'] ?? '', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_formatStudySubtitle(study), style: const TextStyle(fontSize: 12, color: Colors.grey)), Text('${members.length}/${study['maxMembers'] ?? 0}명', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold))]),
                    const Divider(),
                    Expanded(
                      child: isLoading ? const Center(child: CircularProgressIndicator()) : ListView.builder(
                        itemCount: members.length,
                        itemBuilder: (context, index) {
                          final member = members[index];
                          final isLeader = member['role'] == 'LEADER';
                          return ListTile(
                            leading: CircleAvatar(backgroundColor: Colors.grey[200], child: const Icon(Icons.face)),
                            title: Row(children: [Text(member['nickname'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold)), if (isLeader) Container(margin: const EdgeInsets.only(left: 8), padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: Colors.green[100], borderRadius: BorderRadius.circular(4)), child: const Text('방장', style: TextStyle(fontSize: 10, color: Colors.green)))]),
                            subtitle: Text(member['bio'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                            trailing: isLeader ? null : _buildSmallButton('내보내기', () { _showConfirmDialog('정말 내보내시겠습니까?', () async { try { await _api.removeMember(studyId, member['userId'] as int); setPageState(() { members.removeAt(index); }); _loadMyStudies(); } catch (e) { if (!context.mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('강퇴 실패: ${_prettyError(e)}'))); } }); }),
                          );
                        },
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

  void _showApplicationRequests(Map<String, dynamic> study) {
    final studyId = study['id'] as int;
    List<Map<String, dynamic>> applications = [];
    bool isLoading = true;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => StatefulBuilder(
          builder: (context, setPageState) {
            if (isLoading) {
              _api.getStudyApplications(studyId).then((res) {
                final data = (res['data'] as List<dynamic>?) ?? [];
                setPageState(() { applications = data.cast<Map<String, dynamic>>(); isLoading = false; });
              }).catchError((e) { setPageState(() => isLoading = false); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('신청 목록 로딩 실패: ${_prettyError(e)}'))); });
            }
            return Scaffold(
              appBar: AppBar(title: const Text(''), backgroundColor: Colors.white, elevation: 0),
              body: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('신규 가입 요청', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                    Text(study['title'] ?? '', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(_formatStudySubtitle(study), style: const TextStyle(fontSize: 12, color: Colors.grey)), Text('${study['currentMembers'] ?? 0}/${study['maxMembers'] ?? 0}명', style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold))]),
                    const Divider(),
                    Expanded(
                      child: isLoading ? const Center(child: CircularProgressIndicator()) : ListView.builder(
                        itemCount: applications.length,
                        itemBuilder: (context, index) {
                          final req = applications[index];
                          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            ListTile(
                              leading: CircleAvatar(backgroundColor: Colors.grey[200], child: const Icon(Icons.face)),
                              title: Text(req['applicantNickname'] ?? '', style: const TextStyle(fontWeight: FontWeight.bold)),
                              subtitle: Text(req['applicantBio'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                _buildSmallButton('수락', () { _showConfirmDialog('정말 수락하시겠습니까?', () async { try { await _api.acceptApplication(req['id'] as int); setPageState(() { applications.removeAt(index); }); _loadMyStudies(); _showSnack('수락되었습니다.'); } catch (e) { if (!context.mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('수락 실패: ${_prettyError(e)}'))); } }); }),
                                const SizedBox(width: 4),
                                _buildSmallButton('거절', () { _showConfirmDialog('수락을 거절하시겠습니까?', () async { try { await _api.rejectApplication(req['id'] as int); setPageState(() { applications.removeAt(index); }); _loadMyStudies(); _showSnack('거절되었습니다.'); } catch (e) { if (!context.mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('거절 실패: ${_prettyError(e)}'))); } }); }),
                              ]),
                            ),
                            if (req['message'] != null && (req['message'] as String).isNotEmpty)
                              Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), padding: const EdgeInsets.all(12), width: double.infinity, decoration: BoxDecoration(border: Border.all(color: Colors.grey[300]!), borderRadius: BorderRadius.circular(4)), child: Text(req['message'] ?? '', style: const TextStyle(fontSize: 13, color: Colors.black87))),
                          ]);
                        },
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

  void _showConfirmDialog(String message, VoidCallback onConfirm) {
    showDialog(context: context, builder: (context) => AlertDialog(content: Text(message), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소', style: TextStyle(color: Colors.grey))), TextButton(onPressed: () { Navigator.pop(context); onConfirm(); }, child: const Text('확인', style: TextStyle(color: Colors.green)))]));
  }

  void _showCreateStudyDialog() {
    String examType = 'TOEIC'; String city = '서울';
    final titleController = TextEditingController(); final scoreController = TextEditingController(); final contentController = TextEditingController();
    String meetingFrequency = '주 2회'; String studyTypeKo = '온라인'; final peopleController = TextEditingController(); bool isCreating = false;
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
        backgroundColor: const Color(0xFFCDE1AF), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)), title: const Center(child: Text('스터디 만들기', style: TextStyle(fontWeight: FontWeight.bold))),
        content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
          _buildDialogTextField('제목', titleController, '스터디 제목'),
          _buildDialogDropdown('시험 종류', examType, ['TOEIC', 'TOEFL', 'TEPS', 'OPIc'], (val) => setDialogState(() => examType = val!)),
          _buildDialogDropdown('지역', city, ['서울', '대전', '부산', '인천', '광주', '대구', '울산', '세종', '경기', '강원', '충북', '충남', '전북', '전남', '경북', '경남', '제주'], (val) => setDialogState(() => city = val!)),
          _buildDialogTextField('목표 점수', scoreController, '점수 입력', isNumber: true),
          _buildDialogDropdown('모임 횟수', meetingFrequency, ['주 1회', '주 2회', '주 3회', '주 4회', '주 5회', '주 6회', '매일'], (val) => setDialogState(() => meetingFrequency = val!)),
          _buildDialogDropdown('형태', studyTypeKo, ['온라인', '오프라인', '병행'], (val) => setDialogState(() => studyTypeKo = val!)),
          _buildDialogTextField('모집 인원', peopleController, '인원수 입력', isNumber: true),
          const SizedBox(height: 10),
          TextField(controller: contentController, maxLines: 3, decoration: InputDecoration(hintText: '스터디 설명 (선택)', border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)), filled: true, fillColor: Colors.white)),
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: isCreating ? null : () async {
              if (titleController.text.trim().isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('제목을 입력해주세요.'))); return; }
              setDialogState(() => isCreating = true);
              try {
                await _api.createStudy(title: titleController.text.trim(), content: contentController.text.trim().isNotEmpty ? contentController.text.trim() : null, examType: examType, region: city, targetScore: int.tryParse(scoreController.text), maxMembers: int.tryParse(peopleController.text), studyType: _studyTypeKoToEn[studyTypeKo], meetingFrequency: meetingFrequency);
                if (!context.mounted) return;
                Navigator.pop(context); _showSnack('스터디가 생성되었습니다.'); _loadStudies(refresh: true); setState(() => _isSearching = false); _loadMyStudies();
              } catch (e) { setDialogState(() => isCreating = false); if (!context.mounted) return; ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('생성 실패: ${_prettyError(e)}'))); }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
            child: isCreating ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('방 생성', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
          ),
        ])),
      )),
    );
  }

  Widget _buildDialogDropdown(String label, String value, List<String> items, ValueChanged<String?> onChanged) { return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [SizedBox(width: 70, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))), Expanded(child: DropdownButton<String>(value: value, isExpanded: true, items: items.map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(), onChanged: onChanged))])); }
  Widget _buildDialogTextField(String label, TextEditingController controller, String hint, {bool isNumber = false}) { return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [SizedBox(width: 70, child: Text(label, style: const TextStyle(fontWeight: FontWeight.bold))), Expanded(child: TextField(controller: controller, keyboardType: isNumber ? TextInputType.number : TextInputType.text, decoration: InputDecoration(hintText: hint, isDense: true)))])); }
}

class ApiResponseSnackBar extends SnackBar {
  ApiResponseSnackBar({super.key, required String message}) 
    : super(content: Text(message), duration: const Duration(seconds: 2));
}
