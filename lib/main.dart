import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'models/user_preferences.dart';
import 'screens/introduction/introduction_screen.dart';
import 'screens/home/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: 'https://quuazutreaitqoquzolg.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InF1dWF6dXRyZWFpdHFvcXV6b2xnIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NDQwODk2MTgsImV4cCI6MjA1OTY2NTYxOH0.kVZLSMgt05gpVhtADOuI6nbHoDdVmAUnSWpsF9-iU5U',
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

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    // load any prefs you need
    await _userPreferences.loadPreferences();
    setState(() => _isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    // still show a splash while prefs load
    if (_isLoading) {
      return const MaterialApp(
        home: Scaffold(body: Center(child: CircularProgressIndicator())),
      );
    }

    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;

    return MaterialApp(
      title: 'Allowance',
      theme: ThemeData.dark(),
      debugShowCheckedModeBanner: false,
      // ⇩⇩ If there's no logged‑in user, always show the Introduction/Login screen
      home: user == null
          ? IntroductionScreen(
              onFinishIntro: () {
                // optional: keep your seenIntro logic,
                // but it no longer gates login
              },
              userPreferences: _userPreferences,
            )
          : HomeScreen(userPreferences: _userPreferences),
    );
  }
}
