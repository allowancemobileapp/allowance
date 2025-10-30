// lib/screens/profile/profile_screen.dart
import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:allowance/screens/introduction/introduction_screen.dart';
import 'package:allowance/screens/home/home_screen.dart';
import 'edit_profile_screen.dart';

const Color _bg = Color(0xFF121212);
const Color _card = Color(0xFF1E1E1E);
const Color _accent = Color(0xFF4CAF50);

class ProfileScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  final VoidCallback onSave;

  const ProfileScreen(
      {super.key, required this.userPreferences, required this.onSave});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _signingOut = false;

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

    if (confirmed == true) await _signOut();
  }

  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    try {
      final supabase = Supabase.instance.client;
      await supabase.auth.signOut();

      // Clear local preferences (so a new user starts fresh)
      await widget.userPreferences.clearLocal();

      if (mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
              builder: (_) => IntroductionScreen(
                  userPreferences: widget.userPreferences,
                  onFinishIntro: () {})),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not sign out. Try again.'),
            backgroundColor: Colors.red));
      }
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final up = widget.userPreferences;
    final avatarUrl = up.avatarUrl;
    final imageProvider = (avatarUrl != null && avatarUrl.isNotEmpty)
        ? NetworkImage(avatarUrl)
        : null;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        centerTitle: true,
        title: Image.asset(
          'assets/images/profile.png',
          height: 120, // adjust if you want it larger/smaller
          fit: BoxFit.contain,
        ),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Column(
            children: [
              SizedBox(
                width: 110,
                height: 110,
                child: CircleAvatar(
                  radius: 55,
                  backgroundColor: Colors.grey[850],
                  backgroundImage: imageProvider,
                  child: imageProvider == null
                      ? Text(
                          (up.fullName ?? '?').isNotEmpty
                              ? up.fullName![0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 34),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              Text(up.fullName ?? 'No name',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text('@${up.username ?? 'nouser'}',
                  style: const TextStyle(color: Colors.white70)),
            ],
          ),
          const SizedBox(height: 28),

          // Info card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                color: _card, borderRadius: BorderRadius.circular(12)),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.phone, color: Colors.white70),
                  title: const Text('Phone',
                      style: TextStyle(color: Colors.white70)),
                  subtitle: Text(up.phoneNumber ?? 'Not set',
                      style: const TextStyle(color: Colors.white)),
                ),
                const Divider(color: Colors.grey),
                ListTile(
                  leading:
                      const Icon(Icons.fitness_center, color: Colors.white70),
                  title: const Text('Weight',
                      style: TextStyle(color: Colors.white70)),
                  subtitle: Text(up.weight?.toString() ?? 'Not set',
                      style: const TextStyle(color: Colors.white)),
                ),
                const Divider(color: Colors.grey),
                ListTile(
                  leading: const Icon(Icons.height, color: Colors.white70),
                  title: const Text('Height',
                      style: TextStyle(color: Colors.white70)),
                  subtitle: Text(up.height?.toString() ?? 'Not set',
                      style: const TextStyle(color: Colors.white)),
                ),
                const Divider(color: Colors.grey),
                ListTile(
                  leading: const Icon(Icons.cake, color: Colors.white70),
                  title: const Text('Age',
                      style: TextStyle(color: Colors.white70)),
                  subtitle: Text(up.age?.toString() ?? 'Not set',
                      style: const TextStyle(color: Colors.white)),
                ),
                const Divider(color: Colors.grey),
                ListTile(
                  leading: const Icon(Icons.bloodtype, color: Colors.white70),
                  title: const Text('Blood group',
                      style: TextStyle(color: Colors.white70)),
                  subtitle: Text(up.bloodGroup ?? 'Not set',
                      style: const TextStyle(color: Colors.white)),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          ElevatedButton.icon(
            icon: const Icon(Icons.edit_outlined),
            label: const Text('Edit profile'),
            style: ElevatedButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14)),
            onPressed: () async {
              final changed = await Navigator.of(context).push<bool>(
                  MaterialPageRoute(
                      builder: (_) => EditProfileScreen(
                          userPreferences: widget.userPreferences)));
              if (changed == true) {
                setState(() {}); // reload display from updated preferences
                widget.onSave();
              }
            },
          ),

          const SizedBox(height: 12),

          OutlinedButton.icon(
            icon: _signingOut
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.logout),
            label: const Text('Log out'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.redAccent,
              side: const BorderSide(color: Colors.redAccent),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            onPressed: _signingOut ? null : _confirmLogout,
          ),
        ],
      ),
    );
  }
}
