// lib/main.dart
import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Firebase imports
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';

import 'models/user_preferences.dart';
import 'screens/introduction/introduction_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/profile/edit_profile_screen.dart';
import 'shared/services/fcm_service.dart'; // ← now uncommented

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await dotenv.load(fileName: ".env");

  final supabaseUrl = dotenv.env['SUPABASE_URL'];
  final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];
  if (supabaseUrl == null || supabaseAnonKey == null) {
    throw Exception('SUPABASE_URL and SUPABASE_ANON_KEY must be set in .env');
  }

  // === FIREBASE ENABLED ===
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (!kIsWeb) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  }
  // === END FIREBASE ===

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
      _setupFcmAndListeners(); // ← now uncommented
    }

    _authSub = Supabase.instance.client.auth.onAuthStateChange
        .listen((authState) async {
      final session = authState.session;
      if (session != null && session.user != null) {
        await _userPreferences.loadPreferences();
        _setupFcmAndListeners(); // ← now uncommented
        if (mounted) setState(() {});
      } else {
        await _userPreferences.clearLocal();
        if (mounted) setState(() {});
      }
    });
  }

  Future<void> _setupFcmAndListeners() async {
    try {
      if (kIsWeb) {
        await requestWebPushPermissionAndSaveToken();
      } else {
        await initFcmAndSaveToken();
      }
    } catch (e) {
      developer.log('FCM token save error: $e', name: 'main');
    }

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
