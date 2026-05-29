// lib/screens/profile/profile_screen.dart
import 'dart:async';
import 'dart:convert';

import 'package:allowance/screens/home/create_story_screen.dart';
import 'package:allowance/screens/home/home_screen.dart';
import 'package:allowance/screens/home/story_viewer_screen.dart';
import 'package:allowance/screens/home/subscription_screen.dart';
import 'package:allowance/screens/settings/terms_screen.dart';
import 'package:allowance/widgets/universal_profile_card.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:allowance/screens/introduction/introduction_screen.dart';
import 'package:video_player/video_player.dart';
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
  int _selectedSegment = 0;

  Map<String, dynamic>? _cachedProfileData;
  List<Map<String, dynamic>> _moments = [];
  StreamSubscription? _momentsSub;
  bool _isLoadingProfile = true;

  @override
  void initState() {
    super.initState();
    _loadCachedProfile();
    _fetchProfile();
    _setupMomentsStream();
  }

  @override
  void dispose() {
    _momentsSub?.cancel();
    super.dispose();
  }

  Future<void> _loadCachedProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final myId = Supabase.instance.client.auth.currentUser?.id;
    if (myId == null) return;

    final cachedProfile = prefs.getString('cached_profile_$myId');
    final cachedMoments =
        prefs.getString('cached_moments_$myId'); // Updated key

    if (mounted) {
      setState(() {
        if (cachedProfile != null) {
          _cachedProfileData = jsonDecode(cachedProfile);
        }
        if (cachedMoments != null) {
          _moments = List<Map<String, dynamic>>.from(
              jsonDecode(cachedMoments)); // Updated cache
        }
        _isLoadingProfile = _cachedProfileData == null;
      });
    }
  }

  Future<void> _refreshProfile() async {
    await _fetchProfile();
  }

  void _showUserList(String title, bool showFollowers) {
    final supabase = Supabase.instance.client;
    final currentUserId = supabase.auth.currentUser?.id;

    showModalBottomSheet(
      context: context,
      backgroundColor: _card,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        expand: false,
        builder: (context, scrollController) => Column(
          children: [
            const SizedBox(height: 12),
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2))),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
            ),
            const Divider(color: Colors.white10),
            Expanded(
              child: FutureBuilder<List<dynamic>>(
                // Fetching from 'followers' and joining 'profiles'
                future: supabase.from('followers').select('''
                  *,
                  profiles!${showFollowers ? 'follower_id' : 'following_id'} (
                    id, 
                    username, 
                    avatar_url, 
                    school_name
                  )
                ''').eq(showFollowers ? 'following_id' : 'follower_id', currentUserId!),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                        child: CircularProgressIndicator(color: _accent));
                  }

                  if (snapshot.hasError) {
                    return Center(
                      child: Text("Error: ${snapshot.error}",
                          style: const TextStyle(color: Colors.redAccent)),
                    );
                  }

                  final data = snapshot.data ?? [];
                  if (data.isEmpty) {
                    return Center(
                      child: Text("No ${title.toLowerCase()} found",
                          style: const TextStyle(color: Colors.white38)),
                    );
                  }

                  return ListView.builder(
                    controller: scrollController,
                    itemCount: data.length,
                    itemBuilder: (context, index) {
                      final profile = data[index]['profiles'];
                      if (profile == null) return const SizedBox.shrink();

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.grey[850],
                          backgroundImage: profile['avatar_url'] != null
                              ? NetworkImage(profile['avatar_url'])
                              : null,
                          child: profile['avatar_url'] == null
                              ? const Icon(Icons.person, color: Colors.white54)
                              : null,
                        ),
                        title: Text(profile['username'] ?? 'Unknown',
                            style: const TextStyle(color: Colors.white)),
                        subtitle: Text(profile['school_name'] ?? '',
                            style: const TextStyle(color: Colors.white54)),
                        onTap: () {
                          Navigator.pop(context);
                          // Using your static show method to view their profile card[cite: 4]
                          UniversalProfileCard.show(
                              context, profile['id'], widget.userPreferences);
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmLogout() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Log Out',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              const SizedBox(height: 16),
              const Text('Are you sure you want to log out?',
                  style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Cancel',
                          style: TextStyle(color: Colors.white)),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4CAF50)),
                      onPressed: () {
                        Navigator.pop(ctx);
                        _signOut();
                      },
                      child: const Text('Log Out',
                          style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const TermsScreen()));
                    },
                    child: const Text("Terms of Agreement",
                        style: TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                            decoration: TextDecoration.underline)),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text("•",
                        style: TextStyle(
                            color: Colors.white38,
                            fontWeight: FontWeight.bold)),
                  ),
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const TermsScreen()));
                    },
                    child: const Text("Privacy Policy",
                        style: TextStyle(
                            color: Colors.white38,
                            fontSize: 12,
                            decoration: TextDecoration.underline)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  // --- NEW: SAVE CURRENT SESSION FOR SWITCHING ---
  Future<void> _saveCurrentSessionLocal(
      Map<String, dynamic> profileData) async {
    final supabase = Supabase.instance.client; // <-- FIX ADDED HERE
    final session = supabase.auth.currentSession;
    final user = supabase.auth.currentUser;
    if (session == null || user == null || session.refreshToken == null) return;

    final prefs = await SharedPreferences.getInstance();
    final savedStr = prefs.getString('saved_accounts') ?? '[]';
    List<dynamic> savedAccounts = jsonDecode(savedStr);

    final newAccount = {
      'id': user.id,
      'email': user.email,
      'username': profileData['username'] ?? 'User',
      'avatar_url': profileData['avatar_url'] ?? '',
      'refresh_token': session.refreshToken,
    };

    // Remove if it exists to update it with the freshest token
    savedAccounts.removeWhere((acc) => acc['id'] == user.id);
    savedAccounts.insert(0, newAccount); // Put current at top

    await prefs.setString('saved_accounts', jsonEncode(savedAccounts));
  }

  // --- NEW: SWITCH ACCOUNT SHEET ---
  Future<void> _showSwitchAccountSheet() async {
    final supabase = Supabase.instance.client; // <-- FIX ADDED HERE
    final prefs = await SharedPreferences.getInstance();
    final savedStr = prefs.getString('saved_accounts') ?? '[]';
    List<dynamic> savedAccounts = jsonDecode(savedStr);

    if (!mounted) return;

    showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF1E1E1E),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Switch Account',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                ...savedAccounts.map((acc) {
                  final isCurrent = acc['id'] == supabase.auth.currentUser?.id;
                  return ListTile(
                    leading: CircleAvatar(
                      backgroundImage: acc['avatar_url'].toString().isNotEmpty
                          ? NetworkImage(acc['avatar_url'])
                          : null,
                      backgroundColor: Colors.grey[800],
                      child: acc['avatar_url'].toString().isEmpty
                          ? const Icon(Icons.person, color: Colors.white)
                          : null,
                    ),
                    title: Text(acc['username'],
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold)),
                    subtitle: Text(acc['email'],
                        style: const TextStyle(
                            color: Colors.white54, fontSize: 12)),
                    trailing: isCurrent
                        ? const Icon(Icons.check_circle,
                            color: Color(0xFF4CAF50))
                        : null,
                    onTap: isCurrent
                        ? null
                        : () async {
                            Navigator.pop(ctx);
                            await _switchToAccount(acc['refresh_token']);
                          },
                  );
                }).toList(),
                const Divider(color: Colors.white24),
                ListTile(
                  leading: const CircleAvatar(
                      backgroundColor: Colors.transparent,
                      child: Icon(Icons.add, color: Colors.white)),
                  title: const Text('Add Account',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    // Passing true keeps saved accounts so they show up on the login screen
                    _signOut(keepSavedAccounts: true);
                  },
                )
              ],
            ),
          );
        });
  }

  // --- NEW: SWITCH TO ACCOUNT (PASSWORDLESS) ---
  Future<void> _switchToAccount(String refreshToken) async {
    final supabase = Supabase.instance.client; // <-- FIX ADDED HERE
    showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(
            child: CircularProgressIndicator(color: Color(0xFF4CAF50))));
    try {
      final response = await supabase.auth.setSession(refreshToken);
      if (response.user != null) {
        await widget.userPreferences.clearLocal();
        await widget.userPreferences.loadPreferences();

        if (mounted) {
          Navigator.pop(context); // close dialog
          Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
            MaterialPageRoute(
                builder: (_) =>
                    HomeScreen(userPreferences: widget.userPreferences)),
            (route) => false,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Session expired. Please log in again.')));
        _signOut(keepSavedAccounts: true);
      }
    }
  }

  Future<void> _deleteAccount() async {
    final supabase = Supabase.instance.client; // <-- FIX ADDED HERE
    setState(() => _signingOut = true);
    try {
      await supabase.rpc('delete_user');
      await _signOut(keepSavedAccounts: false, removeCurrentFromSaved: true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to delete account: $e')));
        setState(() => _signingOut = false);
      }
    }
  }

  Future<void> _signOut(
      {bool keepSavedAccounts = false,
      bool removeCurrentFromSaved = false}) async {
    final supabase = Supabase.instance.client; // <-- FIX ADDED HERE
    setState(() => _signingOut = true);
    try {
      final currentUser = supabase.auth.currentUser;
      final prefs = await SharedPreferences.getInstance();

      // Only remove this specific account if they are doing a hard log out / delete
      if ((removeCurrentFromSaved || !keepSavedAccounts) &&
          currentUser != null) {
        final savedStr = prefs.getString('saved_accounts') ?? '[]';
        List<dynamic> savedAccounts = jsonDecode(savedStr);
        savedAccounts.removeWhere((acc) => acc['id'] == currentUser.id);
        await prefs.setString('saved_accounts', jsonEncode(savedAccounts));
      }

      await supabase.auth.signOut();
      await widget.userPreferences.clearLocal();

      if (mounted) {
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => IntroductionScreen(
              userPreferences: widget.userPreferences,
              onFinishIntro: () {},
            ),
          ),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not sign out. Try again.'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  // --- NEW: SWITCH ACCOUNT SHEET ---

  // --- NEW: SWITCH TO ACCOUNT (PASSWORDLESS) ---

  // --- NEW: DELETE ACCOUNT DIALOG ---
  Future<void> _confirmDeleteAccount() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: Colors.redAccent, size: 48),
            const SizedBox(height: 16),
            const Text('Delete Account',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.redAccent)),
            const SizedBox(height: 16),
            const Text(
                'Are you absolutely sure you want to delete your account? This action is permanent and cannot be undone.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 32),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.white)),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent),
                    onPressed: () {
                      Navigator.pop(ctx);
                      _deleteAccount();
                    },
                    child: const Text('Delete',
                        style: TextStyle(
                            color: Colors.black, fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }

  // --- NEW UI HELPER FOR THE 4 BUTTONS ---
  Widget _buildActionRow() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildCircularAction(
          icon: Icons.edit_outlined,
          color: _accent,
          label: 'Edit',
          onTap: () async {
            final changed = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                    builder: (_) => EditProfileScreen(
                        userPreferences: widget.userPreferences)));
            if (changed == true) {
              await widget.userPreferences.loadPreferences();
              _refreshProfile();
              widget.onSave();
            }
          },
        ),
        _buildCircularAction(
          icon: Icons.swap_horiz,
          color: Colors.blueAccent,
          label: 'Switch',
          onTap: _showSwitchAccountSheet,
        ),
        _buildCircularAction(
          icon: Icons.logout_rounded,
          color: Colors.orange,
          label: 'Log Out',
          onTap: _signingOut ? null : _confirmLogout,
        ),
        _buildCircularAction(
          icon: Icons.delete_forever,
          color: Colors.redAccent,
          backgroundColor: Colors.black,
          label: 'Delete',
          onTap: _signingOut ? null : _confirmDeleteAccount,
        ),
      ],
    );
  }

  Widget _buildCircularAction({
    required IconData icon,
    required Color color,
    required String label,
    required VoidCallback? onTap,
    Color? backgroundColor,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: backgroundColor ?? color.withOpacity(0.15),
              border: Border.all(color: color.withOpacity(0.5), width: 1.5),
            ),
            child: Icon(icon, color: color, size: 26),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingProfile) {
      return const Scaffold(
        backgroundColor: _bg,
        body: Center(child: CircularProgressIndicator(color: _accent)),
      );
    }

    final profile = _cachedProfileData;

    if (profile == null) {
      return const Scaffold(
          backgroundColor: _bg,
          body: Center(
              child: Text("Profile Error",
                  style: TextStyle(color: Colors.white))));
    }

    final up = widget.userPreferences;
    final isPlus = up.subscriptionTier == 'Membership';
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
        title: Image.asset('assets/images/profile.png',
            height: 100, fit: BoxFit.contain),
        automaticallyImplyLeading: false,
        actions: [
          if (isPlus)
            IconButton(
                icon: const Icon(Icons.remove_red_eye_outlined, color: _accent),
                onPressed: () {},
                tooltip: 'Profile Visibility'),
        ],
      ),
      body: RefreshIndicator(
        color: _accent,
        onRefresh: _refreshProfile,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 20),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildStatItem(
                      'Followers',
                      (profile['follower_count'] ?? 0).toString(),
                      () => _showUserList('Followers', true)),
                  const SizedBox(width: 110),
                  _buildStatItem(
                      'Following',
                      (profile['following_count'] ?? 0).toString(),
                      () => _showUserList('Following', false)),
                ],
              ),
            ),
            Column(
              children: [
                SizedBox(
                  width: 110,
                  height: 110,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      GestureDetector(
                        onTap: () async {
                          final supabase = Supabase.instance.client;
                          final response = await supabase
                              .from('stories')
                              .select(
                                  '*, profiles:user_id(username, avatar_url)')
                              .eq('user_id', supabase.auth.currentUser!.id)
                              .gt('expires_at',
                                  DateTime.now().toUtc().toIso8601String())
                              .order('created_at', ascending: false);
                          final myStories = response as List<dynamic>;
                          if (myStories.isNotEmpty && mounted) {
                            Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => StoryViewerScreen(
                                        stories: myStories,
                                        initialIndex: 0,
                                        userPreferences:
                                            widget.userPreferences)));
                          } else if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                    content: Text(
                                        'You have no active stories yet')));
                          }
                        },
                        child: Container(
                          width: 110,
                          height: 110,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: _accent, width: 3)),
                          child: CircleAvatar(
                            radius: 48,
                            backgroundColor: Colors.grey[850],
                            backgroundImage: imageProvider,
                            child: imageProvider == null
                                ? Text(
                                    (up.fullName ?? '?').isNotEmpty
                                        ? up.fullName![0].toUpperCase()
                                        : '?',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 34))
                                : null,
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 4,
                        right: 4,
                        child: GestureDetector(
                          onTap: () {
                            if (isPlus)
                              Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                      builder: (_) => CreateStoryScreen(
                                          userPreferences:
                                              widget.userPreferences)));
                            else
                              _showUpgradeSheet(context);
                          },
                          child: const CircleAvatar(
                              radius: 14,
                              backgroundColor: _accent,
                              child: Icon(Icons.add,
                                  color: Colors.black, size: 18)),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Text(up.fullName ?? 'No name',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
                Text('@${up.username ?? 'nouser'}',
                    style: const TextStyle(
                        color: _accent, fontWeight: FontWeight.w500)),
                const SizedBox(height: 16),
                Text(
                  up.bio?.trim().isNotEmpty == true
                      ? up.bio!
                      : 'No bio yet • Tap "Edit" below to add one',
                  style: TextStyle(
                      color: up.bio?.trim().isNotEmpty == true
                          ? Colors.white70
                          : Colors.white38,
                      fontSize: 15),
                  textAlign: TextAlign.center,
                ),
              ],
            ),

            const SizedBox(height: 32),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 60),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                    color: _card, borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    _buildSegmentItem("Moments", 0),
                    _buildSegmentItem("Profile Card", 1),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // --- MAIN CONTENT AREA (MEMORIES OR PROFILE) ---
            _selectedSegment == 0
                ? _buildInstagramStyleGrid()
                : Container(
                    decoration: BoxDecoration(
                      color: _card,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: Column(
                      children: [
                        if (profile['is_delivery_agent'] == true) ...[
                          SwitchListTile(
                            title: const Text('Available for Delivery 🛵',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 15)),
                            subtitle: const Text(
                                'Turn on to receive orders from students',
                                style: TextStyle(
                                    color: Colors.white54, fontSize: 12)),
                            value: profile['is_available_for_delivery'] == true,
                            activeColor: _accent,
                            onChanged: (val) async {
                              setState(() => _cachedProfileData![
                                  'is_available_for_delivery'] = val);
                              await Supabase.instance.client
                                  .from('profiles')
                                  .update({
                                'is_available_for_delivery': val
                              }).eq('id', profile['id']);
                            },
                          ),
                          const Divider(color: Colors.white10, height: 1),
                        ],
                        _buildProfileTile(Icons.school_outlined, 'Campus',
                            up.schoolName ?? 'Not set'),
                        const Divider(color: Colors.white10, height: 1),
                        _buildProfileTile(Icons.phone_outlined, 'Phone',
                            up.phoneNumber ?? 'Not set'),
                        const Divider(color: Colors.white10, height: 1),
                        _buildProfileTile(Icons.fitness_center_outlined,
                            'Weight', '${up.weight ?? 'Not set'} kg'),
                        const Divider(color: Colors.white10, height: 1),
                        _buildProfileTile(Icons.height_outlined, 'Height',
                            '${up.height ?? 'Not set'} cm'),
                        const Divider(color: Colors.white10, height: 1),
                        _buildProfileTile(Icons.cake_outlined, 'Age',
                            '${up.age ?? 'Not set'} years'),
                      ],
                    ),
                  ),

            const SizedBox(height: 48),

            _buildActionRow(),

            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                GestureDetector(
                  onTap: () {
                    Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const TermsScreen()));
                  },
                  child: const Text("Terms of Agreement",
                      style: TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                          decoration: TextDecoration.underline)),
                ),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text("•", style: TextStyle(color: Colors.white38))),
                GestureDetector(
                  onTap: () {
                    Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const TermsScreen()));
                  },
                  child: const Text("Privacy Policy",
                      style: TextStyle(
                          color: Colors.white38,
                          fontSize: 11,
                          decoration: TextDecoration.underline)),
                ),
              ],
            ),
            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }

// Helper for Stats
  Widget _buildStatItem(String label, String value, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }

// Helper for Profile Details
  Widget _buildProfileTile(IconData icon, String title, String value) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF4CAF50), size: 22),
      title: Text(title,
          style: const TextStyle(color: Colors.white54, fontSize: 13)),
      subtitle: Text(value,
          style: const TextStyle(
              color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500)),
      dense: true,
    );
  }

  // Helper for Upgrade Sheet
  void _showUpgradeSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_rounded, size: 64, color: Colors.amber),
            const SizedBox(height: 16),
            const Text(
              'JOIN THE ALLOWANCE PLUS FAMILY',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text(
              'Unlock Story Gist and profile customization.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4CAF50),
                    foregroundColor: Colors.black),
                onPressed: () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => SubscriptionScreen(
                        userPreferences: widget.userPreferences,
                        themeColor: _accent,
                      ),
                    ),
                  );
                },
                child: const Text('Subscribe to Allowance Plus',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _fetchProfile() async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return;

    try {
      final resp = await supabase
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();
      if (resp == null) return;
      final data = Map<String, dynamic>.from(resp);

      final followersResp = await supabase
          .from('followers')
          .select('*')
          .eq('following_id', user.id)
          .count(CountOption.exact);
      final followingResp = await supabase
          .from('followers')
          .select('*')
          .eq('follower_id', user.id)
          .count(CountOption.exact);

      data['follower_count'] = followersResp.count;
      data['following_count'] = followingResp.count;

      // Save to cache
      final prefs = await SharedPreferences.getInstance();
      prefs.setString('cached_profile_${user.id}', jsonEncode(data));

      // NEW: SAVE CURRENT SESSION FOR SWITCHING
      await _saveCurrentSessionLocal(data);

      if (mounted) {
        setState(() {
          _cachedProfileData = data;
          _isLoadingProfile = false;
        });
      }
    } catch (e) {
      if (mounted && _cachedProfileData == null) {
        setState(() => _isLoadingProfile = false);
      }
    }
  }

  void _setupMomentsStream() {
    // Renamed from _setupMemoriesStream
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    _momentsSub = supabase
        .from('moments') // Query moments table
        .stream(primaryKey: ['id'])
        .eq('user_id', userId)
        .order('created_at', ascending: false)
        .listen((data) async {
          if (mounted) setState(() => _moments = data);
          final prefs = await SharedPreferences.getInstance();
          prefs.setString(
              'cached_moments_$userId', jsonEncode(data)); // Updated cache key
        });
  }

  Widget _buildInstagramStyleGrid() {
    if (_moments.isEmpty) {
      return Container(
        height: 200,
        alignment: Alignment.center,
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_library_outlined, color: Colors.white24, size: 40),
            SizedBox(height: 8),
            Text("No Moments yet",
                style: TextStyle(color: Colors.white38)), // Updated string
          ],
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
        childAspectRatio: 0.8,
      ),
      itemCount: _moments.length,
      itemBuilder: (context, index) {
        return MomentGridItem(moments: _moments, index: index); // Updated class
      },
    );
  }

  Widget _buildSegmentItem(String title, int index) {
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _selectedSegment = index),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 8), // Reduced height
          decoration: BoxDecoration(
            color: _selectedSegment == index ? _accent : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _selectedSegment == index ? Colors.black : Colors.white54,
              fontWeight: FontWeight.bold,
              fontSize: 13.5, // Slightly smaller
            ),
          ),
        ),
      ),
    );
  }
}

// --- PASTE AT THE VERY BOTTOM OF profile_screen.dart ---

class VerticalMomentFeed extends StatelessWidget {
  // Renamed from VerticalMemoryFeed
  final List<dynamic> moments;
  final int initialIndex;

  const VerticalMomentFeed({
    super.key,
    required this.moments,
    required this.initialIndex,
  });

  @override
  Widget build(BuildContext context) {
    final PageController pageController =
        PageController(initialPage: initialIndex);

    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: pageController,
        scrollDirection: Axis.vertical,
        itemCount: moments.length,
        itemBuilder: (context, index) {
          return EnlargedMomentScreen(moment: moments[index]); // Updated class
        },
      ),
    );
  }
}

class MomentGridItem extends StatefulWidget {
  // Renamed from MemoryGridItem
  final List<Map<String, dynamic>> moments;
  final int index;

  const MomentGridItem({super.key, required this.moments, required this.index});

  @override
  State<MomentGridItem> createState() => _MomentGridItemState();
}

class _MomentGridItemState extends State<MomentGridItem> {
  VideoPlayerController? _videoController;
  bool _isVideo = false;
  late Map<String, dynamic> moment;

  @override
  void initState() {
    super.initState();
    moment = widget.moments[widget.index];
    _isVideo = moment['media_type'] == 'video';

    if (_isVideo) {
      _videoController =
          VideoPlayerController.networkUrl(Uri.parse(moment['media_url']))
            ..initialize().then((_) {
              if (mounted) setState(() {});
            });
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VerticalMomentFeed(
              moments: widget.moments,
              initialIndex: widget.index,
            ),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_isVideo)
              _videoController != null && _videoController!.value.isInitialized
                  ? FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: _videoController!.value.size.width,
                        height: _videoController!.value.size.height,
                        child: VideoPlayer(_videoController!),
                      ),
                    )
                  : Container(color: Colors.black)
            else
              CachedNetworkImage(
                imageUrl: moment['media_url'],
                fit: BoxFit.cover,
                placeholder: (context, url) =>
                    Container(color: Colors.grey[900]),
                errorWidget: (context, url, error) => Container(
                  color: Colors.grey[900],
                  child: const Icon(Icons.broken_image, color: Colors.white10),
                ),
              ),
            if (_isVideo)
              const Positioned(
                top: 5,
                right: 5,
                child: Icon(Icons.play_circle_filled,
                    color: Colors.white, size: 24),
              ),
          ],
        ),
      ),
    );
  }
}

class EnlargedMomentScreen extends StatefulWidget {
  // Renamed from EnlargedMemoryScreen
  final Map<String, dynamic> moment;
  const EnlargedMomentScreen({super.key, required this.moment});

  @override
  State<EnlargedMomentScreen> createState() => _EnlargedMomentScreenState();
}

class _EnlargedMomentScreenState extends State<EnlargedMomentScreen> {
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    if (widget.moment['media_type'] == 'video') {
      _videoController = VideoPlayerController.networkUrl(
          Uri.parse(widget.moment['media_url']))
        ..initialize().then((_) {
          if (mounted) setState(() {});
          _videoController!.setLooping(true);
          _videoController!.play();
        });
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  void _showMomentOptions(BuildContext context, dynamic momentId) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('Delete Moment',
                  style: TextStyle(color: Colors.redAccent, fontSize: 16)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteMoment(momentId);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _deleteMoment(dynamic momentId) async {
    try {
      await Supabase.instance.client
          .from('moments') // Changed query target to moments
          .delete()
          .eq('id', momentId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Moment deleted successfully')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete moment: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.moment['media_type'] == 'video';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: isVideo
                ? (_videoController != null &&
                        _videoController!.value.isInitialized
                    ? AspectRatio(
                        aspectRatio: _videoController!.value.aspectRatio,
                        child: VideoPlayer(_videoController!),
                      )
                    : const CircularProgressIndicator(color: Color(0xFF4CAF50)))
                : CachedNetworkImage(
                    imageUrl: widget.moment['media_url'],
                    fit: BoxFit.contain,
                    placeholder: (context, url) =>
                        const CircularProgressIndicator(
                            color: Color(0xFF4CAF50)),
                  ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  IconButton(
                    icon: const Icon(Icons.more_vert, color: Colors.white),
                    onPressed: () =>
                        _showMomentOptions(context, widget.moment['id']),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.moment['caption'] != null &&
                    widget.moment['caption'].toString().isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      widget.moment['caption'],
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),
                if (isVideo &&
                    _videoController != null &&
                    _videoController!.value.isInitialized) ...[
                  const SizedBox(height: 12),
                  VideoProgressIndicator(
                    _videoController!,
                    allowScrubbing: true,
                    colors: const VideoProgressColors(
                      playedColor: Color(0xFF4CAF50),
                      bufferedColor: Colors.white24,
                      backgroundColor: Colors.white10,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
