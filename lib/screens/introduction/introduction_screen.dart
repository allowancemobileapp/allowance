// lib/screens/introduction/introduction_screen.dart

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/home/home_screen.dart';

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

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);

    final supabase = Supabase.instance.client;

    try {
      AuthResponse authRes;

      if (_isSignUp) {
        // 1) Sign up new user
        final signUpRes = await supabase.auth.signUp(
          email: _emailCtl.text.trim(),
          password: _pwCtl.text,
        );
        if (signUpRes.user == null) {
          throw AuthException('Sign up failed');
        }

        // 2) Immediately sign in after sign up
        authRes = await supabase.auth.signInWithPassword(
          email: _emailCtl.text.trim(),
          password: _pwCtl.text,
        );

        if (authRes.user == null) {
          throw AuthException('Authentication failed after sign up');
        }

        // 3) Create a profile row with the username (if provided)
        //    Wrap in try/catch so profile creation failure doesn't block navigation.
        final usernameVal = _usernameCtl.text.trim();
        try {
          await supabase.from('profiles').insert({
            'id': authRes.user!.id,
            'email': _emailCtl.text.trim(),
            'username': usernameVal.isNotEmpty ? usernameVal : null,
            'created_at': DateTime.now().toUtc().toIso8601String(),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          });
        } catch (e) {
          // Non-fatal: log and continue (profile can be created later)
          debugPrint('Profile creation after signup failed: $e');
        }
      } else {
        // Log in existing user
        authRes = await supabase.auth.signInWithPassword(
          email: _emailCtl.text.trim(),
          password: _pwCtl.text,
        );
      }

      if (authRes.user == null) {
        throw AuthException('Authentication failed');
      }

      // Ensure local preferences reflect the (possibly new) server profile
      try {
        await widget.userPreferences.loadPreferences();
      } catch (e) {
        // non-fatal; proceed to app but log for debugging
        debugPrint('loadPreferences after auth failed: $e');
      }

      // Success: invoke callback and navigate
      widget.onFinishIntro();
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => HomeScreen(userPreferences: widget.userPreferences),
        ),
      );
    } on AuthException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(error.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _emailCtl.dispose();
    _pwCtl.dispose();
    _usernameCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32.0),
          child: Form(
            key: _formKey,
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
                Text(
                  _isSignUp ? 'Create a new account' : 'Log in to your account',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 20, color: Colors.white70),
                ),
                const SizedBox(height: 32),
                TextFormField(
                  controller: _emailCtl,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    border: OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.white12,
                  ),
                  keyboardType: TextInputType.emailAddress,
                  style: const TextStyle(color: Colors.white),
                  validator: (v) => (v == null || !v.contains('@'))
                      ? 'Enter a valid email'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _pwCtl,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.white12,
                  ),
                  style: const TextStyle(color: Colors.white),
                  obscureText: true,
                  validator: (v) =>
                      (v == null || v.length < 6) ? 'Min 6 characters' : null,
                ),

                // Username field shown only on Sign Up
                if (_isSignUp) ...[
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _usernameCtl,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      border: OutlineInputBorder(),
                      filled: true,
                      fillColor: Colors.white12,
                    ),
                    style: const TextStyle(color: Colors.white),
                    validator: (v) {
                      if (!_isSignUp) return null;
                      final s = (v ?? '').trim();
                      if (s.isEmpty) return 'Choose a username';
                      if (s.length < 3) return 'At least 3 characters';
                      // basic sanity: no spaces
                      if (s.contains(' ')) return 'No spaces allowed';
                      return null;
                    },
                  ),
                ],

                const SizedBox(height: 24),
                _loading
                    ? const CircularProgressIndicator()
                    : SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _submit,
                          child: Text(_isSignUp ? 'Sign Up' : 'Log In'),
                        ),
                      ),
                const SizedBox(height: 16),
                TextButton(
                  onPressed: () => setState(() {
                    _isSignUp = !_isSignUp;
                  }),
                  child: Text(
                    _isSignUp
                        ? 'Already have an account? Log In'
                        : 'Don\'t have an account? Sign Up',
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
