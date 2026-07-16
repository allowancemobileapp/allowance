// lib/screens/introduction/introduction_screen.dart
import 'package:allowance/screens/settings/terms_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
  final _referralCtl = TextEditingController();
  bool _loading = false;
  bool _isSignUp = false;
  bool _obscurePassword = true;
  bool _acceptedTerms = false; // <-- ADD THIS

  @override
  void initState() {
    super.initState();
    _checkPendingReferral();
  }

  // 🔥 NEW: Checks if they opened the app via a referral link!
  Future<void> _checkPendingReferral() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString('pending_referral_code');
    if (code != null && code.isNotEmpty && mounted) {
      setState(() {
        _referralCtl.text = code; // Auto-fill the box!
        _isSignUp = true; // Auto-flip to the Sign Up screen!
      });
    }
  }

  // ---------------------------------------------------------------------------
  // RESTORED: YOUR COMPLETE ORIGINAL LOGIC
  // ---------------------------------------------------------------------------
  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    if (_isSignUp && !_acceptedTerms) {
      _showError(
          "You must agree to the Terms of Service to create an account.");
      return;
    }

    setState(() => _loading = true);

    final supabase = Supabase.instance.client;
    final usernameVal = _usernameCtl.text.trim();
    final emailVal = _emailCtl.text.trim();
    final prefs = await SharedPreferences.getInstance();

    // 🔥 FIX: Now automatically pulls from memory if they clicked a link!
    final referralCode = _referralCtl.text.trim().isNotEmpty
        ? _referralCtl.text.trim().toLowerCase()
        : prefs.getString('pending_referral_code')?.toLowerCase() ?? '';

    String? referrerId;

    try {
      if (_isSignUp) {
        // 1) CHECK USERNAME
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

        // 2) CHECK REFERRAL CODE (If provided via UI or Deep Link)
        if (referralCode.isNotEmpty) {
          final referrer = await supabase
              .from('profiles')
              .select('id')
              .eq('username', referralCode)
              .maybeSingle();
          if (referrer == null) {
            _showError('Invalid referral code. Please check the username.');
            setState(() => _loading = false);
            return;
          }
          referrerId = referrer['id'];
        }

        // 3) SIGN UP
        final signUpRes =
            await supabase.auth.signUp(email: emailVal, password: _pwCtl.text);
        if (signUpRes.user == null) throw const AuthException('Sign up failed');

        // 4) UPSERT PROFILE WITH REFERRAL
        await supabase.from('profiles').upsert({
          'id': signUpRes.user!.id,
          'email': emailVal,
          'username': usernameVal,
          'referred_by': referrerId, // <-- SAVES THE REFERRAL!
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        });

        // Clear memory code since it's now safely in the DB
        await prefs.remove('pending_referral_code');

        await widget.userPreferences.loadPreferences();
        if (mounted) {
          await Navigator.of(context).pushReplacement(MaterialPageRoute(
              builder: (_) =>
                  EditProfileScreen(userPreferences: widget.userPreferences)));
          widget.onFinishIntro();
        }
      } else {
        await supabase.auth
            .signInWithPassword(email: emailVal, password: _pwCtl.text);
        await widget.userPreferences.loadPreferences();
        widget.onFinishIntro();
        if (mounted) {
          Navigator.pushReplacement(
              context,
              MaterialPageRoute(
                  builder: (_) =>
                      HomeScreen(userPreferences: widget.userPreferences)));
        }
      }
    } on AuthException catch (e) {
      String message = e.message;
      if (message.contains('Invalid login credentials')) {
        message = 'Incorrect email or password.';
      } else if (message.contains('User already registered')) {
        message = 'An account with this email already exists.';
      }
      _showError(message);
    } on PostgrestException catch (e) {
      if (e.code == '23505' || e.message.contains('profiles_username_unique')) {
        _showError(
            'That username is already taken. Please try a different one.');
      } else {
        _showError('Database error: Unable to save your profile.');
      }
    } catch (e) {
      _showError(
          'Something went wrong. Please check your connection and try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _signInWithGoogle() async {
    final prefs = await SharedPreferences.getInstance();

    // 🔥 FIX: Pull from memory as fallback
    final referralCode = _referralCtl.text.trim().isNotEmpty
        ? _referralCtl.text.trim().toLowerCase()
        : prefs.getString('pending_referral_code')?.toLowerCase() ?? '';

    String? referrerId;
    final supabase = Supabase.instance.client;

    setState(() => _loading = true);

    try {
      // 1) PRE-CHECK REFERRAL BEFORE OAUTH (If signing up)
      if (_isSignUp && referralCode.isNotEmpty) {
        final referrer = await supabase
            .from('profiles')
            .select('id')
            .eq('username', referralCode)
            .maybeSingle();
        if (referrer == null) {
          _showError('Invalid referral code. Please check the username.');
          setState(() => _loading = false);
          return;
        }
        referrerId = referrer['id'];

        // Save the ID securely so Edit Profile screen can attach it later
        if (referrerId != null) {
          await prefs.setString('pending_referrer_uuid', referrerId);
        }
      }

      if (kIsWeb) {
        await supabase.auth.signInWithOAuth(OAuthProvider.google,
            redirectTo: Uri.base.origin,
            queryParams: {'prompt': 'select_account'});
        return;
      }

      const webClientId =
          '463313212619-b0fl0uekmftif09otfpnj27cqm9cgrp7.apps.googleusercontent.com';
      final GoogleSignIn googleSignIn =
          GoogleSignIn(serverClientId: webClientId);
      await googleSignIn.signOut();

      final GoogleSignInAccount? googleUser = await googleSignIn.signIn();
      if (googleUser == null) {
        setState(() => _loading = false);
        return;
      }

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final accessToken = googleAuth.accessToken;
      final idToken = googleAuth.idToken;

      if (idToken == null) throw 'Missing Google ID Token.';

      final authRes = await supabase.auth.signInWithIdToken(
          provider: OAuthProvider.google,
          idToken: idToken,
          accessToken: accessToken);

      // 2) UPDATE REFERRAL IF NEW ACCOUNT
      if (_isSignUp && referrerId != null && authRes.user != null) {
        await supabase
            .from('profiles')
            .update({'referred_by': referrerId}).eq('id', authRes.user!.id);
      }

      // Clear memory code since it's now safely in the DB
      await prefs.remove('pending_referral_code');
      await prefs.remove('pending_referrer_uuid');

      await widget.userPreferences.loadPreferences();
      widget.onFinishIntro();

      if (mounted) {
        Navigator.pushReplacement(
            context,
            MaterialPageRoute(
                builder: (_) =>
                    HomeScreen(userPreferences: widget.userPreferences)));
      }
    } catch (e) {
      _showError('Google Sign-In failed: $e');
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

  Future<void> _forgotPassword() async {
    final email = _emailCtl.text.trim();
    if (email.isEmpty || !email.contains('@')) {
      _showError('Please enter your email address first.');
      return;
    }

    setState(() => _loading = true);
    final supabase = Supabase.instance.client;
    try {
      // DYNAMIC REDIRECT FIX: Automatically detects if you are on localhost or production Web,
      // or falls back to your custom scheme on mobile.
      final String redirectUrl = kIsWeb
          ? Uri.base
              .origin // Captures 'http://localhost:59781' or production domain automatically
          : 'allowance://reset-password';

      await supabase.auth.resetPasswordForEmail(
        email,
        redirectTo: redirectUrl,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Password reset link sent to your email!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      _showError('Error sending reset link: $e');
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
      backgroundColor: const Color(0xFF121212),
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
                  Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.asset('assets/images/app_icon.png',
                          height: 90, fit: BoxFit.contain),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Transform.scale(
                      scale: 3.0,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.asset('assets/images/allowance_logo.png',
                            width: MediaQuery.sizeOf(context).width * 0.7,
                            height: 70,
                            fit: BoxFit.contain),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(_isSignUp ? 'Create a new account' : 'Welcome back',
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(fontSize: 16, color: Colors.white54)),
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
                  if (!_isSignUp)
                    Align(
                      alignment: Alignment.center,
                      child: TextButton(
                        onPressed: _loading ? null : _forgotPassword,
                        child: const Text('Forgot Password?',
                            style: TextStyle(
                                color: Color(0xFF4CAF50),
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    child: _isSignUp
                        ? Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 16.0),
                                child: _buildTextField(
                                  controller: _usernameCtl,
                                  label: 'Username',
                                  icon: Icons.person_outline,
                                  validator: (v) =>
                                      (_isSignUp && (v ?? '').isEmpty)
                                          ? 'Required'
                                          : null,
                                ),
                              ),
                              // --- NEW: REFERRAL CODE FIELD ---
                              Padding(
                                padding: const EdgeInsets.only(top: 16.0),
                                child: _buildTextField(
                                  controller: _referralCtl,
                                  label: 'Referral Code (Optional)',
                                  icon: Icons.card_giftcard,
                                ),
                              ),
                            ],
                          )
                        : const SizedBox.shrink(),
                  ),
                  if (_isSignUp)
                    Padding(
                      padding: const EdgeInsets.only(top: 20.0),
                      child: Row(
                        children: [
                          Checkbox(
                            value: _acceptedTerms,
                            activeColor: const Color(0xFF4CAF50),
                            checkColor: Colors.white,
                            side: const BorderSide(color: Colors.white54),
                            onChanged: (val) =>
                                setState(() => _acceptedTerms = val ?? false),
                          ),
                          Expanded(
                            child: GestureDetector(
                              onTap: () => Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => const TermsScreen())),
                              child: RichText(
                                text: const TextSpan(
                                  text: "I agree to the ",
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 13),
                                  children: [
                                    TextSpan(
                                        text:
                                            "Terms of Service & Privacy Policy",
                                        style: TextStyle(
                                            color: Color(0xFF4CAF50),
                                            fontWeight: FontWeight.bold,
                                            decoration:
                                                TextDecoration.underline))
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 30),
                  _loading
                      ? const Center(
                          child: CircularProgressIndicator(color: Colors.white))
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ElevatedButton(
                              onPressed: _submit,
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: const Color(0xFF121212),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 18),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16))),
                              child: Text(_isSignUp ? 'Sign Up' : 'Log In',
                                  style: const TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold)),
                            ),
                            const SizedBox(height: 16),
                            OutlinedButton.icon(
                              onPressed: _loading ? null : _signInWithGoogle,
                              style: OutlinedButton.styleFrom(
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 18),
                                  side: const BorderSide(color: Colors.white24),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(16))),
                              icon: const Icon(Icons.g_mobiledata,
                                  color: Colors.white, size: 30),
                              label: const Text('Continue with Google',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
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
                                  fontWeight: FontWeight.bold))
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
