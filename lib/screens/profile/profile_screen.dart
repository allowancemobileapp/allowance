// lib/screens/profile/profile_screen.dart
import 'package:allowance/screens/home/create_story_screen.dart';
import 'package:allowance/screens/home/story_viewer_screen.dart';
import 'package:allowance/screens/home/subscription_screen.dart';
import 'package:allowance/widgets/universal_profile_card.dart';
import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:allowance/screens/introduction/introduction_screen.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
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
                          UniversalProfileCard.show(context, profile['id']);
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
            backgroundColor: _bg,
            body: Center(child: CircularProgressIndicator(color: _accent)),
          );
        }

        if (snapshot.hasError) {
          final err = snapshot.error;
          debugPrint('Profile load error: $err');
          return Scaffold(
            backgroundColor: _bg,
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Text(
                  'Error loading profile.\n${err.toString()}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
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
            backgroundColor: _bg,
            body: Center(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: _accent),
                onPressed: () async {
                  try {
                    await supabase.from('profiles').insert({
                      'id': user?.id,
                      'created_at': DateTime.now().toUtc().toIso8601String(),
                      'updated_at': DateTime.now().toUtc().toIso8601String(),
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
                child: const Text('Set up your profile',
                    style: TextStyle(color: Colors.black)),
              ),
            ),
          );
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
            title: Image.asset(
              'assets/images/profile.png',
              height: 100,
              fit: BoxFit.contain,
            ),
            automaticallyImplyLeading: false,
            actions: [
              if (isPlus)
                IconButton(
                  icon:
                      const Icon(Icons.remove_red_eye_outlined, color: _accent),
                  onPressed: () {},
                  tooltip: 'Profile Visibility',
                ),
            ],
          ),

          // Floating Action Button - Memories Tab Only
          // floatingActionButton: _selectedSegment == 0
          //     ? FloatingActionButton(
          //         backgroundColor: _accent,
          //         child: const Icon(Icons.add, color: Colors.black, size: 28),
          //         onPressed: () {
          //           if (isPlus) {
          //             _pickMemoryFlow(context);
          //           } else {
          //             _showUpgradeSheet(context);
          //           }
          //         },
          //       )
          //     : null,

          body: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            children: [
              // Stats Header
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

              // Avatar with Plus Icon
              Column(
                children: [
                  GestureDetector(
                    onTap: () async {
                      final supabase = Supabase.instance.client;
                      final response = await supabase
                          .from('stories')
                          .select('*, profiles:user_id(username, avatar_url)')
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
                              userPreferences: widget.userPreferences,
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
                          Container(
                            width: 110,
                            height: 110,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(color: _accent, width: 3),
                            ),
                          ),
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
                          // Plus Icon - Only visible to trigger story creation / upgrade
                          Positioned(
                            bottom: 4,
                            right: 4,
                            child: GestureDetector(
                              onTap: () {
                                if (isPlus) {
                                  _pickMemoryFlow(context);
                                } else {
                                  _showUpgradeSheet(context);
                                }
                              },
                              child: CircleAvatar(
                                radius: 14,
                                backgroundColor: _accent,
                                child: const Icon(Icons.add,
                                    color: Colors.black, size: 18),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    up.fullName ?? 'No name',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '@${up.username ?? 'nouser'}',
                    style: const TextStyle(
                        color: _accent, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    up.bio?.trim().isNotEmpty == true
                        ? up.bio!
                        : 'No bio yet • Tap "Edit profile" to add one',
                    style: TextStyle(
                      color: up.bio?.trim().isNotEmpty == true
                          ? Colors.white70
                          : Colors.white38,
                      fontSize: 15,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),

              const SizedBox(height: 24),

              // Segmented Control
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 60),
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      _buildSegmentItem("Memories", 0),
                      _buildSegmentItem("Profile Card", 1),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // Content Area
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

              const SizedBox(height: 24),

              // Actions
              ElevatedButton.icon(
                icon: const Icon(Icons.edit_outlined, size: 20),
                label: const Text('Edit Profile'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
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
                    : const Icon(Icons.logout_rounded, size: 20),
                label: const Text('Log Out'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  side: const BorderSide(color: Colors.redAccent),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: _signingOut ? null : _confirmLogout,
              ),
              const SizedBox(height: 80),
            ],
          ),
        );
      },
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

  Future<Map<String, dynamic>?> _fetchProfile() async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return null;

    try {
      // 1. Fetch basic profile data
      final resp = await supabase
          .from('profiles')
          .select()
          .eq('id', user.id)
          .maybeSingle();

      if (resp == null) return null;
      final data = Map<String, dynamic>.from(resp);

      // 2. Fetch Follower Count (people following YOU)
      final followersResp = await supabase
          .from('followers')
          .select('*')
          .eq('following_id', user.id)
          .count(CountOption.exact);

      // 3. Fetch Following Count (people YOU follow)[cite: 4]
      final followingResp = await supabase
          .from('followers')
          .select('*')
          .eq('follower_id', user.id)
          .count(CountOption.exact);

      // 4. Inject these counts into the data map so the build method sees them[cite: 4]
      data['follower_count'] = followersResp.count;
      data['following_count'] = followingResp.count;

      return data;
    } catch (e, st) {
      debugPrint('[_fetchProfile] error: $e\n$st');
      return null;
    }
  }

  Future<void> _pickMemoryFlow(BuildContext context) async {
    final List<AssetEntity>? result = await AssetPicker.pickAssets(
      context,
      pickerConfig: const AssetPickerConfig(
        maxAssets: 1,
        requestType: RequestType.common,
        themeColor: _accent,
      ),
    );

    if (result != null && result.isNotEmpty) {
      // Navigate to CreateStoryScreen to edit/trim the selection
      if (!mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              CreateStoryScreen(userPreferences: widget.userPreferences),
        ),
      );
    }
  }

  Widget _buildInstagramStyleGrid() {
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser?.id;

    if (userId == null) return const SizedBox.shrink();

    return StreamBuilder<List<Map<String, dynamic>>>(
      // Connects to Supabase 'memories' table and listens for real-time changes
      stream: supabase
          .from('memories')
          .stream(primaryKey: ['id'])
          .eq('user_id', userId)
          .order('created_at', ascending: false),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SizedBox(
            height: 200,
            child: Center(child: CircularProgressIndicator(color: _accent)),
          );
        }

        final memories = snapshot.data ?? [];

        if (memories.isEmpty) {
          return Container(
            height: 200,
            alignment: Alignment.center,
            child: const Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.photo_library_outlined,
                    color: Colors.white24, size: 40),
                SizedBox(height: 8),
                Text("No Memories yet",
                    style: TextStyle(color: Colors.white38)),
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
          itemCount: memories.length,
          itemBuilder: (context, index) {
            final memory = memories[index];
            final isVideo = memory['is_video'] == true;

            return GestureDetector(
              onTap: () {
                // Navigate to your viewer here if needed
              },
              child: Container(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Network image for the thumbnail
                    Image.network(
                      memory['media_url'],
                      fit: BoxFit.cover,
                      errorBuilder: (ctx, _, __) => Container(
                        color: _card,
                        child: const Icon(Icons.broken_image,
                            color: Colors.white10),
                      ),
                    ),
                    // If it's a video, overlay a play icon
                    if (isVideo)
                      const Positioned(
                        top: 5,
                        right: 5,
                        child: Icon(Icons.play_circle_filled,
                            color: Colors.white70, size: 20),
                      ),
                  ],
                ),
              ),
            );
          },
        );
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
