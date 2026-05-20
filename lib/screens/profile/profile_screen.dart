// lib/screens/profile/profile_screen.dart
import 'dart:async';
import 'dart:convert';

import 'package:allowance/screens/home/create_story_screen.dart';
import 'package:allowance/screens/home/story_viewer_screen.dart';
import 'package:allowance/screens/home/subscription_screen.dart';
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
  List<Map<String, dynamic>> _memories = [];
  StreamSubscription? _memoriesSub;
  bool _isLoadingProfile = true;

  @override
  void initState() {
    super.initState();
    _loadCachedProfile();
    _fetchProfile();
    _setupMemoriesStream();
  }

  @override
  void dispose() {
    _memoriesSub?.cancel();
    super.dispose();
  }

  Future<void> _loadCachedProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final myId = Supabase.instance.client.auth.currentUser?.id;
    if (myId == null) return;

    final cachedProfile = prefs.getString('cached_profile_$myId');
    final cachedMemories = prefs.getString('cached_memories_$myId');

    if (mounted) {
      setState(() {
        if (cachedProfile != null) {
          _cachedProfileData = jsonDecode(cachedProfile);
        }
        if (cachedMemories != null) {
          _memories =
              List<Map<String, dynamic>>.from(jsonDecode(cachedMemories));
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
                    onTap: () {/* Placeholder for Terms */},
                    child: const Text("Terms of Agreement",
                        style: TextStyle(color: Colors.white38, fontSize: 12)),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8.0),
                    child: Text(".",
                        style: TextStyle(
                            color: Colors.white38,
                            fontWeight: FontWeight.bold)),
                  ),
                  GestureDetector(
                    onTap: () {
                      // Open: https://www.freeprivacypolicy.com/live/c2d1ccb0-132f-4ec9-b087-5ada740e3a4f
                    },
                    child: const Text("Privacy Policy",
                        style: TextStyle(color: Colors.white38, fontSize: 12)),
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

  Future<void> _signOut() async {
    setState(() => _signingOut = true);
    try {
      final supabase = Supabase.instance.client;
      await supabase.auth.signOut();

      await widget.userPreferences.clearLocal();

      if (mounted) {
        // Using rootNavigator: true and pushAndRemoveUntil ensures
        // the app clears the screen stack immediately, preventing the red flicker.
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

    // --- REVERTED: Standard Scaffold Body without _buildShell ---
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

            // Avatar with Plus Icon Stack
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
                          child: CircleAvatar(
                              radius: 14,
                              backgroundColor: _accent,
                              child: const Icon(Icons.add,
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
                      : 'No bio yet • Tap "Edit profile" to add one',
                  style: TextStyle(
                      color: up.bio?.trim().isNotEmpty == true
                          ? Colors.white70
                          : Colors.white38,
                      fontSize: 15),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 60),
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                    color: _card, borderRadius: BorderRadius.circular(12)),
                child: Row(
                  children: [
                    _buildSegmentItem("Memories", 0),
                    _buildSegmentItem("Profile Card", 1),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            _selectedSegment == 0
                ? _buildInstagramStyleGrid()
                : Container(
                    decoration: BoxDecoration(
                        color: _card,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white10)),
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
            ElevatedButton.icon(
              icon: const Icon(Icons.edit_outlined, size: 20),
              label: const Text('Edit Profile'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: _accent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: () async {
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
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              onPressed: _signingOut ? null : _confirmLogout,
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("Terms of Agreement",
                    style: TextStyle(color: Colors.white38, fontSize: 11)),
                const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Text("•", style: TextStyle(color: Colors.white38))),
                GestureDetector(
                  onTap: () {},
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

  void _setupMemoriesStream() {
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;

    _memoriesSub = supabase
        .from('memories')
        .stream(primaryKey: ['id'])
        .eq('user_id', userId)
        .order('created_at', ascending: false)
        .listen((data) async {
          if (mounted) setState(() => _memories = data);
          final prefs = await SharedPreferences.getInstance();
          prefs.setString('cached_memories_$userId', jsonEncode(data));
        });
  }

  Widget _buildInstagramStyleGrid() {
    if (_memories.isEmpty) {
      return Container(
        height: 200,
        alignment: Alignment.center,
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_library_outlined, color: Colors.white24, size: 40),
            SizedBox(height: 8),
            Text("No Memories yet", style: TextStyle(color: Colors.white38)),
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
      itemCount: _memories.length,
      itemBuilder: (context, index) {
        return MemoryGridItem(memories: _memories, index: index);
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

// ADD THIS CLASS AT THE BOTTOM OF YOUR FILE
class VerticalMemoryFeed extends StatelessWidget {
  final List<dynamic> memories;
  final int initialIndex;

  const VerticalMemoryFeed({
    super.key,
    required this.memories,
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
        scrollDirection: Axis.vertical, // This makes it slide like TikTok
        itemCount: memories.length,
        itemBuilder: (context, index) {
          return EnlargedMemoryScreen(memory: memories[index]);
        },
      ),
    );
  }
}

class MemoryGridItem extends StatefulWidget {
  final List<Map<String, dynamic>> memories; // Changed from single map
  final int index; // Added index

  const MemoryGridItem(
      {super.key, required this.memories, required this.index});

  @override
  State<MemoryGridItem> createState() => _MemoryGridItemState();
}

class _MemoryGridItemState extends State<MemoryGridItem> {
  VideoPlayerController? _videoController;
  bool _isVideo = false;
  late Map<String, dynamic> memory; // Local variable for convenience

  @override
  void initState() {
    super.initState();
    // Grab the specific memory using the index
    memory = widget.memories[widget.index];
    _isVideo = memory['media_type'] == 'video';

    if (_isVideo) {
      _videoController =
          VideoPlayerController.networkUrl(Uri.parse(memory['media_url']))
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
            builder: (context) => VerticalMemoryFeed(
              memories: widget.memories, // FIX: Pass the entire list
              initialIndex: widget.index, // FIX: Pass the starting index
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
                imageUrl: memory['media_url'], // Updated to use local variable
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

class EnlargedMemoryScreen extends StatefulWidget {
  final Map<String, dynamic> memory;
  const EnlargedMemoryScreen({super.key, required this.memory});

  @override
  State<EnlargedMemoryScreen> createState() => _EnlargedMemoryScreenState();
}

class _EnlargedMemoryScreenState extends State<EnlargedMemoryScreen> {
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    if (widget.memory['media_type'] == 'video') {
      _videoController = VideoPlayerController.networkUrl(
          Uri.parse(widget.memory['media_url']))
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

  // --- NEW MENU BOTTOM SHEET FOR DELETE ---
  void _showMemoryOptions(BuildContext context, dynamic memoryId) {
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
              title: const Text('Delete Memory',
                  style: TextStyle(color: Colors.redAccent, fontSize: 16)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteMemory(memoryId);
              },
            ),
          ],
        ),
      ),
    );
  }

  // --- NEW DELETE FUNCTION ---
  Future<void> _deleteMemory(dynamic memoryId) async {
    try {
      await Supabase.instance.client
          .from('memories')
          .delete()
          .eq('id', memoryId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Memory deleted successfully')),
        );
        Navigator.pop(context); // Pop back out of the memory viewer
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete memory: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.memory['media_type'] == 'video';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. BACKGROUND MEDIA LAYER
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
                    imageUrl: widget.memory['media_url'],
                    fit: BoxFit.contain,
                    placeholder: (context, url) =>
                        const CircularProgressIndicator(
                            color: Color(0xFF4CAF50)),
                  ),
          ),

          // 2. TOP CONTROLS (Back Button & Hamburger Menu)
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
                    icon: const Icon(Icons.more_vert,
                        color: Colors.white), // Hamburger Menu
                    onPressed: () =>
                        _showMemoryOptions(context, widget.memory['id']),
                  ),
                ],
              ),
            ),
          ),

          // 3. BOTTOM CONTROLS (Caption & Video Progress Bar)
          Positioned(
            bottom: 20,
            left: 20,
            right: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.memory['caption'] != null &&
                    widget.memory['caption'].toString().isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      widget.memory['caption'],
                      style: const TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ),

                // PROGRESS BAR NOW PINNED BELOW CAPTION
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
