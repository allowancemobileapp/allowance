// lib/screens/profile/profile_screen.dart
import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:allowance/screens/introduction/introduction_screen.dart';
import 'package:allowance/screens/home/home_screen.dart';

class ProfileScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  final VoidCallback onSave; // Callback to notify HomeScreen

  const ProfileScreen({
    super.key,
    required this.userPreferences,
    required this.onSave,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _weightController = TextEditingController();
  final TextEditingController _heightController = TextEditingController();
  final TextEditingController _ageController = TextEditingController();

  String? _bloodGroup;
  final List<String> bloodGroups = [
    "A+",
    "A-",
    "B+",
    "B-",
    "AB+",
    "AB-",
    "O+",
    "O-",
  ];

  bool _signingOut = false;

  @override
  void initState() {
    super.initState();
    _usernameController.text = widget.userPreferences.username ?? "";
    _phoneController.text = widget.userPreferences.phoneNumber ?? "";
    _weightController.text = widget.userPreferences.weight?.toString() ?? "";
    _heightController.text = widget.userPreferences.height?.toString() ?? "";
    _ageController.text = widget.userPreferences.age?.toString() ?? "";
    _bloodGroup = widget.userPreferences.bloodGroup;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _phoneController.dispose();
    _weightController.dispose();
    _heightController.dispose();
    _ageController.dispose();
    super.dispose();
  }

  Future<void> _confirmLogout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Log out'),
        content: const Text('Are you sure you want to log out?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Log out')),
        ],
      ),
    );

    if (confirmed == true) {
      await _signOut();
    }
  }

  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    try {
      final supabase = Supabase.instance.client;

      // Sign out from Supabase
      await supabase.auth.signOut();

      // Optionally keep local preferences; if you want to clear them uncomment below:
      // await widget.userPreferences.clearPreferences(); // (implement if you add a clear method)

      // Show friendly message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Signed out successfully.')),
        );
      }

      // Navigate to the Introduction screen and remove all previous routes
      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => IntroductionScreen(
              userPreferences: widget.userPreferences,
              onFinishIntro: () {
                // After login, rebuild will show Home because auth state will change and main.dart listens for it.
                Navigator.of(context).pushReplacement(
                  MaterialPageRoute(
                      builder: (_) =>
                          HomeScreen(userPreferences: widget.userPreferences)),
                );
              },
            ),
          ),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to sign out: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required String hint,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFF2C2C2C),
      ),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(
            color: Colors.white,
            fontFamily: 'SF Pro',
            fontWeight: FontWeight.bold,
          ),
          hintStyle: const TextStyle(
            color: Colors.white60,
            fontFamily: 'SF Pro',
          ),
          filled: true,
          fillColor: Colors.transparent,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none),
          contentPadding:
              const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
        ),
        keyboardType: keyboardType,
        style: const TextStyle(fontFamily: 'SF Pro', color: Colors.white),
        textAlign: TextAlign.left,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        centerTitle: true,
        title: const Text(
          "My Profile",
          style: TextStyle(
            fontFamily: 'SF Pro',
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 4,
        actions: [
          // Logout button
          IconButton(
            icon: _signingOut
                ? const CircularProgressIndicator.adaptive()
                : const Icon(Icons.logout),
            tooltip: 'Log out',
            onPressed: _signingOut ? null : _confirmLogout,
          )
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: ListView(
                shrinkWrap: true,
                children: [
                  _buildInputField(
                    controller: _usernameController,
                    label: "Username",
                    hint: "Enter your username",
                  ),
                  const SizedBox(height: 16),
                  _buildInputField(
                    controller: _phoneController,
                    label: "Phone Number",
                    hint: "Enter your phone number",
                    keyboardType: TextInputType.phone,
                  ),
                  const SizedBox(height: 16),
                  _buildInputField(
                    controller: _weightController,
                    label: "Weight (kg)",
                    hint: "Enter your weight",
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 16),
                  _buildInputField(
                    controller: _heightController,
                    label: "Height (cm)",
                    hint: "Enter your height",
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 16),
                  _buildInputField(
                    controller: _ageController,
                    label: "Age",
                    hint: "Enter your age",
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 16),
                  // Blood group dropdown
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: const Color(0xFF2C2C2C),
                    ),
                    child: DropdownButtonFormField<String>(
                      value: _bloodGroup,
                      items: bloodGroups
                          .map(
                              (b) => DropdownMenuItem(value: b, child: Text(b)))
                          .toList(),
                      onChanged: (v) => setState(() => _bloodGroup = v),
                      decoration: const InputDecoration(
                          border:
                              OutlineInputBorder(borderSide: BorderSide.none),
                          labelText: 'Blood Group'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Center(
                      child: ElevatedButton(
                        onPressed: () {
                          // Save preferences locally and notify home
                          widget.userPreferences.username =
                              _usernameController.text;
                          widget.userPreferences.phoneNumber =
                              _phoneController.text;
                          widget.userPreferences.weight =
                              double.tryParse(_weightController.text);
                          widget.userPreferences.height =
                              double.tryParse(_heightController.text);
                          widget.userPreferences.age =
                              int.tryParse(_ageController.text);
                          widget.userPreferences.bloodGroup = _bloodGroup;
                          widget.userPreferences.savePreferences();
                          widget.onSave();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4CAF50),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              vertical: 16, horizontal: 48),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          elevation: 0,
                        ),
                        child: const Text(
                          "Save",
                          style: TextStyle(
                              fontFamily: 'SF Pro',
                              fontSize: 16,
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
