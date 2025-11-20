// lib/main.dart
import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_web_plugins/flutter_web_plugins.dart'; // ← NEW
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Firebase imports
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';

import 'models/user_preferences.dart';
import 'screens/introduction/introduction_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/profile/edit_profile_screen.dart'; // ← ADD THIS IMPORT
import 'shared/services/fcm_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Use Hash URL strategy for Flutter web
  if (kIsWeb) {
    setUrlStrategy(const HashUrlStrategy());
  }

  await dotenv.load(fileName: ".env");

  final supabaseUrl = dotenv.env['SUPABASE_URL'];
  final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];
  if (supabaseUrl == null || supabaseAnonKey == null) {
    throw Exception('SUPABASE_URL and SUPABASE_ANON_KEY must be set in .env');
  }

  // Firebase init
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Background handler (Android/iOS only — web uses firebase-messaging-sw.js)
  if (!kIsWeb) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }

  // Supabase init
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
  bool _isLoading = true;
  StreamSubscription<AuthState>? _authSub;

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
  static BuildContext? navigatorKeyRootContext;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _userPreferences.loadPreferences();
    setState(() => _isLoading = false);

    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      _setupFcmAndListeners();
    }

    // Auth state listener
    _authSub = Supabase.instance.client.auth.onAuthStateChange
        .listen((authState) async {
      final session = authState.session;
      if (session != null && session.user != null) {
        await _userPreferences.loadPreferences();
        _setupFcmAndListeners();
        if (mounted) setState(() {});
      } else {
        await _userPreferences.clearLocal();
        if (mounted) setState(() {});
      }
    });
  }

  Future<void> _setupFcmAndListeners() async {
    // Save FCM token (mobile + web)
    try {
      if (kIsWeb) {
        await requestWebPushPermissionAndSaveToken(); // web version
      } else {
        await initFcmAndSaveToken(); // mobile version
      }
    } catch (e) {
      developer.log('FCM token save error: $e', name: 'main');
    }

    // Register foreground / tap listeners (needs context)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      registerFcmListeners(navigatorKey.currentContext ?? context);
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    navigatorKeyRootContext ??= navigatorKey.currentContext;

    if (_isLoading) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    final user = Supabase.instance.client.auth.currentUser;

    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Allowance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.indigo),
      home: user == null
          ? IntroductionScreen(
              onFinishIntro: () {},
              userPreferences: _userPreferences,
            )
          : (_userPreferences.hasCompletedProfile == true
              ? HomeScreen(userPreferences: _userPreferences)
              : EditProfileScreen(userPreferences: _userPreferences)),
    );
  }
}
