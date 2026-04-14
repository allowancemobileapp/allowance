// lib/screens/introduction/introduction_screen.dart
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/home/home_screen.dart';
import 'package:allowance/screens/profile/edit_profile_screen.dart';

class IntroductionScreen extends StatefulWidget {
  final VoidCallback onFinishIntro;
  final UserPreferences userPreferences;
  const IntroductionScreen({
    super.key,
    required this.onFinishIntro,
    required this.userPreferences,
  });

  @override
  State<IntroductionScreen> createState() => _IntroductionScreenState();
}

class _IntroductionScreenState extends State<IntroductionScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailCtl = TextEditingController();
  final _pwCtl = TextEditingController();
  final _usernameCtl = TextEditingController();
  bool _loading = false;
  bool _isSignUp = false;
  bool _obscurePassword = true;

  // ---------------------------------------------------------------------------
  // RESTORED: YOUR COMPLETE ORIGINAL LOGIC
  // ---------------------------------------------------------------------------
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    final supabase = Supabase.instance.client;
    final usernameVal = _usernameCtl.text.trim();
    final emailVal = _emailCtl.text.trim();

    try {
      // 1) PRE-CHECK: Check username availability before starting the Auth process
      if (_isSignUp) {
        final existing = await supabase
            .from('profiles')
            .select('username')
            .eq('username', usernameVal)
            .maybeSingle();

        if (existing != null) {
          _showError('This username is already taken. Please choose another.');
          setState(() => _loading = false);
          return;
        }
      }

      if (_isSignUp) {
        // 2) SIGN UP FLOW
        final signUpRes = await supabase.auth.signUp(
          email: emailVal,
          password: _pwCtl.text,
        );

        if (signUpRes.user == null) throw AuthException('Sign up failed');

        // 3) INITIAL PROFILE UPSERT
        // Using upsert ensures we create the profile and link it to the Auth ID immediately
        await supabase.from('profiles').upsert({
          'id': signUpRes.user!.id,
          'email': emailVal,
          'username': usernameVal,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });

        await widget.userPreferences.loadPreferences();

        if (mounted) {
          await Navigator.of(context).pushReplacement(
            MaterialPageRoute(
              builder: (_) =>
                  EditProfileScreen(userPreferences: widget.userPreferences),
            ),
          );
          widget.onFinishIntro();
        }
      } else {
        // 4) LOG IN FLOW
        await supabase.auth.signInWithPassword(
          email: emailVal,
          password: _pwCtl.text,
        );

        await widget.userPreferences.loadPreferences();
        widget.onFinishIntro();

        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) =>
                  HomeScreen(userPreferences: widget.userPreferences),
            ),
          );
        }
      }
    } on AuthException catch (e) {
      // Friendly mapping for common Auth errors
      String message = e.message;
      if (message.contains('Invalid login credentials')) {
        message = 'Incorrect email or password.';
      } else if (message.contains('User already registered')) {
        message = 'An account with this email already exists.';
      }
      _showError(message);
    } on PostgrestException catch (e) {
      // Specific check for Postgres unique constraint violation (Code 23505)
      if (e.code == '23505' || e.message.contains('profiles_username_unique')) {
        _showError(
            'That username is already taken. Please try a different one.');
      } else {
        _showError('Database error: Unable to save your profile.');
      }
    } catch (e) {
      // Final fallback for unexpected issues (Network, etc.)
      _showError(
          'Something went wrong. Please check your connection and try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

// Helper to keep code clean
  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.redAccent,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  void dispose() {
    _emailCtl.dispose();
    _pwCtl.dispose();
    _usernameCtl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // UI HELPERS
  // ---------------------------------------------------------------------------
  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscureText = false,
    TextInputType? keyboardType,
    Widget? suffixIcon,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white, fontSize: 16),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white54),
        prefixIcon: Icon(icon, color: Colors.white54, size: 22),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: const Color(0xFF1A1A1A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: const BorderSide(color: Colors.white24, width: 1),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide:
              BorderSide(color: Colors.redAccent.withOpacity(0.5), width: 1),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      ),
      validator: validator,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28.0),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 1. App Icon
                  Center(
                    child: Image.asset(
                      'assets/images/app_icon.png',
                      height: 90,
                      fit: BoxFit.contain,
                    ),
                  ),

                  const SizedBox(height: 4),

                  // 2. Allowance Logo - VISUALLY 5X BIGGER
                  Center(
                    child: Transform.scale(
                      scale:
                          3.0, // <--- Adjust this (e.g., 2.0) if it's too big for the screen
                      child: Image.asset(
                        'assets/images/allowance_logo.png',
                        width: MediaQuery.of(context).size.width * 0.7,
                        height: 70,
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),

                  const SizedBox(height: 12),

                  Text(
                    _isSignUp ? 'Create a new account' : 'Welcome back',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, color: Colors.white54),
                  ),
                  const SizedBox(height: 48),

                  _buildTextField(
                    controller: _emailCtl,
                    label: 'Email',
                    icon: Icons.email_outlined,
                    validator: (v) => (v == null || !v.contains('@'))
                        ? 'Enter valid email'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    controller: _pwCtl,
                    label: 'Password',
                    icon: Icons.lock_outline,
                    obscureText: _obscurePassword,
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_off
                              : Icons.visibility,
                          color: Colors.white54),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                    validator: (v) =>
                        (v == null || v.length < 6) ? 'Min 6 characters' : null,
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    child: _isSignUp
                        ? Padding(
                            padding: const EdgeInsets.only(top: 16.0),
                            child: _buildTextField(
                              controller: _usernameCtl,
                              label: 'Username',
                              icon: Icons.person_outline,
                              validator: (v) => (_isSignUp && (v ?? '').isEmpty)
                                  ? 'Required'
                                  : null,
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  const SizedBox(height: 40),
                  _loading
                      ? const Center(
                          child: CircularProgressIndicator(color: Colors.white))
                      : ElevatedButton(
                          onPressed: _submit,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16)),
                          ),
                          child: Text(_isSignUp ? 'Sign Up' : 'Log In',
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold)),
                        ),
                  const SizedBox(height: 24),
                  TextButton(
                    onPressed: () => setState(() => _isSignUp = !_isSignUp),
                    child: RichText(
                      text: TextSpan(
                        text: _isSignUp
                            ? 'Already have an account? '
                            : 'Don\'t have an account? ',
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 15),
                        children: [
                          TextSpan(
                              text: _isSignUp ? 'Log In' : 'Sign Up',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
