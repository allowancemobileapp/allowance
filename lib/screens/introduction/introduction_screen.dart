import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';
// import 'package:allowance/screens/onboarding/onboarding_school.dart';
import 'package:allowance/screens/home/home_screen.dart';

class IntroductionScreen extends StatelessWidget {
  final VoidCallback onFinishIntro;
  final UserPreferences userPreferences;
  const IntroductionScreen({
    super.key,
    required this.onFinishIntro,
    required this.userPreferences,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                'Allowance',
                style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '"The best app to manage your meal budget"',
                style: TextStyle(fontSize: 20, color: Colors.white70),
              ),
              const SizedBox(height: 16),
              const Text(
                'Use this app to get daily meal suggestions that fit your budget.\nSimple, efficient, and personalized!',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.white60),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () {
                  // Placeholder for login
                  onFinishIntro();
                  Navigator.pushReplacement(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          HomeScreen(userPreferences: userPreferences),
                    ),
                  );
                },
                child: const Text("Login"),
              ),
              const SizedBox(height: 16),
              // ElevatedButton(
              //   onPressed: () {
              //     onFinishIntro();
              //     Navigator.pushReplacement(
              //       context,
              //       MaterialPageRoute(
              //         builder:
              //             (_) => OnboardingSchoolScreen(
              //               userPreferences: userPreferences,
              //             ),
              //       ),
              //     );
              //   },
              //   child: const Text("Get Started"),
              // ),
            ],
          ),
        ),
      ),
    );
  }
}
