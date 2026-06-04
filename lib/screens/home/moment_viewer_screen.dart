// lib/screens/home/moment_viewer_screen.dart
import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/user_preferences.dart';
import '../../widgets/universal_profile_card.dart';

class MomentViewerScreen extends StatefulWidget {
  final List<dynamic> moments;
  final int initialIndex;
  final UserPreferences userPreferences;

  const MomentViewerScreen({
    super.key,
    required this.moments,
    required this.initialIndex,
    required this.userPreferences,
  });

  @override
  State<MomentViewerScreen> createState() => _MomentViewerScreenState();
}

class _MomentViewerScreenState extends State<MomentViewerScreen> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        // --- THE MAGIC PRELOADER! This builds the next video in the background ---
        allowImplicitScrolling: true,
        onPageChanged: (index) {
          setState(() => _currentIndex = index);
        },
        itemCount: widget.moments.length,
        itemBuilder: (context, index) {
          return MomentViewerItem(
            moment: widget.moments[index],
            userPreferences: widget.userPreferences,
            isCurrentPage:
                index == _currentIndex, // Tells the item if it's on screen
          );
        },
      ),
    );
  }
}

class MomentViewerItem extends StatefulWidget {
  final Map<String, dynamic> moment;
  final UserPreferences userPreferences;
  final bool isCurrentPage; // <-- NEW

  const MomentViewerItem({
    super.key,
    required this.moment,
    required this.userPreferences,
    required this.isCurrentPage,
  });

  @override
  State<MomentViewerItem> createState() => _MomentViewerItemState();
}

class _MomentViewerItemState extends State<MomentViewerItem> {
  VideoPlayerController? _videoController;
  final supabase = Supabase.instance.client;

  bool _isLiked = false;
  int _likesCount = 0;
  int _commentsCount = 0;
  bool _isMuted = false;
  bool _authorIsPlus = false; // NEW: Track if the moment creator is Plus
  bool _isHighQuality = false;

  @override
  void initState() {
    super.initState();
    _likesCount = widget.moment['likes_count'] ?? 0;
    _commentsCount = widget.moment['comments_count'] ?? 0;

    _fetchLikeAndCommentData();
    _checkIfAuthorIsPlus();

    // 🔥 FIX: Only initialize the video if it is ACTUALLY on screen!
    if (widget.moment['media_type'] == 'video' && widget.isCurrentPage) {
      _initializeAndPreloadVideo(widget.moment['media_url']);
    }
  }

  // 🔥 THE FIX: Separated the Star checking logic so it doesn't break your Like/Comment logic!
  Future<void> _checkIfAuthorIsPlus() async {
    final authorId = widget.moment['user_id'];
    if (authorId == null) return;
    try {
      final res = await supabase
          .from('profiles')
          .select('subscription_tier')
          .eq('id', authorId)
          .maybeSingle();
      if (res != null && mounted) {
        setState(
            () => _authorIsPlus = res['subscription_tier'] == 'Membership');
      }
    } catch (_) {}
  }

  // --- NEW: PRELOAD & CACHE LOGIC ---
  Future<void> _initializeAndPreloadVideo(String url) async {
    try {
      if (kIsWeb) {
        _videoController = VideoPlayerController.networkUrl(Uri.parse(url));
      } else {
        final fileInfo = await DefaultCacheManager().getFileFromCache(url);
        if (fileInfo != null) {
          _videoController = VideoPlayerController.file(fileInfo.file);
        } else {
          _videoController = VideoPlayerController.networkUrl(Uri.parse(url));
          DefaultCacheManager().downloadFile(url);
        }
      }

      await _videoController!.initialize();
      _videoController!.setLooping(true);

      if (mounted && widget.isCurrentPage) {
        setState(() {});
        _videoController!.play();
      }
    } catch (e) {
      debugPrint("Video init error: $e");
    }
  }

  // 🔥 THE FIX: ULTIMATE GARBAGE COLLECTION
  @override
  void didUpdateWidget(MomentViewerItem oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isCurrentPage && !oldWidget.isCurrentPage) {
      // Swiped INTO view
      if (widget.moment['media_type'] == 'video') {
        if (_videoController == null) {
          _initializeAndPreloadVideo(widget.moment['media_url']);
        } else {
          _videoController!.play();
        }
      }
    } else if (!widget.isCurrentPage && oldWidget.isCurrentPage) {
      // Swiped OUT of view -> DESTROY THE VIDEO TO FREE UP RAM!
      _videoController?.pause();
      _videoController?.dispose();
      _videoController = null;
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _fetchLikeAndCommentData() async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;
    final momentId = widget.moment['id'];

    try {
      final likeRes = await supabase
          .from('moment_likes')
          .select('moment_id')
          .eq('moment_id', momentId)
          .eq('user_id', myId)
          .maybeSingle();
      if (likeRes != null && mounted) setState(() => _isLiked = true);

      // Fetch accurate counts in case they updated since the feed loaded
      final countRes = await supabase
          .from('moments')
          .select('likes_count, comments_count')
          .eq('id', momentId)
          .single();
      if (mounted) {
        setState(() {
          _likesCount = countRes['likes_count'] ?? 0;
          _commentsCount = countRes['comments_count'] ?? 0;
        });
      }
    } catch (_) {}
  }

  Future<void> _toggleLike() async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;
    final momentId = widget.moment['id'];

    final wasLiked = _isLiked;
    setState(() {
      _isLiked = !wasLiked;
      _likesCount += _isLiked ? 1 : -1;
    });

    try {
      if (wasLiked) {
        await supabase
            .from('moment_likes')
            .delete()
            .eq('moment_id', momentId)
            .eq('user_id', myId);
      } else {
        await supabase
            .from('moment_likes')
            .insert({'moment_id': momentId, 'user_id': myId});
      }
    } catch (e) {
      setState(() {
        _isLiked = wasLiked;
        _likesCount += _isLiked ? 1 : -1;
      });
    }
  }

  Future<void> _deleteMoment() async {
    try {
      await supabase.from('moments').delete().eq('id', widget.moment['id']);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Moment deleted successfully'),
            backgroundColor: Colors.green));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Failed to delete: $e'),
            backgroundColor: Colors.red));
    }
  }

  void _showMomentOptions() {
    final isMe = supabase.auth.currentUser?.id == widget.moment['user_id'];

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 🔥 NEW: Request Full Quality Option
            if (widget.moment['media_type'] != 'video')
              ListTile(
                leading: const Icon(Icons.hd, color: Colors.blueAccent),
                title: const Text('View Full Quality',
                    style: TextStyle(color: Colors.blueAccent, fontSize: 16)),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _isHighQuality = true);
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Loading High Quality...')));
                },
              ),

            if (isMe)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('Delete Moment',
                    style: TextStyle(color: Colors.redAccent, fontSize: 16)),
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteMoment();
                },
              ),
          ],
        ),
      ),
    );
  }

  // --- SHARE FUNCTIONALITY ---
  Future<List<dynamic>> _fetchFriends(String myId) async {
    try {
      final res = await supabase
          .from('followers')
          .select('following_id')
          .eq('follower_id', myId);
      final followingIds = res.map((e) => e['following_id']).toList();
      if (followingIds.isEmpty) return [];
      return await supabase
          .from('profiles')
          .select('id, username, avatar_url')
          .inFilter('id', followingIds);
    } catch (e) {
      return [];
    }
  }

  Future<void> _sendMomentToFriends(
      Set<String> friendIds, String caption, String momentLink) async {
    final myId = supabase.auth.currentUser!.id;
    final mediaUrl = widget.moment['media_url'] ?? '';
    final mediaType = widget.moment['media_type'] ?? 'image';
    final creatorId = widget.moment['user_id'];

    for (String friendId in friendIds) {
      final response = await supabase.rpc('get_or_create_personal_chat',
          params: {'user_a': myId, 'user_b': friendId});
      await supabase.from('messages').insert({
        'chat_id': response.toString(),
        'sender_id': myId,
        'content': 'Check out this Moment on Allowance!\n$caption\n$momentLink',
        'media_url': mediaUrl,
        'media_type': mediaType,
        'is_read': false,
      });
    }

    // --- NEW: NOTIFY THE MOMENT CREATOR THAT IT WAS SHARED ---
    if (creatorId != null && creatorId != myId) {
      try {
        await supabase.rpc('notify_share', params: {
          'target_user_id': creatorId,
          'item_type': 'moment',
          'item_id': widget.moment['id'],
          'friend_count': friendIds.length
        });
      } catch (e) {
        debugPrint('Share notification failed: $e');
      }
    }
  }

  void _showShipSheet() {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;

    final String caption = widget.moment['caption'] ?? 'A memory shared';
    final String momentLink =
        'https://www.allowanceapp.org/share?type=moment&id=${widget.moment['id']}';
    final friendsFuture = _fetchFriends(myId);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        Set<String> selectedFriends = {};
        bool isSending = false;

        return StatefulBuilder(
          builder: (context, setModalState) => DraggableScrollableSheet(
            initialChildSize: 0.6,
            minChildSize: 0.4,
            maxChildSize: 0.9,
            expand: false,
            builder: (_, scrollController) => Column(
              children: [
                const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text('Share Moment',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold))),
                ListTile(
                  leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: Colors.grey[800], shape: BoxShape.circle),
                      child: const Icon(Icons.share, color: Colors.white)),
                  title: const Text('Share to other apps',
                      style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    Share.share(
                        'Check out this Moment on Allowance!\n$caption\n$momentLink');
                  },
                ),
                const Divider(color: Colors.white10),
                Expanded(
                  child: FutureBuilder<List<dynamic>>(
                      future: friendsFuture,
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting)
                          return const Center(
                              child: CircularProgressIndicator(
                                  color: Color(0xFF4CAF50)));
                        final friends = snapshot.data ?? [];
                        if (friends.isEmpty)
                          return const Center(
                              child: Text("Follow people to see them here",
                                  style: TextStyle(color: Colors.white54)));

                        return ListView.builder(
                          controller: scrollController,
                          itemCount: friends.length,
                          itemBuilder: (context, index) {
                            final friend = friends[index];
                            final friendId = friend['id'];
                            final isSelected =
                                selectedFriends.contains(friendId);
                            return ListTile(
                              leading: CircleAvatar(
                                backgroundColor: Colors.grey[800],
                                backgroundImage: friend['avatar_url'] != null
                                    ? CachedNetworkImageProvider(
                                        friend['avatar_url'])
                                    : null,
                                child: friend['avatar_url'] == null
                                    ? const Icon(Icons.person,
                                        color: Colors.white54)
                                    : null,
                              ),
                              title: Text(friend['username'] ?? 'User',
                                  style: const TextStyle(color: Colors.white)),
                              trailing: Checkbox(
                                  value: isSelected,
                                  activeColor: const Color(0xFF4CAF50),
                                  checkColor: Colors.black,
                                  onChanged: (v) => setModalState(() =>
                                      v == true
                                          ? selectedFriends.add(friendId)
                                          : selectedFriends.remove(friendId))),
                              onTap: () => setModalState(() => isSelected
                                  ? selectedFriends.remove(friendId)
                                  : selectedFriends.add(friendId)),
                            );
                          },
                        );
                      }),
                ),
                if (selectedFriends.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4CAF50),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12))),
                        onPressed: isSending
                            ? null
                            : () async {
                                setModalState(() => isSending = true);
                                await _sendMomentToFriends(
                                    selectedFriends, caption, momentLink);
                                if (mounted) {
                                  Navigator.pop(ctx);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(
                                              'Sent to ${selectedFriends.length} friend(s)!'),
                                          backgroundColor: Colors.green));
                                }
                              },
                        child: isSending
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                    color: Colors.black, strokeWidth: 2))
                            : Text('Send to ${selectedFriends.length}',
                                style: const TextStyle(
                                    color: Colors.black,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16)),
                      ),
                    ),
                  )
              ],
            ),
          ),
        );
      },
    );
  }

  void _showCommentsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => MomentCommentsSheet(
          momentId: widget.moment['id'].toString(),
          themeColor: const Color(0xFF4CAF50)),
    ).then(
        (_) => _fetchLikeAndCommentData()); // Refresh counts when sheet closes
  }

  // 2. REPLACE THIS METHOD
  @override
  Widget build(BuildContext context) {
    final isVideo = widget.moment['media_type'] == 'video';
    final profile = widget.moment['profiles'] ?? {};
    final username = profile['username'] ?? 'User';
    final avatarUrl = profile['avatar_url'];
    final schoolName = profile['school_name'];
    final caption = widget.moment['caption'] ?? '';
    final isPlus =
        _authorIsPlus || profile['subscription_tier'] == 'Membership';

    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: isVideo
              ? (_videoController != null &&
                      _videoController!.value.isInitialized
                  ? GestureDetector(
                      onTap: () {
                        _videoController!.value.isPlaying
                            ? _videoController!.pause()
                            : _videoController!.play();
                        setState(() {});
                      },
                      child: Stack(alignment: Alignment.center, children: [
                        AspectRatio(
                            aspectRatio: _videoController!.value.aspectRatio,
                            child: VideoPlayer(_videoController!)),
                        if (!_videoController!.value.isPlaying)
                          Container(
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.6),
                                  shape: BoxShape.circle),
                              child: const Icon(Icons.play_arrow_rounded,
                                  color: Colors.white, size: 54)),
                      ]),
                    )
                  : const CircularProgressIndicator(color: Color(0xFF4CAF50)))
              : CachedNetworkImage(
                  imageUrl: widget.moment['media_url'],
                  fit: BoxFit.contain,
                  // 🔥 FIX: Reduces RAM usage from ~30MB per image to ~2MB! Prevents OOM crashes.
                  memCacheWidth: _isHighQuality ? null : 600,
                  placeholder: (context, url) =>
                      const CircularProgressIndicator(color: Color(0xFF4CAF50)),
                ),
        ),

        // ... Keep the rest of your original Stack UI (AppBar, Caption, Interaction Buttons) exactly the same ...
        // (Just ensure the "isMe" check in _showMomentOptions button is handled properly since it moved into the bottom sheet)
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: SizedBox(
              height: 90,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Image.asset('assets/images/moments.png',
                      height: 90, fit: BoxFit.contain),
                  Positioned(
                      left: 8,
                      child: IconButton(
                          icon: const Icon(Icons.arrow_back_ios,
                              color: Colors.white),
                          onPressed: () => Navigator.pop(context))),
                  Positioned(
                    right: 8,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isVideo)
                          IconButton(
                            icon: Icon(
                                _isMuted ? Icons.volume_off : Icons.volume_up,
                                color: Colors.white),
                            onPressed: () {
                              setState(() {
                                _isMuted = !_isMuted;
                                _videoController
                                    ?.setVolume(_isMuted ? 0.0 : 1.0);
                              });
                            },
                          ),
                        // Changed to always show options (so users can select HD)
                        IconButton(
                          icon:
                              const Icon(Icons.more_vert, color: Colors.white),
                          onPressed: _showMomentOptions,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // 3. CAPTION AREA
        Positioned(
          bottom: 20,
          left: 16,
          right: 80,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => UniversalProfileCard.show(
                    context, widget.moment['user_id'], widget.userPreferences),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text('@$username',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                shadows: [
                                  Shadow(color: Colors.black87, blurRadius: 4)
                                ])),
                        if (isPlus) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.star,
                              color: Colors.amber,
                              size: 16,
                              shadows: [
                                Shadow(color: Colors.black87, blurRadius: 4)
                              ]),
                        ],
                      ],
                    ),
                    if (schoolName != null && schoolName.toString().isNotEmpty)
                      Text(schoolName,
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              shadows: [
                                Shadow(color: Colors.black87, blurRadius: 4)
                              ])),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (caption.isNotEmpty)
                Text(caption,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        shadows: [
                          Shadow(color: Colors.black87, blurRadius: 4)
                        ])),
            ],
          ),
        ),

        // 4. RIGHT SIDE INTERACTION BUTTONS
        Positioned(
          bottom: 20,
          right: 8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => UniversalProfileCard.show(
                    context, widget.moment['user_id'], widget.userPreferences),
                child: SizedBox(
                  height: 60,
                  width: 50,
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: Colors.grey[800],
                        backgroundImage: avatarUrl != null
                            ? CachedNetworkImageProvider(avatarUrl)
                            : null,
                        child: avatarUrl == null
                            ? const Icon(Icons.person, color: Colors.white)
                            : null,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              GestureDetector(
                onTap: _toggleLike,
                child: Column(
                  children: [
                    Icon(_isLiked ? Icons.favorite : Icons.favorite_border,
                        color: _isLiked ? Colors.red : Colors.white,
                        size: 36,
                        shadows: const [
                          Shadow(color: Colors.black54, blurRadius: 8)
                        ]),
                    const SizedBox(height: 4),
                    Text('$_likesCount',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 4)
                            ])),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              GestureDetector(
                onTap: _showCommentsSheet,
                child: Column(
                  children: [
                    const Icon(CupertinoIcons.chat_bubble,
                        color: Colors.white,
                        size: 34,
                        shadows: [
                          Shadow(color: Colors.black54, blurRadius: 8)
                        ]),
                    const SizedBox(height: 4),
                    Text('$_commentsCount',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 4)
                            ])),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              GestureDetector(
                onTap: _showShipSheet,
                child: Column(
                  children: const [
                    Text('🚀',
                        style: TextStyle(fontSize: 30, shadows: [
                          Shadow(color: Colors.black54, blurRadius: 8)
                        ])),
                    SizedBox(height: 4),
                    Text('Share',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 4)
                            ])),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// --- MOMENT COMMENTS SHEET ---
class MomentCommentsSheet extends StatefulWidget {
  final String momentId;
  final Color themeColor;

  const MomentCommentsSheet(
      {super.key, required this.momentId, required this.themeColor});

  @override
  State<MomentCommentsSheet> createState() => _MomentCommentsSheetState();
}

class _MomentCommentsSheetState extends State<MomentCommentsSheet> {
  final _commentController = TextEditingController();
  final supabase = Supabase.instance.client;
  bool _isPosting = false;
  late final Stream<List<Map<String, dynamic>>> _commentsStream;

  @override
  void initState() {
    super.initState();
    _commentsStream = supabase
        .from('moment_comments')
        .stream(primaryKey: ['id'])
        .eq('moment_id', int.parse(widget.momentId))
        .order('created_at', ascending: true);
  }

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _postComment() async {
    final text = _commentController.text.trim();
    final user = supabase.auth.currentUser;
    if (text.isEmpty || user == null) return;

    setState(() => _isPosting = true);
    try {
      await supabase.from('moment_comments').insert({
        'moment_id': int.parse(widget.momentId),
        'user_id': user.id,
        'content': text
      });
      _commentController.clear();
      FocusScope.of(context).unfocus();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to post comment')));
    } finally {
      if (mounted) setState(() => _isPosting = false);
    }
  }

  Future<void> _deleteComment(int commentId) async {
    try {
      await supabase.from('moment_comments').delete().eq('id', commentId);
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Failed to delete')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Container(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
          color: Color(0xFF111111),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      child: SafeArea(
        bottom: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.grey[700],
                    borderRadius: BorderRadius.circular(10))),
            const Padding(
                padding: EdgeInsets.symmetric(vertical: 15),
                child: Text('Comments',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold))),
            const Divider(color: Colors.white10, height: 1),
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _commentsStream,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting)
                    return Center(
                        child: CircularProgressIndicator(
                            color: widget.themeColor));
                  final comments = snapshot.data ?? [];
                  if (comments.isEmpty)
                    return const Center(
                        child: Text("No comments yet. Be the first!",
                            style: TextStyle(color: Colors.white54)));

                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: comments.length,
                    itemBuilder: (context, index) {
                      final comment = comments[index];
                      final userId = comment['user_id'] as String;
                      final isMyComment =
                          userId == supabase.auth.currentUser?.id;

                      return FutureBuilder<Map<String, dynamic>?>(
                        future: supabase
                            .from('profiles')
                            // 🔥 NEW: Added subscription_tier to the select query
                            .select('username, avatar_url, subscription_tier')
                            .eq('id', userId)
                            .maybeSingle(),
                        builder: (ctx, profileSnap) {
                          final profile = profileSnap.data;
                          // 🔥 NEW: Check if the commenter is a Plus member
                          final isCommenterPlus =
                              profile?['subscription_tier'] == 'Membership';

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Colors.grey[800],
                              backgroundImage: profile?['avatar_url'] != null
                                  ? CachedNetworkImageProvider(
                                      profile!['avatar_url'])
                                  : null,
                              child: profile?['avatar_url'] == null
                                  ? const Icon(Icons.person,
                                      color: Colors.white54, size: 20)
                                  : null,
                            ),
                            title: Row(
                              children: [
                                Text('@${profile?['username'] ?? 'User'}',
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold)),
                                if (isCommenterPlus) ...[
                                  const SizedBox(width: 4),
                                  const Icon(Icons.star,
                                      color: Colors.amber, size: 12),
                                ],
                              ],
                            ),
                            subtitle: Padding(
                                padding: const EdgeInsets.only(top: 4.0),
                                child: Text(comment['content'] ?? '',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 14))),
                            trailing: isMyComment
                                ? IconButton(
                                    icon: const Icon(Icons.delete,
                                        color: Colors.white54, size: 18),
                                    onPressed: () =>
                                        _deleteComment(comment['id']))
                                : null,
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: Colors.white10))),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _commentController,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                          hintText: 'Add a comment...',
                          hintStyle: const TextStyle(color: Colors.white54),
                          filled: true,
                          fillColor: Colors.grey[900],
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(30),
                              borderSide: BorderSide.none),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _commentController,
                    builder: (context, value, child) {
                      final hasText = value.text.trim().isNotEmpty;
                      return GestureDetector(
                        onTap: (hasText && !_isPosting) ? _postComment : null,
                        child: _isPosting
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    color: widget.themeColor, strokeWidth: 2))
                            : Text('Post',
                                style: TextStyle(
                                    color: hasText
                                        ? widget.themeColor
                                        : Colors.grey,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16)),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
