import 'package:flutter/material.dart';
import 'package:dio/dio.dart';
import 'package:toeic_master_front/pages/chat_page.dart';
import 'package:toeic_master_front/core/api.dart';
import 'package:toeic_master_front/core/api_client.dart';
import 'package:toeic_master_front/core/token_storage.dart';

class StudyPage extends StatefulWidget {
  final bool isLoggedIn;
  final String nickname;
  final ValueNotifier<int> scoreNotifier;

  const StudyPage({
    super.key,
    required this.isLoggedIn,
    required this.nickname,
    required this.scoreNotifier,
  });

  @override
  State<StudyPage> createState() => _StudyPageState();
}

class _StudyPageState extends State<StudyPage> with SingleTickerProviderStateMixin {
  late final AnimationController _shineCtrl;

  bool _isSearching = true;

  final Set<int> _joinScoreTriedStudyIds = {};

  String? _selectedExamType; // null = 전체
  String? _selectedRegion;   // null = 전체

  // ===== AI 추천 =====
  List<Map<String, dynamic>> _recommendedStudies = [];
  bool _isLoadingRecommended = false;

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

    _shineCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _shineCtrl.dispose();
    super.dispose();
  }

  Future<void> _initPage() async {
    if (widget.isLoggedIn) {
      await _loadCurrentUserId();
      await _syncScoreFromServer();
      _loadRecommendedStudies(force: true);
    }
    _loadStudies();
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

  Future<void> _syncScoreFromServer() async {
    if (!widget.isLoggedIn) return;
    try {
      final profileRes = await _api.getMyProfile();
      final data = profileRes['data'] as Map<String, dynamic>?;
      final serverScore = (data?['score'] as num?)?.toInt();
      if (serverScore != null) {
        widget.scoreNotifier.value = serverScore;
      }
    } catch (e) {
      debugPrint('점수 동기화 실패: ${_prettyError(e)}');
    }
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

  Widget _shinyCardWrap({required Widget child, required BorderRadius borderRadius}) {
    return AnimatedBuilder(
      animation: _shineCtrl,
      builder: (context, _) {
        final t = _shineCtrl.value; // 0~1
        final pulse = 1.0 + (0.012 * (1 - (2 * (t - 0.5)).abs())); // 아주 약하게

        return Transform.scale(
          scale: pulse,
          child: ClipRRect(
            borderRadius: borderRadius,
            child: Stack(
              children: [
                child,

                // ✅ "빛 스윕" 오버레이 (원본 색 안 망가짐)
                IgnorePointer(
                  child: FractionalTranslation(
                    translation: Offset((t * 2.4) - 1.2, 0), // 왼→오
                    child: Transform.rotate(
                      angle: -0.35,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: 0.35,
                          child: Container(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [
                                  Colors.transparent,
                                  Colors.white.withOpacity(0.20),
                                  Colors.transparent,
                                ],
                                stops: const [0.35, 0.5, 0.65],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _progressWithRunnerAndFlag({required double progress}) {
    const barH = 10.0;
    const runnerSize = 28.0;
    const flagSize = 25.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        return TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: progress),
          duration: const Duration(milliseconds: 700),
          curve: Curves.easeOutCubic,
          builder: (context, value, _) {
            // runner x: 채워진 바 끝을 따라가게
            final runnerX = (maxW - runnerSize) * value;

            // runner 살짝 통통 튀는 느낌(shineCtrl 재사용)
            final bob = (0.5 - ( (_shineCtrl.value - 0.5).abs() )) * 6.0; // 0~3 정도

            return SizedBox(
              height: 34,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // ✅ 바(회색) + 채워진 바(초록)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 16,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: Stack(
                        children: [
                          Container(height: barH, color: const Color(0xFFEFEFEF)),
                          FractionallySizedBox(
                            widthFactor: value.clamp(0.0, 1.0),
                            child: Container(height: barH, color: const Color(0xFF7CB342)),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ✅ 깃발: 회색 바 오른쪽 끝 고정
                  Positioned(
                    right: -2,
                    top: 6,
                    child: const Text(
                      '🏁',
                      style: TextStyle(
                        fontSize: 22, // ✅ 더 크게 하고 싶으면 24~28 추천
                        height: 1.0,
                      ),
                    ),
                  ),

                  // ✅ 달리는 사람: 채워지는 바 끝에 붙어서 이동
                  Positioned(
                    left: runnerX,
                    top: 0 - bob,
                    child: const Text(
                      '🏃🏻‍♂️‍➡️',
                      style: TextStyle(
                        fontSize: 28, // ✅ 여기 숫자 키우면 더 커짐 (예: 32, 36)
                        height: 1.0,
                      ),
                    ),
                  ),

                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _shinyPillBadge({required Widget child}) {
    return AnimatedBuilder(
      animation: _shineCtrl,
      builder: (context, _) {
        final t = _shineCtrl.value; // 0.0 ~ 1.0

        // ⭐ 반짝 이동 위치
        final dx = (t * 3.0) - 1.0;

        // ⭐ 살짝 두근거리는 펄스 효과 (중앙에서 가장 큼)
        final pulse =
            1.0 + (0.03 * (1 - (2 * (t - 0.5)).abs()));

        return Transform.scale(
          scale: pulse, // ✅ 여기서 크기 변화
          child: ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (rect) {
              return LinearGradient(
                begin: Alignment(-1.0 + dx, -0.2),
                end: Alignment(1.0 + dx, 0.2),
                colors: [
                  Colors.transparent,
                  Colors.white.withOpacity(0.55),
                  Colors.transparent,
                ],
                stops: const [0.35, 0.5, 0.65],
              ).createShader(rect);
            },
            child: child, // ← 원래 Lv.0 UI
          ),
        );
      },
    );
  }

  @override
  void didUpdateWidget(covariant StudyPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isLoggedIn != widget.isLoggedIn) {
      _syncScoreFromServer();
      if (widget.isLoggedIn) {
        _loadCurrentUserId();
        _loadMyStudies();
        _loadRecommendedStudies(force: true);
      } else {
        setState(() {
          _myStudies = [];
          _currentUserId = null;
          _recommendedStudies = [];
        });
      }
    }
  }

  void _resetAndReloadStudies() {
    _currentPage = 0;
    _hasMoreStudies = true;
    _loadStudies(refresh: true);
    _loadRecommendedStudies(force: true);
  }

  Widget _buildScoreGamificationCard(int score) {
    final level = _levelFromScore(score);
    final next = _nextThreshold(level);
    final progress = _progressInLevel(score);
    final remain = (next - score).clamp(0, 1 << 30);
    final isMax = (level >= 5 && score >= 1000);

    String titleByLevel() {
      switch (level) {
        case 0:
          return '🔥 워밍업 중';
        case 1:
          return '🤓 루키 수험생';
        case 2:
          return '✏️ 집중 모드';
        case 3:
          return '🧐 실전 감각 ON';
        case 4:
          return '🧭 합격권 진입';
        default:
          return '👑 마스터';
      }
    }

    IconData iconByLevel() {
      switch (level) {
        case 0:
          return Icons.spa;
        case 1:
          return Icons.emoji_events_outlined;
        case 2:
          return Icons.local_fire_department;
        case 3:
          return Icons.bolt;
        case 4:
          return Icons.workspace_premium;
        default:
          return Icons.stars;
      }
    }

    // ✅ 카드 전체 반짝(펄스+스윕) 적용 + ✅ 게이지에 러너/깃발 적용
    return _shinyCardWrap(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            colors: [Color(0xFFF3FBE9), Color(0xFFFFFFFF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: const Color(0xFFCDE1AF)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 상단: 뱃지 + 타이틀
            Row(
              children: [
                _shinyPillBadge(
                  child: Container(
                    padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF7CB342).withOpacity(0.14),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      children: [

                        Icon(iconByLevel(),
                            size: 16, color: const Color(0xFF4E8F2E)),
                        const SizedBox(width: 6),
                        Text(
                          '합격 게이지 Lv.$level',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF4E8F2E),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: RichText(
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    text: TextSpan(
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black),
                      children: [
                        TextSpan(
                          text: '   내 등급: ',
                          style: TextStyle(color: Colors.black.withOpacity(0.55)),
                        ),
                        TextSpan(text: titleByLevel()),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // 점수 크게
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$score',
                  style: const TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF2F4A1F),
                  ),
                ),
                const SizedBox(width: 6),
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text('점',
                      style: TextStyle(
                          fontSize: 14,
                          color: Colors.black54,
                          fontWeight: FontWeight.w700)),
                ),
                const Spacer(),
                // “오늘도 한 발 더” 같은 발표용 문구
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFCDE1AF).withOpacity(0.55),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Text(
                    '스터디 참여 & 리뷰 작성으로 점수를 올려봐요!',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF436B2D)),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 10),

            // ✅ 게이지(러너 + 깃발)
            _progressWithRunnerAndFlag(progress: progress),

            const SizedBox(height: 8),

            // 하단 설명
            Text(
              isMax
                  ? '현재 MAX 레벨이에요. 유지하면서 실전 감각을 끌어올려요!'
                  : '다음 레벨까지 $remain점 남았어요.',
              style: const TextStyle(fontSize: 12, color: Color(0xF44336B8), height: 1.25),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAiRecommendationSection() {
    // 로그인인데 성향 없으면 404/빈 배열 등 올 수 있으니 Empty UI 포함
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: const LinearGradient(
          colors: [Color(0xFFE9F7D6), Color(0xFFFFFFFF)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: const Color(0xFFCDE1AF)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF7CB342).withOpacity(0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  children: const [
                    Icon(Icons.auto_awesome, size: 16, color: Color(0xFF4E8F2E)),
                    SizedBox(width: 6),
                    Text(
                      'AI 추천',
                      style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF4E8F2E)),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _isLoadingRecommended ? null : () => _loadRecommendedStudies(force: true),
                child: const Text('새로고침', style: TextStyle(color: Color(0xFF4E8F2E))),
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Text(
            '나에게 맞는 AI 추천 스터디',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            '마이페이지 > 나의 성향을 기반으로 추천해요.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),

          if (_isLoadingRecommended)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_recommendedStudies.isEmpty)
            _buildAiEmptyState()
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final cards = _recommendedStudies.take(2).toList();

                if (cards.isEmpty) {
                  return _buildAiEmptyState();
                }

                // ✅ 1개만 있을 때
                if (cards.length == 1) {
                  return SizedBox(
                    height: 155,
                    child: Row(
                      children: [
                        Expanded(child: _buildAiStudyCard(cards[0], compact: true)),
                        const SizedBox(width: 10),
                        const Expanded(child: SizedBox()), // 빈칸으로 균형 유지(선택)
                      ],
                    ),
                  );
                }

                // ✅ 2개 이상일 때
                return SizedBox(
                  height: 155,
                  child: Row(
                    children: [
                      Expanded(child: _buildAiStudyCard(cards[0], compact: true)),
                      const SizedBox(width: 10),
                      Expanded(child: _buildAiStudyCard(cards[1], compact: true)),
                    ],
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildAiEmptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Row(
        children: [
          const Icon(Icons.psychology_alt, color: Color(0xFF7CB342)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '아직 추천할 스터디가 없어요.\n마이페이지에서 성향을 저장했는지 확인해보세요.',
              style: TextStyle(color: Colors.grey[700], fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAiStudyCard(Map<String, dynamic> study, {bool compact = false}) {
    final currentMembers = study['currentMembers'] ?? 0;
    final maxMembers = study['maxMembers'] ?? 0;
    final displayCount = '$currentMembers/$maxMembers명';
    final isClosed = (study['status'] == 'CLOSED');

    final pad = compact ? 10.0 : 12.0;
    final titleSize = compact ? 13.5 : 15.0;
    final subSize = compact ? 11.0 : 12.0;
    final iconBox = compact ? 30.0 : 34.0;
    final iconSize = compact ? 16.0 : 18.0;
    final btnH = compact ? 36.0 : 40.0;

    return Container(
      padding: EdgeInsets.all(pad),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey[200]!),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: iconBox,
                height: iconBox,
                decoration: BoxDecoration(
                  color: const Color(0xFFCDE1AF).withOpacity(0.65),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.school, color: const Color(0xFF4E8F2E), size: iconSize),
              ),
              const Spacer(),
              Text(
                displayCount,
                style: TextStyle(
                  color: Colors.green,
                  fontWeight: FontWeight.bold,
                  fontSize: compact ? 12 : 13,
                ),
              ),
            ],
          ),
          SizedBox(height: compact ? 6 : 8),
          Text(
            study['title'] ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: titleSize),
          ),
          const SizedBox(height: 3),
          Expanded( // ✅ 남는 영역에서만 설명 보여주고 버튼 공간 확보
            child: Text(
              _formatStudySubtitle(study),
              maxLines: compact ? 2 : 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: subSize, color: Colors.grey, height: 1.25),
              strutStyle: const StrutStyle(height: 1.25, forceStrutHeight: true),
            ),
          ),
          const SizedBox(height: 6),

          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => _showStudyDetail(study),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: Colors.grey[300]!),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    minimumSize: Size(0, btnH),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text('상세', style: TextStyle(color: Colors.black87, fontSize: compact ? 12 : 13)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton(
                  onPressed: (!widget.isLoggedIn || isClosed)
                      ? null
                      : () {
                    final studyId = study['id'] as int;
                    _showApplyForm(study, studyId);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF7CB342),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    minimumSize: Size(0, btnH),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(
                    isClosed ? '마감' : '신청',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: compact ? 12 : 13),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
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

  Future<void> _loadRecommendedStudies({bool force = false}) async {
    if (!widget.isLoggedIn) return;
    if (_isLoadingRecommended) return;
    if (!force && _recommendedStudies.isNotEmpty) return;

    setState(() => _isLoadingRecommended = true);

    try {
      final res = await _api.getStudyRecommendations(
        examType: _selectedExamType,
        region: _selectedRegion,
        topK: 10,
      );

      final data = res['data'];
      final list = (data is List) ? data : <dynamic>[];

      if (!mounted) return;
      setState(() {
        _recommendedStudies = list.cast<Map<String, dynamic>>();
        _isLoadingRecommended = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoadingRecommended = false);
      debugPrint('추천 스터디 로딩 실패: ${_prettyError(e)}');
    }
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
  Future<void> _tryGrantJoinStudyScore(List<Map<String, dynamic>> myStudies) async {
    if (!widget.isLoggedIn) return;
    if (_currentUserId == null) return;

    // "내가 참여한 스터디"만 (내가 만든 스터디 제외)
    final joined = myStudies.where((s) => (s['authorId'] as int?) != _currentUserId).toList();

    for (final s in joined) {
      final studyId = (s['id'] as num).toInt();

      // 프론트 세션 중복 방지
      if (_joinScoreTriedStudyIds.contains(studyId)) continue;
      _joinScoreTriedStudyIds.add(studyId);

      try {
        final scoreRes = await _api.addScore(type: 'JOIN_STUDY', refId: studyId);
        final data = scoreRes['data'] as Map<String, dynamic>?;

        final delta = (data?['delta'] as num?)?.toInt() ?? 0;
        final total = (data?['score'] as num?)?.toInt() ?? 0;

        if (delta > 0) {
          widget.scoreNotifier.value = total;
          if (!mounted) return;
          _showSnack('스터디 가입 +$delta점! (총 $total점)');
        }
      } catch (e) {
        // 실패해도 앱 사용에는 지장 없게 조용히 처리
        debugPrint('JOIN_STUDY 점수 지급 실패: ${_prettyError(e)}');
      }
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

      await _tryGrantJoinStudyScore(_myStudies);
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
        backgroundColor: Colors.white,
        elevation: 0,
        toolbarHeight: 44,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/examtalk_logo.png',
              height: 30, // 🔹 작게
            ),
            const SizedBox(width: 5),
            const Text(
              '스터디',
              style: TextStyle(
                fontSize : 20,
                fontWeight: FontWeight.bold,
                color: Colors.black,
              ),
            ),
          ],
        ),
      ),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () async {
              if (_isSearching) {
                await _loadStudies(refresh: true);
                await _loadRecommendedStudies(force: true);
              } else {
                await _loadMyStudies();
              }
            },
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                // ✅ 전체 패딩
                SliverPadding(
                  padding: const EdgeInsets.all(16.0),
                  sliver: SliverList(
                    delegate: SliverChildListDelegate(
                      [
                        Text(
                          widget.isLoggedIn ? '$greetingName 님 합격하세요! 🍀' : '로그인하세요',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),

                        if (widget.isLoggedIn) ...[
                          const SizedBox(height: 10),
                          ValueListenableBuilder<int>(
                            valueListenable: widget.scoreNotifier,
                            builder: (context, score, _) => _buildScoreGamificationCard(score),
                          ),
                        ],

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

                        // ✅ 탭별 상단 UI(검색창/필터 같은 것들)
                        if (_isSearching) ..._buildSearchHeaderWidgets(),
                        if (!_isSearching) ..._buildMyTabHeaderWidgets(),
                      ],
                    ),
                  ),
                ),

                // ✅ 탭별 “리스트” 부분을 슬리버로 붙이기
                if (_isSearching) ..._buildSearchListSlivers(),
                if (!_isSearching) ..._buildMyStudyListSlivers(),

                const SliverToBoxAdapter(child: SizedBox(height: 90)), // 하단 여백
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
                  if (widget.isLoggedIn) _showCreateStudyDialog();
                  else _showLoginWarning();
                },
                label: const Text('스터디 만들기',
                    style: TextStyle(color: Colors.black87, fontWeight: FontWeight.bold)),
                backgroundColor: const Color(0xFFCDE1AF),
                elevation: 2,
              ),
            ),
        ],
      ),
    );
  }
  List<Widget> _buildSearchHeaderWidgets() {
    return [
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
                if (picked == null) return;
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
    ];
  }
  List<Widget> _buildSearchListSlivers() {
    final filteredStudies = _currentUserId != null
        ? _allStudies.where((s) => s['authorId'] != _currentUserId).toList()
        : _allStudies;

    // 처음 로딩
    if (_isLoadingStudies && _allStudies.isEmpty) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }

    // 결과 없음
    if (filteredStudies.isEmpty && !_hasMoreStudies) {
      return const [
        SliverFillRemaining(
          hasScrollBody: false,
          child: Center(child: Text('검색 결과가 없습니다.')),
        ),
      ];
    }

    final hasAiHeader = widget.isLoggedIn;

    // ✅ 아이템 개수: (AI헤더 1개) + 결과들 + (더 불러오는 로더 1개)
    final itemCount = (hasAiHeader ? 1 : 0) + filteredStudies.length + (_hasMoreStudies ? 1 : 0);

    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
                (context, index) {
              final offset = hasAiHeader ? 1 : 0;

              if (hasAiHeader && index == 0) {
                return _buildAiRecommendationSection();
              }

              // 마지막 로딩 인디케이터
              final lastIndex = offset + filteredStudies.length;
              if (_hasMoreStudies && index == lastIndex) {
                _loadStudies(); // 다음 페이지 로드 트리거
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }

              final study = filteredStudies[index - offset];
              return _buildStudyListItem(study, isSearchTab: true);
            },
            childCount: itemCount,
          ),
        ),
      ),
    ];
  }
  List<Widget> _buildMyTabHeaderWidgets() => []; // 필요하면 나중에 헤더 넣기

  List<Widget> _buildMyStudyListSlivers() {
    if (_isLoadingMyStudies) {
      return const [
        SliverFillRemaining(hasScrollBody: false, child: Center(child: CircularProgressIndicator())),
      ];
    }

    final myCreatedStudies = _myStudies.where((s) => s['authorId'] == _currentUserId).toList();
    final myJoinedStudies = _myStudies.where((s) => s['authorId'] != _currentUserId).toList();

    if (_myStudies.isEmpty) {
      return const [
        SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('참여 중인 스터디가 없습니다.'))),
      ];
    }

    return [
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        sliver: SliverList(
          delegate: SliverChildBuilderDelegate(
                (context, index) => _buildStudyListItem(myJoinedStudies[index], isSearchTab: false),
            childCount: myJoinedStudies.length,
          ),
        ),
      ),
      if (myCreatedStudies.isNotEmpty)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 10),
            child: Text('내가 만든 스터디',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green)),
          ),
        ),
      if (myCreatedStudies.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
                  (context, index) => _buildStudyListItem(myCreatedStudies[index], isSearchTab: false, isOwner: true),
              childCount: myCreatedStudies.length,
            ),
          ),
        ),
    ];
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
    final filteredStudies = _currentUserId != null
        ? _allStudies.where((s) => s['authorId'] != _currentUserId).toList()
        : _allStudies;

    final itemCount =
    // 상단 고정 섹션들(검색창/필터/AI추천 등)은 Sliver로 넣을 거라 itemCount에 포함 안 함
    filteredStudies.length + (_hasMoreStudies ? 1 : 0);

    return Expanded(
      child: RefreshIndicator(
        onRefresh: () async {
          await _loadStudies(refresh: true);
          await _loadRecommendedStudies(force: true);
        },
        child: CustomScrollView(
          slivers: [
            // ✅ 검색창
            SliverToBoxAdapter(
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

                  // ✅ 필터 2개
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
                            if (picked == null) return;
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

                  // ✅ AI 추천(로그인일 때만)
                  if (widget.isLoggedIn) ...[
                    _buildAiRecommendationSection(),
                  ],
                ],
              ),
            ),

            // ✅ 목록(로딩/빈 상태 처리)
            if (_isLoadingStudies && _allStudies.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (filteredStudies.isEmpty && !_hasMoreStudies)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('검색 결과가 없습니다.')),
              )
            else
              SliverList(
                delegate: SliverChildBuilderDelegate(
                      (context, index) {
                    // 마지막 로딩 인디케이터
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
                  childCount: itemCount,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMyStudyTab() {
    if (_isLoadingMyStudies) {
      return const Expanded(child: Center(child: CircularProgressIndicator()));
    }

    final myCreatedStudies =
    _myStudies.where((s) => s['authorId'] == _currentUserId).toList();
    final myJoinedStudies =
    _myStudies.where((s) => s['authorId'] != _currentUserId).toList();

    return Expanded(
      child: RefreshIndicator(
        onRefresh: _loadMyStudies,
        child: CustomScrollView(
          slivers: [
            // ✅ 빈 상태
            if (_myStudies.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('참여 중인 스터디가 없습니다.')),
              )
            else ...[
              // ✅ 내가 참여한 스터디 목록
              SliverList(
                delegate: SliverChildBuilderDelegate(
                      (context, index) {
                    final s = myJoinedStudies[index];
                    return _buildStudyListItem(s, isSearchTab: false);
                  },
                  childCount: myJoinedStudies.length,
                ),
              ),

              // ✅ 내가 만든 스터디 헤더
              if (myCreatedStudies.isNotEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(top: 20, bottom: 10),
                    child: Text(
                      '내가 만든 스터디',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                      ),
                    ),
                  ),
                ),

              // ✅ 내가 만든 스터디 목록
              if (myCreatedStudies.isNotEmpty)
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                        (context, index) {
                      final s = myCreatedStudies[index];
                      return _buildStudyListItem(
                        s,
                        isSearchTab: false,
                        isOwner: true,
                      );
                    },
                    childCount: myCreatedStudies.length,
                  ),
                ),

              // ✅ 맨 아래 여백(플로팅 버튼/네비게이션과 겹침 방지용)
              const SliverToBoxAdapter(child: SizedBox(height: 80)),
            ],
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
      case 'HYBRID': return '병행';
      default: return '';
    }
  }

  static const Map<String, String> _studyTypeKoToEn = {
    '온라인': 'ONLINE', '오프라인': 'OFFLINE', '병행': 'HYBRID',
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
                const SizedBox(width: 8),
                _buildSmallButton('삭제', () => _showDeleteStudyDialog(study), isDestructive: true),
              ]),
            ],
            // ✅ 내가 참여한 스터디(내가 만든 것 제외)에만 나가기 버튼 표시
            if (!isSearchTab && !isOwner) ...[
              const SizedBox(height: 8),
              Row(children: [
                _buildSmallButton('나가기', () => _showLeaveStudyDialog(study)),
              ]),
            ],
          ],
        ),
        trailing: Text(displayCount, style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildSmallButton(String label, VoidCallback onTap, {bool isDestructive = false}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isDestructive ? Colors.red[100] : Colors.grey[300],
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: isDestructive ? Colors.red : Colors.black,
          ),
        ),
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

  void _showLeaveStudyDialog(Map<String, dynamic> study) {
    final studyId = study['id'] as int;
    final studyTitle = study['title'] ?? '스터디';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('스터디 나가기'),
        content: Text('\'$studyTitle\' 스터디에서 나가시겠습니까?\n\n나가면 채팅 내역을 더 이상 볼 수 없습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await _api.leaveStudy(studyId);
                _showSnack('스터디에서 나갔습니다.');
                _loadMyStudies(); // 목록 새로고침
              } catch (e) {
                _showSnack('나가기 실패: ${_prettyError(e)}');
              }
            },
            child: const Text('나가기', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showDeleteStudyDialog(Map<String, dynamic> study) {
    final studyId = study['id'] as int;
    final studyTitle = study['title'] ?? '스터디';
    final currentMembers = study['currentMembers'] ?? 0;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('스터디 삭제'),
        content: Text(
          '\'$studyTitle\' 스터디를 삭제하시겠습니까?\n\n'
          '${currentMembers > 1 ? '⚠️ 현재 ${currentMembers}명의 멤버가 있습니다.\n' : ''}'
          '삭제하면 모든 채팅 내역과 데이터가 영구적으로 삭제됩니다.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('취소', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              try {
                await _api.deleteStudy(studyId);
                _showSnack('스터디가 삭제되었습니다.');
                _loadMyStudies(); // 목록 새로고침
                _loadStudies(refresh: true); // 전체 목록도 새로고침
              } catch (e) {
                _showSnack('삭제 실패: ${_prettyError(e)}');
              }
            },
            child: const Text('삭제', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
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
