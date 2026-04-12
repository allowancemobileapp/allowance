// lib/main.dart
import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Firebase
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';

import 'models/user_preferences.dart';
import 'screens/introduction/introduction_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/profile/edit_profile_screen.dart';
import 'shared/services/fcm_service.dart';
import 'widgets/custom_loading_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await dotenv.load(fileName: ".env");

  final supabaseUrl = dotenv.env['SUPABASE_URL'];
  final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];
  if (supabaseUrl == null || supabaseAnonKey == null) {
    throw Exception('SUPABASE_URL and SUPABASE_ANON_KEY must be set in .env');
  }

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (!kIsWeb) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);

  runApp(const AllowanceApp());
}

class AllowanceApp extends StatefulWidget {
  const AllowanceApp({super.key});

  @override
  State<AllowanceApp> createState() => _AllowanceAppState();
}

class _AllowanceAppState extends State<AllowanceApp> {
  final UserPreferences _userPreferences = UserPreferences();
  bool _isInitialized = false;

  StreamSubscription<AuthState>? _authSub;

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _initializeApp();
  }

  Future<void> _initializeApp() async {
    try {
      await _userPreferences.loadPreferences();

      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        await _setupFcmAndListeners();
      }

      _authSub = Supabase.instance.client.auth.onAuthStateChange
          .listen((authState) async {
        final session = authState.session;
        if (session != null && session.user != null) {
          await _userPreferences.loadPreferences();
          await _setupFcmAndListeners();
        } else {
          await _userPreferences.clearLocal();
        }
        if (mounted) setState(() {});
      });
    } catch (e) {
      developer.log('App initialization error: $e', name: 'main');
    } finally {
      if (mounted) setState(() => _isInitialized = true);
    }
  }

  Future<void> _setupFcmAndListeners() async {
    try {
      if (kIsWeb) {
        await requestWebPushPermissionAndSaveToken();
      } else {
        await initFcmAndSaveToken();
      }
    } catch (e) {
      developer.log('FCM setup error: $e', name: 'main');
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = navigatorKey.currentContext;
      if (context != null) {
        registerFcmListeners(context);
      }
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Allowance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.indigo),
      home: _isInitialized
          ? _buildHome()
          : const CustomLoadingScreen(), // ← Now safely inside MaterialApp
    );
  }

  Widget _buildHome() {
    final user = Supabase.instance.client.auth.currentUser;

    if (user == null) {
      return IntroductionScreen(
        onFinishIntro: () {},
        userPreferences: _userPreferences,
      );
    }

    return _userPreferences.hasCompletedProfile == true
        ? HomeScreen(userPreferences: _userPreferences)
        : EditProfileScreen(userPreferences: _userPreferences);
  }
}
