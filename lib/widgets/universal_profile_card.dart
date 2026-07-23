// lib/widgets/universal_profile_card.dart
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/chat/individual_chat_screen.dart';
import 'package:allowance/screens/home/moment_viewer_screen.dart';
import 'package:allowance/screens/home/story_viewer_screen.dart';
import 'package:allowance/services/subscription_service.dart'; // New Import
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';

class UniversalProfileCard extends StatefulWidget {
  final String targetUserId;
  final UserPreferences userPreferences;
  const UniversalProfileCard({
    super.key,
    required this.targetUserId,
    required this.userPreferences,
  });

  static void show(
      BuildContext context, String userId, UserPreferences userPreferences) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (_, scrollController) => UniversalProfileCard(
          targetUserId: userId,
          userPreferences: userPreferences, // Pass the required argument here
        ),
      ),
    );
  }

  @override
  State<UniversalProfileCard> createState() => _UniversalProfileCardState();
}

class _UniversalProfileCardState extends State<UniversalProfileCard> {
  final supabase = Supabase.instance.client;
  final Color themeColor = const Color(0xFF4CAF50);

  Map<String, dynamic>? _profile;
  int _followerCount = 0;
  bool _isFollowing = false;
  bool _isLoading = true;
  int _followingCount = 0; // Added this
  bool? _hasActiveStories;
  bool _isSubscribedToAlerts = false; // <-- NEW
  int _totalMomentsCount = 0; // Renamed from _totalMemoriesCount
  List<dynamic> _moments = []; // Renamed from _memories
  bool _isLoadingMoreMoments = false;
  bool _hasMoreMoments = true;

  @override
  void initState() {
    super.initState();
    _loadProfileData();
  }

  // --- UPDATED: LAZY LOADING PREVENTS LAG SPIKES ---
  // --- UPDATED: ULTRA-FAST LAZY LOADING ---
  void _loadProfileData() {
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) return;

    final String safeId = widget.targetUserId.toString().trim();

    // 1. Fetch ONLY the Profile instantly and independently
    supabase
        .from('profiles')
        .select()
        .eq('id', safeId)
        .maybeSingle()
        .then((profileResp) {
      if (mounted) {
        setState(() {
          _profile = profileResp;
          _isLoading = false; // 🔥 Card UI appears instantly!
        });

        // 2. Offload the heavy counts and moments to a background task so it doesn't freeze the animation
        Future.microtask(
            () => _loadHeavyProfileData(currentUserId, safeId, profileResp));
      }
    }).catchError((e) {
      debugPrint("Profile load error: $e");
      if (mounted) setState(() => _isLoading = false);
    });
  }

  Future<void> _loadMoreMoments() async {
    if (_isLoadingMoreMoments || !_hasMoreMoments) return;
    setState(() => _isLoadingMoreMoments = true);

    try {
      final res = await supabase
          .from('moments')
          .select(
              'id, user_id, media_url, media_type, category, created_at, likes_count, comments_count, profiles:user_id(username, avatar_url, school_name)')
          .eq('user_id', widget.targetUserId)
          .order('created_at', ascending: false)
          .range(_moments.length, _moments.length + 14);

      if (res.isEmpty) {
        if (mounted)
          setState(() {
            _hasMoreMoments = false;
            _isLoadingMoreMoments = false;
          });
        return;
      }
      if (mounted) {
        setState(() {
          _moments.addAll(res);
          _isLoadingMoreMoments = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingMoreMoments = false);
    }
  }

  // --- NEW: FETCH HEAVY DATA IN THE BACKGROUND ---
  Future<void> _loadHeavyProfileData(String currentUserId, String safeId,
      Map<String, dynamic>? profileResp) async {
    try {
      // 🔥 FIX: Using .select('id') instead of .select('*') stops downloading massive lists of data just to count them!
      final results = await Future.wait<dynamic>([
        supabase
            .from('followers')
            .select('follower_id')
            .eq('following_id', safeId)
            .count(CountOption.exact),
        supabase
            .from('followers')
            .select('follower_id')
            .eq('follower_id', currentUserId)
            .eq('following_id', safeId)
            .maybeSingle(),
        supabase
            .from('moments')
            .select('id')
            .eq('user_id', safeId)
            .count(CountOption.exact),
        supabase
            .from('followers')
            .select('following_id')
            .eq('follower_id', safeId)
            .count(CountOption.exact),
        supabase
            .from('stories')
            .select('id')
            .eq('user_id', safeId)
            .gt('expires_at', DateTime.now().toUtc().toIso8601String())
            .limit(1),
        supabase
            .from('post_alerts')
            .select('target_user_id')
            .eq('subscriber_id', currentUserId)
            .eq('target_user_id', safeId)
            .maybeSingle(),
      ]);

      final isPrivate = profileResp?['is_private'] == true;
      final isFollowingStatus = results[1] != null;
      final isMe = currentUserId == safeId;

      List<dynamic> fetchedMoments = [];
      if (profileResp != null && (!isPrivate || isFollowingStatus || isMe)) {
        fetchedMoments = await supabase
            .from('moments')
            // 🔥 Reduced columns to only what is absolutely needed for the grid to prevent memory crash
            .select(
                'id, user_id, media_url, media_type, category, created_at, likes_count, comments_count, profiles:user_id(username, avatar_url, school_name)')
            .eq('user_id', safeId)
            .order('created_at', ascending: false)
            .limit(15); // 🔥 Limit reduced to 15 for instant rendering
      }

      if (mounted) {
        setState(() {
          _followerCount = (results[0] as PostgrestResponse).count;
          _isFollowing = isFollowingStatus;
          _totalMomentsCount = (results[2] as PostgrestResponse).count;
          _followingCount = (results[3] as PostgrestResponse).count;
          _hasActiveStories = (results[4] as List<dynamic>).isNotEmpty;
          _isSubscribedToAlerts = results[5] != null;
          _moments = fetchedMoments;
        });
      }
    } catch (e) {
      debugPrint("Heavy Profile data load error: $e");
    }
  }

  // --- NEW: TOGGLE POST ALERTS ---
  Future<void> _togglePostAlerts() async {
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) return;

    final wasSubscribed = _isSubscribedToAlerts;
    setState(() => _isSubscribedToAlerts = !wasSubscribed);

    try {
      if (!wasSubscribed) {
        await supabase.from('post_alerts').insert({
          'subscriber_id': currentUserId,
          'target_user_id': widget.targetUserId,
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    'You will now be notified when @${_profile?['username']} posts!'),
                backgroundColor: const Color(0xFF4CAF50)),
          );
        }
      } else {
        await supabase.from('post_alerts').delete().match({
          'subscriber_id': currentUserId,
          'target_user_id': widget.targetUserId,
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(
                    'Post notifications turned off for @${_profile?['username']}.')),
          );
        }
      }
    } catch (e) {
      setState(
          () => _isSubscribedToAlerts = wasSubscribed); // Rollback on error
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to update notifications')));
    }
  }

  // --- NEW: SHOW PROFILE MENU ---
  void _showProfileMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Color(0xFF121212),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(
                _isSubscribedToAlerts
                    ? Icons.notifications_active
                    : Icons.notifications_none,
                color: Colors.white),
            title: Text(
                _isSubscribedToAlerts
                    ? 'Turn Off Post Notifications'
                    : 'Turn On Post Notifications',
                style: const TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(ctx);
              _togglePostAlerts();
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  void _showUserList(String title, bool showFollowers) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Color(0xFF121212),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return Column(
          children: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2)),
            ),
            Text(title,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const Divider(color: Colors.white10),
            Expanded(
              child: FutureBuilder<List<dynamic>>(
                // We fetch from the 'followers' table and join the 'profiles' table
                // based on which list we are viewing.
                future: supabase.from('followers').select('''
                    *,
                    profiles!${showFollowers ? 'follower_id' : 'following_id'} (
                      id, 
                      username, 
                      avatar_url, 
                      school_name
                    )
                  ''').eq(showFollowers ? 'following_id' : 'follower_id', widget.targetUserId),
                builder: (context, snapshot) {
                  // 1. Handle Loading State
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFF4CAF50)));
                  }

                  // 2. Handle Error State (This was missing and causing the infinite load)
                  if (snapshot.hasError) {
                    debugPrint("User List Error: ${snapshot.error}");
                    return Center(
                      child: Text("Error loading list: ${snapshot.error}",
                          style: const TextStyle(color: Colors.redAccent),
                          textAlign: TextAlign.center),
                    );
                  }

                  // 3. Handle Empty State
                  final data = snapshot.data ?? [];
                  if (data.isEmpty) {
                    return const Center(
                        child: Text("No users found",
                            style: TextStyle(color: Colors.white54)));
                  }

                  return ListView.builder(
                    itemCount: data.length,
                    itemBuilder: (context, index) {
                      // Access the joined profile data
                      final profile = data[index]['profiles'];

                      if (profile == null) return const SizedBox.shrink();

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Color(0xFF1E1E1E),
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
                          Navigator.pop(context); // Close current sheet
                          UniversalProfileCard.show(context, profile['id'],
                              widget.userPreferences); // Open new profile
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _toggleFollow() async {
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) return;

    final wasFollowing = _isFollowing;
    setState(() {
      _isFollowing = !_isFollowing;
      _followerCount += _isFollowing ? 1 : -1;
    });
    try {
      if (!wasFollowing) {
        await supabase.from('followers').insert({
          'follower_id': currentUserId,
          'following_id': widget.targetUserId,
        });
      } else {
        await supabase.from('followers').delete().match({
          'follower_id': currentUserId,
          'following_id': widget.targetUserId,
        });
      }
    } catch (e) {
      setState(() {
        _isFollowing = wasFollowing;
        _followerCount += _isFollowing ? 1 : -1;
      });
    }
  }

  Widget _buildActionButtons() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _buildCircleButton(
          icon: _isFollowing ? Icons.check : Icons.person_add_alt_1,
          label: _isFollowing ? 'Following' : 'Follow',
          bgColor: _isFollowing ? const Color(0xFF1E1E1E) : themeColor,
          iconColor: Colors.white,
          onTap: _toggleFollow,
        ),
        _buildCircleButton(
            icon: Icons.ios_share,
            label: 'Share',
            bgColor: const Color(0xFF1E1E1E),
            iconColor: Colors.white,
            onTap: () => Share.share(
                'Check out @${_profile!['username']} on Allowance!')),
        _buildCircleButton(
            icon: Icons.chat_bubble_outline,
            label: 'Message',
            bgColor: Colors.white,
            iconColor: const Color(0xFF121212),
            onTap: () async {
              final currentUserId = supabase.auth.currentUser?.id;
              if (currentUserId == null) return;
              try {
                final response = await supabase
                    .rpc('get_or_create_personal_chat', params: {
                  'user_a': currentUserId,
                  'user_b': widget.targetUserId
                });
                if (response != null && mounted) {
                  Navigator.pop(context);
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => IndividualChatScreen(
                              chatId: response.toString(),
                              recipientProfile: _profile!,
                              userPreferences: widget.userPreferences)));
                }
              } catch (e) {
                debugPrint("Navigation Error: $e");
              }
            }),
      ],
    );
  }

  Widget _buildCircleButton(
      {required IconData icon,
      required String label,
      required Color bgColor,
      required Color iconColor,
      required VoidCallback onTap}) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: bgColor, shape: BoxShape.circle),
              child: Icon(icon, color: iconColor, size: 24),
            ),
            const SizedBox(height: 8),
            Text(label,
                style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return _buildShell(const Center(
          child: CircularProgressIndicator(color: Color(0xFF4CAF50))));
    }
    if (_profile == null) {
      return _buildShell(const Center(
          child:
              Text("User not found", style: TextStyle(color: Colors.white))));
    }

    final isPrivate = _profile!['is_private'] == true;
    final isMe = supabase.auth.currentUser?.id == widget.targetUserId;
    final canSeeContent = !isPrivate || _isFollowing || isMe;

    // Cast the moments safely for the SliverGrid
    final typedMoments = List<Map<String, dynamic>>.from(_moments);

    return _buildShell(
      NotificationListener<ScrollNotification>(
        onNotification: (ScrollNotification scrollInfo) {
          if (scrollInfo.metrics.pixels >=
              scrollInfo.metrics.maxScrollExtent - 200) {
            _loadMoreMoments();
          }
          return false;
        },
        // 🔥 CHANGED TO CUSTOM SCROLL VIEW: This completely fixes the memory crash
        // by lazily rendering only the grid items visible on the screen!
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              sliver: SliverList(
                delegate: SliverChildListDelegate([
                  Row(
                    children: [
                      _buildAvatar(),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _buildStatColumn(
                                'Followers',
                                _followerCount.toString(),
                                () => _showUserList('Followers', true)),
                            _buildStatColumn(
                                'Following',
                                _followingCount.toString(),
                                () => _showUserList('Following', false)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _buildProfileInfo(isPrivate),
                  const SizedBox(height: 24),
                  if (!isMe) _buildActionButtons(),
                  const SizedBox(height: 24),
                  const Divider(color: Colors.white10),
                  const SizedBox(height: 12),
                  Text('Moments ($_totalMomentsCount)',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                ]),
              ),
            ),

            // --- THE SLIVER GRID ---
            if (canSeeContent) ...[
              if (typedMoments.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(top: 20, bottom: 40),
                    child: Center(
                      child: Text("No moments yet",
                          style: TextStyle(color: Colors.white38)),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 2,
                      mainAxisSpacing: 2,
                      childAspectRatio: 0.56, // 🔥 TALL RECTANGLES ARE BACK
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        return UniversalMomentGridItem(
                          moments: typedMoments,
                          index: index,
                          userPreferences: widget.userPreferences,
                        );
                      },
                      childCount: typedMoments.length,
                    ),
                  ),
                ),
              if (_isLoadingMoreMoments)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFF4CAF50))),
                  ),
                ),
            ] else
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 40),
                  child: Column(
                    children: const [
                      Icon(Icons.lock_outline, color: Colors.white24, size: 50),
                      SizedBox(height: 12),
                      Text("This account is private",
                          style: TextStyle(color: Colors.white70)),
                      Text("Follow to see their moments",
                          style:
                              TextStyle(color: Colors.white38, fontSize: 12)),
                    ],
                  ),
                ),
              ),

            const SliverToBoxAdapter(
                child: SizedBox(height: 40)), // Bottom spacing
          ],
        ),
      ),
    );
  }

  Widget _buildShell(Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: Color(0xFF121212),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 16),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: Colors.white24, borderRadius: BorderRadius.circular(2)),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _buildAvatar() {
    final bool showRing = _hasActiveStories == true;

    return GestureDetector(
      onTap: () => _handleAvatarTap(showRing),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: showRing ? themeColor : Colors.transparent,
            width: 2,
          ),
        ),
        child: CircleAvatar(
          radius: 40,
          backgroundColor: Color(0xFF1E1E1E),
          backgroundImage: _profile!['avatar_url'] != null
              ? CachedNetworkImageProvider(_profile!['avatar_url'])
              : null,
          child: _profile!['avatar_url'] == null
              ? const Icon(Icons.person, size: 40, color: Colors.white54)
              : null,
        ),
      ),
    );
  }

  Future<void> _handleAvatarTap(bool hasStories) async {
    if (!hasStories) return;

    try {
      final List<dynamic> activeStories = await supabase
          .from('stories')
          .select('''
            *,
            profiles:user_id(username, avatar_url, school_name)
          ''') // Join the profiles table to supply username and school metadata to StoryViewerScreen
          .eq('user_id', widget.targetUserId)
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .order('created_at', ascending: true);

      if (activeStories.isNotEmpty && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => StoryViewerScreen(
              stories: List<Map<String, dynamic>>.from(activeStories),
              initialIndex: 0,
              userPreferences: widget.userPreferences,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint("Error launching stories: $e");
    }
  }

  Widget _buildProfileInfo(bool isPrivate) {
    final bool isPlusMember =
        SubscriptionService.isPlus(_profile!['subscription_tier']);
    final isMe = supabase.auth.currentUser?.id == widget.targetUserId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text('@${_profile!['username']}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),

                  // STAR BADGE FOR PLUS USERS
                  if (isPlusMember) ...[
                    const SizedBox(width: 6),
                    SubscriptionService.getPlusBadge(),
                  ],

                  if (isPrivate) ...[
                    const SizedBox(width: 6),
                    const Icon(Icons.lock, color: Colors.white54, size: 16)
                  ],
                ],
              ),
            ),

            // --- NEW: 3-DOT MENU FOR NOTIFICATION ALERTS ---
            if (!isMe)
              IconButton(
                icon: const Icon(Icons.more_horiz, color: Colors.white),
                onPressed: _showProfileMenu,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
          ],
        ),
        if (_profile!['school_name'] != null)
          Padding(
            padding: const EdgeInsets.only(top: 4.0),
            child: Text(_profile!['school_name'],
                style: const TextStyle(color: Colors.white54, fontSize: 14)),
          ),
        if (_profile!['bio'] != null && _profile!['bio'].toString().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_profile!['bio'],
                style: const TextStyle(color: Colors.white, fontSize: 15)),
          ),
      ],
    );
  }

  Widget _buildStatColumn(String label, String count, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        children: [
          Text(count,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          Text(label,
              style: const TextStyle(color: Colors.white54, fontSize: 14)),
        ],
      ),
    );
  }
}

// --- LIGHTWEIGHT GRID ITEM WITH STAGGERED VIDEO THUMBNAILS & HARDWARE LEAK PROTECTION ---
class UniversalMomentGridItem extends StatefulWidget {
  final List<Map<String, dynamic>> moments;
  final int index;
  final UserPreferences userPreferences;

  const UniversalMomentGridItem({
    super.key,
    required this.moments,
    required this.index,
    required this.userPreferences,
  });

  @override
  State<UniversalMomentGridItem> createState() =>
      _UniversalMomentGridItemState();
}

class _UniversalMomentGridItemState extends State<UniversalMomentGridItem> {
  VideoPlayerController? _videoController;
  bool _isVideo = false;
  late Map<String, dynamic> moment;
  bool _countedActive = false;
  bool _isDisposed = false; // 🔥 Strict lifecycle management flag

  static int _activeMomentVideoInits = 0;
  static const int _maxConcurrentMomentVideos =
      2; // Keep it low to protect hardware

  @override
  void initState() {
    super.initState();
    moment = widget.moments[widget.index];
    _isVideo = moment['media_type'] == 'video';

    if (_isVideo) {
      final url = moment['media_url'] ?? '';
      if (url.isNotEmpty) {
        _videoController = VideoPlayerController.networkUrl(Uri.parse(url));
        _tryInitVideo();
      }
    }
  }

  void _tryInitVideo() {
    // 🔥 Stop instantly if scrolled off screen
    if (_isDisposed || !mounted || _videoController == null) return;

    if (_activeMomentVideoInits >= _maxConcurrentMomentVideos) {
      Future.delayed(const Duration(milliseconds: 200), () {
        if (mounted && !_isDisposed) _tryInitVideo();
      });
      return;
    }

    _countedActive = true;
    _activeMomentVideoInits++;

    _videoController!
        .initialize()
        .then((_) {
          if (mounted && !_isDisposed) setState(() {});
        })
        .catchError((_) {})
        .whenComplete(() {
          if (_countedActive) {
            _countedActive = false;
            _activeMomentVideoInits--;
          }
        });
  }

  @override
  void dispose() {
    _isDisposed = true; // 🔥 Instantly lock out any pending delays
    if (_countedActive) {
      _countedActive = false;
      _activeMomentVideoInits--;
    }
    // 🔥 Safely destroy the native decoder to free RAM & hardware slots
    _videoController?.dispose();
    _videoController = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => MomentViewerScreen(
              moments: widget.moments,
              initialIndex: widget.index,
              userPreferences: widget.userPreferences,
            ),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. VIDEO THUMBNAIL (First frame)
            if (_isVideo)
              _videoController != null && _videoController!.value.isInitialized
                  ? FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: _videoController!.value.size.width,
                        height: _videoController!.value.size.height,
                        child: IgnorePointer(
                          child: VideoPlayer(_videoController!),
                        ),
                      ),
                    )
                  : Container(color: const Color(0xFF1E1E1E))

            // 2. IMAGE
            else
              CachedNetworkImage(
                imageUrl: moment['media_url'] ?? '',
                fit: BoxFit.cover,
                memCacheWidth: 250, // 🔥 Heavy RAM compression for images
                placeholder: (context, url) =>
                    Container(color: const Color(0xFF1E1E1E)),
                errorWidget: (context, url, error) => Container(
                  color: const Color(0xFF1E1E1E),
                  child: const Icon(Icons.broken_image, color: Colors.white10),
                ),
              ),

            // 3. VIDEO PLAY ICON
            if (_isVideo)
              Container(
                color: Colors.black.withOpacity(0.15),
                child: const Center(
                  child: Icon(Icons.play_circle_fill,
                      color: Colors.white, size: 36),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
