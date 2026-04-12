// lib/screens/profile/profile_screen.dart
import 'package:allowance/screens/home/create_story_screen.dart';
import 'package:allowance/screens/home/story_viewer_screen.dart';
import 'package:allowance/screens/home/subscription_screen.dart';
import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:allowance/screens/introduction/introduction_screen.dart';
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

  late Future<Map<String, dynamic>?> _profileFuture;

  @override
  void initState() {
    super.initState();
    _profileFuture = _fetchProfile();
  }

  void _refreshProfile() {
    setState(() {
      _profileFuture = _fetchProfile();
    });
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

    if (confirmed == true) await _signOut();
  }

  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    try {
      final supabase = Supabase.instance.client;
      await supabase.auth.signOut();

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
    return FutureBuilder<Map<String, dynamic>?>(
      future: _profileFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        if (snapshot.hasError) {
          final err = snapshot.error;
          debugPrint('Profile load error: $err');
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Error loading profile.\n${err.toString()}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }

        final profile = snapshot.data;

        if (profile == null) {
          final supabase = Supabase.instance.client;
          final user = supabase.auth.currentUser;

          return Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async {
                  try {
                    await supabase.from('profiles').insert({
                      'id': user?.id,
                      'created_at': DateTime.now().toIso8601String(),
                      'updated_at': DateTime.now().toIso8601String(),
                    });
                    await widget.userPreferences.loadPreferences();
                    if (!mounted) return;
                    _refreshProfile();
                  } catch (e) {
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Create profile failed: $e')),
                      );
                    }
                  }
                },
                child: const Text('Set up your profile'),
              ),
            ),
          );
        }

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
              height: 120,
              fit: BoxFit.contain,
            ),
            automaticallyImplyLeading: false,
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Column(
                children: [
                  // ==================== TAPABLE AVATAR WITH STORY RING + PLUS BUTTON ====================
                  GestureDetector(
                    onTap: () async {
                      // When user taps their own profile photo → open their story
                      final supabase = Supabase.instance.client;

                      final response = await supabase
                          .from('stories')
                          .select('''
      id, media_url, media_type, caption, url, expires_at, created_at, likes_count,
      profiles:user_id(username, avatar_url)
    ''')
                          .eq('user_id', supabase.auth.currentUser!.id)
                          .gt('expires_at',
                              DateTime.now().toUtc().toIso8601String())
                          .order('created_at', ascending: false);

                      final myStories = response as List<dynamic>;

                      if (myStories.isNotEmpty) {
                        if (!mounted) return;
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => StoryViewerScreen(
                              stories: myStories,
                              initialIndex: 0,
                            ),
                          ),
                        );
                      } else {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                              content: Text('You have no active stories yet')),
                        );
                      }
                    },
                    child: SizedBox(
                      width: 110,
                      height: 110,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Green glowing ring (visible when you have an active story)
                          Container(
                            width: 110,
                            height: 110,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFF4CAF50),
                                width: 5,
                              ),
                            ),
                          ),
                          // Main Avatar
                          CircleAvatar(
                            radius: 48,
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
                          // PLUS BUTTON FOR POSTING STORY
                          Positioned(
                            bottom: 4,
                            right: 4,
                            child: GestureDetector(
                              onTap: () async {
                                final isPlus =
                                    widget.userPreferences.subscriptionTier ==
                                        'Membership';
                                if (isPlus) {
                                  final result = await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => CreateStoryScreen(
                                        userPreferences: widget.userPreferences,
                                      ),
                                    ),
                                  );
                                  if (result == true) _refreshProfile();
                                } else {
                                  if (!mounted) return;
                                  showModalBottomSheet(
                                    context: context,
                                    backgroundColor: Colors.grey[900],
                                    shape: const RoundedRectangleBorder(
                                      borderRadius: BorderRadius.vertical(
                                          top: Radius.circular(20)),
                                    ),
                                    builder: (ctx) => Padding(
                                      padding: const EdgeInsets.all(24),
                                      child: Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          const Icon(Icons.lock_rounded,
                                              size: 64, color: Colors.amber),
                                          const SizedBox(height: 16),
                                          const Text(
                                            'JOIN THE ALLOWANCE PLUS FAMILY',
                                            style: TextStyle(
                                                fontSize: 22,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white),
                                          ),
                                          const SizedBox(height: 12),
                                          const Text(
                                            'to post Story Gist',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                                fontSize: 16,
                                                color: Colors.white70),
                                          ),
                                          const SizedBox(height: 8),
                                          const Text(
                                            'This unlocks full creative features across Allowance.',
                                            textAlign: TextAlign.center,
                                            style: TextStyle(
                                                color: Colors.white54,
                                                fontSize: 14),
                                          ),
                                          const SizedBox(height: 24),
                                          SizedBox(
                                            width: double.infinity,
                                            child: ElevatedButton(
                                              onPressed: () {
                                                Navigator.pop(ctx);
                                                Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        SubscriptionScreen(
                                                      userPreferences: widget
                                                          .userPreferences,
                                                      themeColor: _accent,
                                                    ),
                                                  ),
                                                );
                                              },
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: _accent,
                                                foregroundColor: Colors.white,
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        vertical: 16),
                                              ),
                                              child: const Text(
                                                  'Subscribe to Allowance Plus',
                                                  style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold)),
                                            ),
                                          ),
                                          TextButton(
                                            onPressed: () => Navigator.pop(ctx),
                                            child: const Text('Maybe later',
                                                style: TextStyle(
                                                    color: Colors.white70)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  );
                                }
                              },
                              child: const CircleAvatar(
                                radius: 14,
                                backgroundColor: Color(0xFF4CAF50),
                                child: Icon(Icons.add,
                                    color: Colors.black, size: 18),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // ==================== END TAPABLE AVATAR ====================

                  const SizedBox(height: 12),
                  Text(
                    up.fullName ?? 'No name',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text('@${up.username ?? 'nouser'}',
                      style: const TextStyle(color: Colors.white70)),

                  // BIO DISPLAY
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      up.bio?.trim().isNotEmpty == true
                          ? up.bio!
                          : 'No bio yet • Tap "Edit profile" to add one',
                      style: TextStyle(
                        color: up.bio?.trim().isNotEmpty == true
                            ? Colors.white70
                            : Colors.white54,
                        fontSize: 15,
                        height: 1.4,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
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
                      leading: const Icon(Icons.fitness_center,
                          color: Colors.white70),
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
                      leading:
                          const Icon(Icons.bloodtype, color: Colors.white70),
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
                            userPreferences: widget.userPreferences)),
                  );
                  if (changed == true) {
                    await widget.userPreferences.loadPreferences();
                    _refreshProfile();
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
      },
    );
  }

  Future<Map<String, dynamic>?> _fetchProfile() async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return null;
    try {
      final resp = await supabase
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();

      if (resp == null) return null;
      return Map<String, dynamic>.from(resp);
    } catch (e, st) {
      debugPrint('[_fetchProfile] error: $e\n$st');
      return null;
    }
  }
}
