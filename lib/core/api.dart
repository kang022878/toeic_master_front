import 'package:dio/dio.dart';
import 'api_client.dart';
import 'dart:io';

class Api {
  Api(this._client);

  final ApiClient _client;

  // 로그인: /api/auth/login
  Future<String> login({
    required String email,
    required String password,
  }) async {
    final res = await _client.dio.post(
      '/api/auth/login',
      data: {'email': email, 'password': password},
    );

    // 서버 응답 형태: { success, message, data: { accessToken, ... } }
    final data = res.data['data'];
    final token = data['accessToken'] as String?;
    if (token == null || token.isEmpty) {
      throw DioException(
        requestOptions: res.requestOptions,
        message: 'accessToken이 응답에 없습니다.',
      );
    }
    return token;
  }

  // 고사장 목록: /api/schools
  Future<List<dynamic>> getSchools() async {
    final res = await _client.dio.get('/api/schools');
    return (res.data['data'] as List<dynamic>);
  }

  Future<Map<String, dynamic>> uploadMyProfileImage(File imageFile) async {
    final formData = FormData.fromMap({
      'image': await MultipartFile.fromFile(
        imageFile.path,
        filename: imageFile.path.split('/').last,
      ),
    });

    final res = await _client.dio.post(
      '/api/users/me/profile-image',
      data: formData,
      // ✅ Dio가 multipart boundary까지 자동으로 설정하게 둔다
      options: Options(
        headers: {
          // ❗ ApiClient의 기본 Content-Type: application/json 을 덮어씌우기 위해 null로 제거
          Headers.contentTypeHeader: null,
        },
      ),
    );

    return (res.data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> deleteMyProfileImage() async {
    final res = await _client.dio.delete('/api/users/me/profile-image');
    return (res.data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> signup({
    required String email,
    required String password,
    required String nickname,
  }) async {
    final res = await _client.dio.post(
      '/api/auth/signup',
      data: {'email': email, 'password': password, 'nickname': nickname},
    );
    return (res.data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> getMyProfile() async {
    final res = await _client.dio.get('/api/users/me');
    return (res.data as Map<String, dynamic>);
  }

  Future<dynamic> updateMyProfile({
    required String nickname,
    required String bio,
    String? tendency,
  }) async {
    final res = await _client.dio.put(
      '/api/users/me',
      data: {
        'nickname': nickname,
        'bio': bio,
        'tendency': tendency ?? '',
      },
    );
    return res.data;
  }

  // ========== Study API ==========

  /// 스터디 목록 조회
  Future<Map<String, dynamic>> getStudies({
    String? keyword,
    String? examType,
    String? region,
    int? minScore,
    int? maxScore,
    int page = 0,
    int size = 10,
    String sort = 'createdAt,desc',
  }) async {
    final queryParams = <String, dynamic>{
      'page': page,
      'size': size,
      'sort': sort,
    };
    if (keyword != null && keyword.isNotEmpty) queryParams['keyword'] = keyword;
    if (examType != null && examType.isNotEmpty) queryParams['examType'] = examType;
    if (region != null && region.isNotEmpty) queryParams['region'] = region;
    if (minScore != null) queryParams['minScore'] = minScore;
    if (maxScore != null) queryParams['maxScore'] = maxScore;

    final res = await _client.dio.get('/api/studies', queryParameters: queryParams);
    return (res.data as Map<String, dynamic>);
  }

  /// 스터디 상세 조회
  Future<Map<String, dynamic>> getStudy(int studyId) async {
    final res = await _client.dio.get('/api/studies/$studyId');
    return (res.data as Map<String, dynamic>);
  }

  /// 스터디 생성
  Future<Map<String, dynamic>> createStudy({
    required String title,
    String? content,
    required String examType,
    required String region,
    int? targetScore,
    int? maxMembers,
    String? studyType, // ONLINE, OFFLINE, HYBRID
    String? meetingFrequency,
  }) async {
    final data = <String, dynamic>{
      'title': title,
      'examType': examType,
      'region': region,
    };
    if (content != null) data['content'] = content;
    if (targetScore != null) data['targetScore'] = targetScore;
    if (maxMembers != null) data['maxMembers'] = maxMembers;
    if (studyType != null) data['studyType'] = studyType;
    if (meetingFrequency != null) data['meetingFrequency'] = meetingFrequency;

    final res = await _client.dio.post('/api/studies', data: data);
    return (res.data as Map<String, dynamic>);
  }

  /// 스터디 수정
  Future<Map<String, dynamic>> updateStudy({
    required int studyId,
    required String title,
    String? content,
    required String examType,
    required String region,
    int? targetScore,
    int? maxMembers,
    String? studyType,
    String? meetingFrequency,
  }) async {
    final data = <String, dynamic>{
      'title': title,
      'examType': examType,
      'region': region,
    };
    if (content != null) data['content'] = content;
    if (targetScore != null) data['targetScore'] = targetScore;
    if (maxMembers != null) data['maxMembers'] = maxMembers;
    if (studyType != null) data['studyType'] = studyType;
    if (meetingFrequency != null) data['meetingFrequency'] = meetingFrequency;

    final res = await _client.dio.put('/api/studies/$studyId', data: data);
    return (res.data as Map<String, dynamic>);
  }

  /// 스터디 삭제
  Future<void> deleteStudy(int studyId) async {
    await _client.dio.delete('/api/studies/$studyId');
  }

  /// 스터디 마감
  Future<Map<String, dynamic>> closeStudy(int studyId) async {
    final res = await _client.dio.post('/api/studies/$studyId/close');
    return (res.data as Map<String, dynamic>);
  }

  // ========== Study Application API ==========

  /// 스터디 참가 신청
  Future<Map<String, dynamic>> applyToStudy(int studyId, {String? message}) async {
    final data = <String, dynamic>{};
    if (message != null) data['message'] = message;

    final res = await _client.dio.post('/api/studies/$studyId/applications', data: data);
    return (res.data as Map<String, dynamic>);
  }

  /// 스터디 신청 목록 조회 (방장용)
  Future<Map<String, dynamic>> getStudyApplications(int studyId) async {
    final res = await _client.dio.get('/api/studies/$studyId/applications');
    return (res.data as Map<String, dynamic>);
  }

  /// 신청 수락
  Future<Map<String, dynamic>> acceptApplication(int applicationId) async {
    final res = await _client.dio.post('/api/applications/$applicationId/accept');
    return (res.data as Map<String, dynamic>);
  }

  /// 신청 거절
  Future<Map<String, dynamic>> rejectApplication(int applicationId) async {
    final res = await _client.dio.post('/api/applications/$applicationId/reject');
    return (res.data as Map<String, dynamic>);
  }

  /// 스터디 멤버 목록 조회
  Future<Map<String, dynamic>> getStudyMembers(int studyId) async {
    final res = await _client.dio.get('/api/studies/$studyId/members');
    return (res.data as Map<String, dynamic>);
  }

  /// 멤버 강퇴
  Future<void> removeMember(int studyId, int userId) async {
    await _client.dio.delete('/api/studies/$studyId/members/$userId');
  }

  /// 스터디 탈퇴
  Future<void> leaveStudy(int studyId) async {
    await _client.dio.delete('/api/studies/$studyId/leave');
  }

  // ========== User Study API ==========

  /// 내가 참여 중인 스터디 목록
  Future<Map<String, dynamic>> getMyStudies() async {
    final res = await _client.dio.get('/api/users/me/studies');
    return (res.data as Map<String, dynamic>);
  }

  // ========== Chat API ==========

  /// 채팅 메시지 조회
  Future<Map<String, dynamic>> getChatMessages(
    int studyId, {
    int page = 0,
    int size = 50,
    String sort = 'createdAt,desc',
  }) async {
    final res = await _client.dio.get(
      '/api/studies/$studyId/messages',
      queryParameters: {
        'page': page,
        'size': size,
        'sort': sort,
      },
    );
    return (res.data as Map<String, dynamic>);
  }

  /// 채팅 이미지 업로드
  Future<String> uploadChatImage(int studyId, File imageFile) async {
    final formData = FormData.fromMap({
      'file': await MultipartFile.fromFile(
        imageFile.path,
        filename: imageFile.path.split('/').last,
      ),
    });

    final res = await _client.dio.post(
      '/api/studies/$studyId/chat/images',
      data: formData,
      options: Options(
        headers: {
          Headers.contentTypeHeader: null,
        },
      ),
    );

    final data = res.data as Map<String, dynamic>;
    return data['data'] as String; // imageKey 반환
  }

  Future<Map<String, dynamic>> getStudyRecommendations({
    String? examType,
    String? region,
    int? minScore,
    int? maxScore,
    int topK = 10,
  }) async {
    final queryParams = <String, dynamic>{'topK': topK};
    if (examType != null && examType.isNotEmpty) queryParams['examType'] = examType;
    if (region != null && region.isNotEmpty) queryParams['region'] = region;
    if (minScore != null) queryParams['minScore'] = minScore;
    if (maxScore != null) queryParams['maxScore'] = maxScore;

    final res = await _client.dio.get(
      '/api/studies/recommendations',
      queryParameters: queryParams,
    );
    return (res.data as Map<String, dynamic>);
  }

  Future<Map<String, dynamic>> addScore({
    required String type, // 'JOIN_STUDY' | 'WRITE_REVIEW'
    required int refId,
  }) async {
    final res = await _client.dio.post(
      '/api/users/me/score',
      data: {'type': type, 'refId': refId},
    );
    return res.data as Map<String, dynamic>;
  }

}
