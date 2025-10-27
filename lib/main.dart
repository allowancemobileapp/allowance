// lib/main.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/user_preferences.dart';
import 'screens/introduction/introduction_screen.dart';
import 'screens/home/home_screen.dart';

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

  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

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
    await _userPreferences.loadPreferences();
    setState(() => _isLoading = false);

    // Listen to Supabase auth changes (login/logout)
    _authSub = Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _authSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    final user = Supabase.instance.client.auth.currentUser;

    return MaterialApp(
      title: 'Allowance',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(primarySwatch: Colors.indigo),
      home: user == null
          ? IntroductionScreen(
              onFinishIntro: () {},
              userPreferences: _userPreferences,
            )
          : HomeScreen(userPreferences: _userPreferences),
    );
  }
}
