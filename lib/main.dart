import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart'; // Import shared_preferences
import 'models/user_preferences.dart';
import 'screens/introduction/introduction_screen.dart';
import 'screens/home/home_screen.dart';
// Remove the global variable: bool isFirstTime = true;

void main() async {
  // Make main async
  // Ensure Flutter binding is initialized before using plugins
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AllowanceApp());
}

class AllowanceApp extends StatefulWidget {
  const AllowanceApp({super.key});

  @override
  State<AllowanceApp> createState() => _AllowanceAppState();
}

class _AllowanceAppState extends State<AllowanceApp> {
  final UserPreferences _userPreferences = UserPreferences();
  bool _isLoading = true; // Loading state
  bool _isFirstTime = true; // Default to true until checked

  @override
  void initState() {
    super.initState();
    _checkFirstTime();
    _userPreferences.loadPreferences(); // Load other preferences
  }

  // Function to check SharedPreferences for the first time flag
  Future<void> _checkFirstTime() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    // Check if 'seenIntro' key exists, default to true if not found (means first time)
    bool isFirstTime = (prefs.getBool('seenIntro') ?? false) == false;

    setState(() {
      _isFirstTime = isFirstTime;
      _isLoading = false; // Finished loading the flag
    });
  }

  // Function to mark intro as seen
  Future<void> _markIntroSeen() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('seenIntro', true);
    setState(() {
      _isFirstTime = false; // Update state immediately
    });
  }

  @override
  Widget build(BuildContext context) {
    // Show loading indicator while checking the flag
    if (_isLoading) {
      return const MaterialApp(
        home: Scaffold(
          body: Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return MaterialApp(
      title: 'Allowance',
      theme: ThemeData.dark(), // Or your preferred theme
      debugShowCheckedModeBanner: false, // Hide debug banner
      home: _isFirstTime
          ? IntroductionScreen(
              onFinishIntro: () {
                // Mark intro as seen when finished
                _markIntroSeen();
              },
              userPreferences:
                  _userPreferences, // Pass preferences if needed by IntroScreen
            )
          : HomeScreen(userPreferences: _userPreferences),
    );
  }
}
