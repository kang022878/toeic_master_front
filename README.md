# toeic_master_front (이그잼톡)

스터디 모집/참여와 고사장 정보를 한 곳에서 제공하는 Flutter 앱입니다.

## 주요 기능
- 스터디 탐색/필터링, 스터디 생성 및 참여 신청
- 스터디 채팅(STOMP WebSocket)과 이미지 전송
- 네이버 지도 기반 고사장 지도, 리뷰/평점/좋아요, 사진 업로드
- 로그인/회원가입, 프로필/목표/점수 관리, 캘린더 일정 관리
- 로그인 사용자 대상 AI 추천(스터디/고사장)

## 기술 스택
- Flutter, Dart
- Dio, STOMP(WebSocket)
- flutter_naver_map, geolocator
- image_picker, shared_preferences, table_calendar

## 요구 사항
- Flutter SDK `3.11.0-296.2.beta` (pubspec 기준)

## 환경 변수
프로젝트 루트에 `.env` 파일을 생성하고 네이버 지도 클라이언트 ID를 설정합니다.

```env
NAVER_MAP_CLIENT_ID=YOUR_CLIENT_ID
```

## 실행 방법
```bash
flutter pub get
flutter run
```

## 서버 설정
API 기본 주소는 `lib/core/api_client.dart`에 정의되어 있습니다.
환경에 맞게 `baseUrl`을 변경하세요.

## 프로젝트 구조
- `lib/main.dart`: 앱 엔트리 및 네비게이션
- `lib/pages/`: 주요 화면(스터디, 고사장, 마이페이지, 채팅)
- `lib/core/`: API 클라이언트, 토큰 저장소
- `assets/`: 앱 로고 및 리소스

## 빌드
```bash
flutter build apk
flutter build ios
```
