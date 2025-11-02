// lib/main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// NEW imports
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import 'models/user_preferences.dart';
import 'screens/introduction/introduction_screen.dart';
import 'screens/home/home_screen.dart';

// import the FCM service you just added
import 'shared/services/fcm_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Load environment variables
  await dotenv.load(fileName: ".env");

  final supabaseUrl = dotenv.env['SUPABASE_URL'];
  final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];

  if (supabaseUrl == null || supabaseAnonKey == null) {
    throw Exception(
        'SUPABASE_URL and SUPABASE_ANON_KEY must be set in .env (project root).');
  }

  // Initialize Firebase (required for FCM)
  await Firebase.initializeApp();

  // Initialize Supabase
  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  // Register background handler (redundant if done in fcm_service but safe)
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

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

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Load local prefs first. If a user is already signed in, loadPreferences()
    // will also try to fetch/create the server profile and overwrite local values.
    await _userPreferences.loadPreferences();
    setState(() => _isLoading = false);

    // If user already signed in at app start, register FCM now
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      // call after first frame so context is ready
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // register listeners that need BuildContext
        registerFcmListeners(
            navigatorKey.currentContext ?? navigatorKeyRootContext!);
      });
      // token save does not require context
      await initFcmAndSaveToken();
    }

    // Listen to Supabase auth changes (login / logout).
    _authSub = Supabase.instance.client.auth.onAuthStateChange
        .listen((authState) async {
      final session = authState.session;
      if (session != null && session.user != null) {
        // Signed in: explicitly reload preferences (this reads server profile and writes local).
        try {
          await _userPreferences.loadPreferences();
        } catch (_) {
          // ignore - keep whatever local values exist if load fails
        }

        // Save token & register listeners after sign-in
        try {
          await initFcmAndSaveToken();
        } catch (_) {}
        // register listeners (we need a BuildContext, so do it on next frame)
        if (mounted) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            registerFcmListeners(context);
          });
        }

        if (mounted) setState(() {});
      } else {
        // Signed out: clear local cache and rebuild UI so the app shows intro/login
        try {
          await _userPreferences.clearLocal();
        } catch (_) {
          // ignore
        }
        if (mounted) setState(() {});
      }
    });
  }

  // NOTE: we use a navigator key to have a context if you need to register listeners
  // before a specific screen is built. If you already manage navigation differently,
  // you can remove this and simply call registerFcmListeners(context) from your HomeScreen.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();
  static BuildContext? navigatorKeyRootContext;

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // capture root context for FCM listener registration if needed
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
              onFinishIntro: () {
                // When intro finishes, the introduction screen should handle sign-in / sign-up flow.
                // After sign-in completes, the auth listener above will reload preferences and rebuild UI.
              },
              userPreferences: _userPreferences,
            )
          : HomeScreen(userPreferences: _userPreferences),
    );
  }
}
