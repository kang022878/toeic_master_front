import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_naver_map/flutter_naver_map.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'pages/study_page.dart';
import 'pages/test_center_page.dart';
//import 'pages/ai_recommender_page.dart';
import 'pages/my_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await dotenv.load(fileName: ".env");
  debugPrint("NAVER_MAP_CLIENT_ID = ${dotenv.env['NAVER_MAP_CLIENT_ID']}");

  await FlutterNaverMap().init(
    clientId: dotenv.env['NAVER_MAP_CLIENT_ID'] ?? '',
    onAuthFailed: (ex) {
      debugPrint("네이버 지도 인증 실패: $ex");
    },
  );

  runApp(const ExamTalkApp());
}

class ExamTalkApp extends StatelessWidget {
  const ExamTalkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '이그잼톡',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const SplashScreen(),
    );
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  double _opacity = 1.0;

  @override
  void initState() {
    super.initState();
    _startSplashScreen();
  }

  Future<void> _startSplashScreen() async {
    await Future.delayed(const Duration(milliseconds: 2500));
    if (mounted) setState(() => _opacity = 0.0);
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const MainNavigationScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFCDE1AF),
      body: AnimatedOpacity(
        opacity: _opacity,
        duration: const Duration(milliseconds: 500),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(
                'assets/examtalk_logo.png',
                width: 160,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 24),
              const Text(
                '이그잼톡',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '스터디와 고사장 정보를 한 곳에',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.black54,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),

      ),
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {
  int _selectedIndex = 0;

  // ✅ 앱 전체 로그인/프로필 상태 (여기가 “단일 진실”)
  bool _isLoggedIn = false;
  String _email = '';
  String _nickname = '닉네임';
  String _myGoal = '목표를 적어보세요';
  File? _profileImage;

  @override
  Widget build(BuildContext context) {
    final pages = [
      StudyPage(
        isLoggedIn: _isLoggedIn,
        nickname: _nickname,
      ),
      const TestCenterPage(),
      //const AiRecommenderPage(),
      MyPage(
        isLoggedIn: _isLoggedIn,
        email: _email,
        nickname: _nickname,
        myGoal: _myGoal,
        profileImage: _profileImage,

        // ✅ MyPage에서 로그인 성공했을 때 부모 상태 갱신
        onLogin: (email, nickname, goal, image) {
          setState(() {
            _isLoggedIn = true;
            _email = email;
            _nickname = nickname;
            _myGoal = goal;
            _profileImage = image;
          });
        },

        // ✅ MyPage에서 로그아웃했을 때 부모 상태 갱신
        onLogout: () {
          setState(() {
            _isLoggedIn = false;
            _email = '';
            _nickname = '닉네임';
            _myGoal = '목표를 적어보세요';
            _profileImage = null;
          });
        },

        // ✅ MyPage에서 닉네임/목표/사진 수정했을 때 부모 상태 갱신
        onProfileUpdated: (nickname, goal, image) {
          setState(() {
            _nickname = nickname;
            _myGoal = goal;
            _profileImage = image;
          });
        },
      ),
    ];

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: pages,
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _selectedIndex,
        onTap: (index) => setState(() => _selectedIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.edit_note), label: '스터디'),
          BottomNavigationBarItem(icon: Icon(Icons.home), label: '고사장'),
          //BottomNavigationBarItem(icon: Icon(Icons.smart_toy), label: 'AI 추천'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: '마이페이지'),
        ],
      ),
    );
  }
}
