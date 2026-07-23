// lib/screens/home/story_viewer_screen.dart
import 'package:allowance/screens/chat/group_invite_screen.dart';
import 'package:allowance/widgets/universal_profile_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

import '../../models/user_preferences.dart';
import 'subscription_screen.dart';

class StoryViewerScreen extends StatefulWidget {
  final List<dynamic> stories;
  final int initialIndex;
  final UserPreferences userPreferences;
  final String? storyId;

  const StoryViewerScreen({
    super.key,
    required this.stories,
    required this.initialIndex,
    required this.userPreferences,
    this.storyId,
  });

  @override
  State<StoryViewerScreen> createState() => _StoryViewerScreenState();
}

class _StoryViewerScreenState extends State<StoryViewerScreen> {
  late PageController _pageController;
  int _currentIndex = 0;
  VideoPlayerController? _videoController;
  final Set<int> _likedStoryIds = {};

  // Progress
  late List<double> _progressValues;
  Timer? _progressTimer;
  bool _isPaused = false;
  VideoPlayerController? _preloadedController;
  int? _preloadedIndex;
  bool _isTransitioning = false;
  int _viewCount = 0;
  StreamSubscription<List<Map<String, dynamic>>>? _viewSubscription;
  RealtimeChannel? _realtimeStoryChannel;
  final TextEditingController _replyController = TextEditingController();
  bool _isSendingReply = false;

  late final List<dynamic> _sortedStories;

  // Theme color for paywall
  final Color themeColor = const Color(0xFF4CAF50);

  @override
  void initState() {
    super.initState();
    _sortedStories = widget.stories;

    // If a storyId is passed (from chat), find its index in the list
    if (widget.storyId != null) {
      final index = _sortedStories
          .indexWhere((s) => s['id'].toString() == widget.storyId);
      _currentIndex = index != -1 ? index : widget.initialIndex;
    } else {
      _currentIndex = widget.initialIndex;
    }

    _pageController = PageController(initialPage: _currentIndex);
    _progressValues = List.filled(_sortedStories.length, 0.0);
    _loadLikedStories();
    _playCurrentStory();
    _startProgressForCurrentStory();
    _initViewCountAndSubscription();
    _markStoryAsViewed(_currentIndex);
  }

  Future<void> _loadLikedStories() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final storyIds = _sortedStories.map((s) => s['id'] as int).toList();
    if (storyIds.isEmpty) return;

    final res = await Supabase.instance.client
        .from('story_likes')
        .select('story_id')
        .inFilter('story_id', storyIds)
        .eq('user_id', user.id);

    setState(() {
      _likedStoryIds.addAll(res.map((r) => r['story_id'] as int));
    });
  }

  Future<void> _playCurrentStory() async {
    _videoController?.removeListener(_videoProgressListener);
    _videoController?.dispose();
    _videoController = null;

    final story = _sortedStories[_currentIndex];
    final url = story['media_url'] ?? '';

    if (story['media_type'] == 'video' && url.isNotEmpty) {
      if (_preloadedIndex == _currentIndex && _preloadedController != null) {
        _videoController = _preloadedController;
        _preloadedController = null;
        _preloadedIndex = null;
      } else {
        // 🔥 FIX: Bypass DefaultCacheManager entirely for videos! It causes the 1-second freeze and infinite load bugs.
        _videoController = VideoPlayerController.networkUrl(Uri.parse(url));
        await _videoController!.initialize();
      }

      if (mounted && !_isPaused) {
        _videoController!.play();
      }
      _videoController!.addListener(_videoProgressListener);
    }

    _preloadNext();
    if (mounted) setState(() {});
  }

  void _preloadNext() async {
    _preloadedController?.dispose();
    _preloadedController = null;
    _preloadedIndex = null;

    if (_currentIndex + 1 >= _sortedStories.length) return;
    final nextStory = _sortedStories[_currentIndex + 1];
    final nextUrl = nextStory['media_url'] ?? '';

    if (nextStory['media_type'] == 'video') {
      _preloadedIndex = _currentIndex + 1;
      var fileInfo = await DefaultCacheManager().downloadFile(nextUrl);
      _preloadedController = VideoPlayerController.file(fileInfo.file);
      await _preloadedController!.initialize();
    } else {
      precacheImage(NetworkImage(nextUrl), context);
    }
  }

  void _startProgressForCurrentStory() {
    _progressTimer?.cancel();
    _progressValues[_currentIndex] = 0.0;

    final story = _sortedStories[_currentIndex];

    if (story['media_type'] == 'video') {
      _videoController?.addListener(_videoProgressListener);
    } else {
      // Image: 8 seconds
      const total = Duration(seconds: 8);
      final start = DateTime.now();

      _progressTimer =
          Timer.periodic(const Duration(milliseconds: 32), (timer) {
        if (!mounted || _isPaused) return;

        final elapsed = DateTime.now().difference(start).inMilliseconds;
        double progress = elapsed / total.inMilliseconds;

        if (progress >= 1.0) {
          timer.cancel();
          _goToNextStory();
          return;
        }
        setState(() => _progressValues[_currentIndex] = progress);
      });
    }
  }

  Future<void> _markStoryAsViewed(int index) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final story = _sortedStories[index];

    // Do NOT count the creator viewing their own story
    if (user.id == story['user_id']) return;

    try {
      await Supabase.instance.client.from('story_views').upsert({
        'story_id': story['id'],
        'user_id': user.id,
      });
    } catch (e) {
      debugPrint('View recording error: $e');
    }
  }

  (int, int) _getCurrentUserStoryRange() {
    final currentStory = _sortedStories[_currentIndex];
    final currentChatId = currentStory['chat_id'];
    final currentUserId = currentStory['user_id'];

    int start = _currentIndex;
    while (start > 0) {
      final prev = _sortedStories[start - 1];
      if (currentChatId != null) {
        if (prev['chat_id'] != currentChatId) break;
      } else {
        if (prev['chat_id'] != null || prev['user_id'] != currentUserId) break;
      }
      start--;
    }

    int end = _currentIndex;
    while (end < _sortedStories.length - 1) {
      final next = _sortedStories[end + 1];
      if (currentChatId != null) {
        if (next['chat_id'] != currentChatId) break;
      } else {
        if (next['chat_id'] != null || next['user_id'] != currentUserId) break;
      }
      end++;
    }

    return (start, end);
  }

  String _timeAgo(String createdAt) {
    final date = DateTime.parse(createdAt).toLocal();
    final difference = DateTime.now().difference(date);

    if (difference.inMinutes < 1) return 'just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  Future<void> _initViewCountAndSubscription() async {
    final story = _sortedStories[_currentIndex];
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;

    if (currentUserId == null || currentUserId != story['user_id']) return;

    final storyId = story['id'] as int;

    // 1. Fetch initial total views directly from DB (excluding creator)
    try {
      final response = await Supabase.instance.client
          .from('story_views')
          .select('id, user_id')
          .eq('story_id', storyId)
          .neq('user_id', currentUserId);
      if (mounted) {
        setState(() => _viewCount = (response as List).length);
      }
    } catch (e) {
      debugPrint('Error fetching views: $e');
    }

    // 2. Listen for realtime new views
    _viewSubscription?.cancel();
    _viewSubscription = Supabase.instance.client
        .from('story_views')
        .stream(primaryKey: ['id'])
        .eq('story_id', storyId)
        .listen((payload) {
          if (mounted) {
            final actualViews =
                payload.where((v) => v['user_id'] != currentUserId).toList();
            setState(() => _viewCount = actualViews.length);
          }
        });
  }

  Future<void> _showViewersList() async {
    _pauseStory();

    final storyId = _sortedStories[_currentIndex]['id'];
    final supabase = Supabase.instance.client;
    final currentUserId = supabase.auth.currentUser?.id;

    await showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return FutureBuilder(
          future: supabase
              .from('story_views')
              .select(
                  'user_id, viewed_at, profiles:user_id(username, avatar_url, school_name)')
              .eq('story_id', storyId)
              .neq('user_id', currentUserId ?? '')
              .order('viewed_at', ascending: false),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(
                height: 300,
                child: Center(
                    child: CircularProgressIndicator(color: Color(0xFF4CAF50))),
              );
            }

            final viewers = (snapshot.data as List<dynamic>?) ?? [];

            return Container(
              padding: const EdgeInsets.all(16),
              height: MediaQuery.of(context).size.height * 0.55,
              child: Column(
                children: [
                  Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2))),
                  const SizedBox(height: 16),
                  Text('${viewers.length} Viewers',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  Expanded(
                    child: viewers.isEmpty
                        ? const Center(
                            child: Text("No views yet",
                                style: TextStyle(color: Colors.white54)))
                        : ListView.builder(
                            itemCount: viewers.length,
                            itemBuilder: (context, index) {
                              final viewer = viewers[index];
                              final profile = viewer['profiles'] ?? {};
                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Colors.grey[800],
                                  backgroundImage: profile['avatar_url'] != null
                                      ? NetworkImage(profile['avatar_url'])
                                      : null,
                                  child: profile['avatar_url'] == null
                                      ? Text(
                                          (profile['username'] ?? 'U')
                                              .toString()[0]
                                              .toUpperCase(),
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold))
                                      : null,
                                ),
                                title: Text(profile['username'] ?? 'User',
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold)),
                                subtitle: Text(
                                    profile['school_name'] ?? 'Allowance',
                                    style: const TextStyle(
                                        color: Colors.white54, fontSize: 12)),
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );

    _resumeStory();
  }

  void _videoProgressListener() {
    if (!mounted || _videoController == null || _isPaused || _isTransitioning) {
      return;
    }

    final controller = _videoController!;

    if (controller.value.isInitialized) {
      final position = controller.value.position;
      final duration = controller.value.duration;

      final progress = position.inMilliseconds /
          duration.inMilliseconds.clamp(1, double.infinity);

      if (mounted) {
        setState(
            () => _progressValues[_currentIndex] = progress.clamp(0.0, 1.0));
      }

      if (duration.inMilliseconds > 0 && position >= duration) {
        _isTransitioning = true;
        controller.removeListener(_videoProgressListener);
        _goToNextStory();
      }
    }
  }

  void _goToNextStory() {
    if (_currentIndex < _sortedStories.length - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    } else {
      Navigator.pop(context);
    }
  }

  void _goToPreviousStory() {
    if (_currentIndex > 0) {
      _pageController.previousPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

  void _pauseStory() {
    setState(() => _isPaused = true);
    _videoController?.pause();
    _progressTimer?.cancel();
  }

  void _resumeStory() {
    setState(() => _isPaused = false);
    if (_videoController != null && _videoController!.value.isInitialized) {
      _videoController!.play();
    }
    _startProgressForCurrentStory();
  }

  Future<void> _toggleLike() async {
    final story = _sortedStories[_currentIndex];
    final storyId = story['id'] as int;
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return;

    final wasLiked = _likedStoryIds.contains(storyId);
    final currentCount = (story['likes_count'] ?? 0) as int;

    // Optimistic UI update
    setState(() {
      if (wasLiked) {
        _likedStoryIds.remove(storyId);
        story['likes_count'] = currentCount > 0 ? currentCount - 1 : 0;
      } else {
        _likedStoryIds.add(storyId);
        story['likes_count'] = currentCount + 1;
      }
    });

    try {
      if (wasLiked) {
        await supabase
            .from('story_likes')
            .delete()
            .eq('story_id', storyId)
            .eq('user_id', user.id);
      } else {
        await supabase
            .from('story_likes')
            .insert({'story_id': storyId, 'user_id': user.id});
      }
    } catch (e) {
      debugPrint('Like error: $e');
      setState(() {
        if (wasLiked) {
          _likedStoryIds.add(storyId);
        } else {
          _likedStoryIds.remove(storyId);
        }
        story['likes_count'] = currentCount;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not update like'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _reshareStory() async {
    final isPlus = widget.userPreferences.subscriptionTier == 'Membership';

    if (!isPlus) {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.grey[900],
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_rounded, size: 64, color: Colors.amber),
              const SizedBox(height: 16),
              const Text('Join Allowance Plus',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const SizedBox(height: 12),
              const Text(
                  'JOIN ALLOWANCE PLUS TO POST STORY GIST AND PASS THE FUN!',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.white70)),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => SubscriptionScreen(
                                userPreferences: widget.userPreferences,
                                themeColor: themeColor)));
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: themeColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: const Text('Subscribe to Allowance Plus',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Maybe later',
                    style: TextStyle(color: Colors.white70)),
              ),
            ],
          ),
        ),
      );
      return;
    }

    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final original = _sortedStories[_currentIndex];

    final shouldReshare = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Reshare this story?',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
            const SizedBox(height: 8),
            const Text('It will appear on your profile as a new story.',
                style: TextStyle(color: Colors.white70),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                    child: TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Cancel',
                            style: TextStyle(color: Colors.white70)))),
                Expanded(
                    child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white),
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Reshare',
                            style: TextStyle(color: Colors.black)))),
              ],
            ),
          ],
        ),
      ),
    );

    if (shouldReshare != true) return;

    try {
      String reshareUrl = original['url']?.toString() ?? '';

      // If it isn't already a shared link, we create the special 'reshare://' tag!
      if (!reshareUrl.startsWith('reshare://') &&
          !reshareUrl.contains('type=')) {
        final isGroup = original['chat_id'] != null;
        final origUser = isGroup
            ? (original['chats']?['group_name'] ?? 'Group')
            : (original['profiles']?['username'] ?? 'User');
        final origAvatar = isGroup
            ? (original['chats']?['group_avatar'] ?? '')
            : (original['profiles']?['avatar_url'] ?? '');
        final origSchool =
            isGroup ? 'Group' : (original['profiles']?['school_name'] ?? '');
        final origId = isGroup ? original['chat_id'] : original['user_id'];

        reshareUrl =
            'reshare://$origId|${Uri.encodeComponent(origUser)}|${Uri.encodeComponent(origAvatar)}|${Uri.encodeComponent(origSchool)}|$isGroup';
      }

      await Supabase.instance.client.from('stories').insert({
        'user_id': user.id,
        'media_url': original['media_url'],
        'media_type': original['media_type'],
        'caption': original['caption'],
        'url': reshareUrl,
      });

      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Story reshared successfully!'),
            backgroundColor: Colors.green));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Could not reshare story'),
            backgroundColor: Colors.red));
    }
  }

  Future<String> _getOrCreateDirectChat(
      String currentUserId, String otherUserId) async {
    try {
      final response = await Supabase.instance.client.rpc(
        'get_or_create_personal_chat',
        params: {
          'user_a': currentUserId,
          'user_b': otherUserId,
        },
      );
      return response.toString();
    } catch (e) {
      debugPrint("RPC Chat Error: $e");
      rethrow;
    }
  }

  Future<void> _sendStoryReply(Map<String, dynamic> story) async {
    final text = _replyController.text.trim();
    if (text.isEmpty || _isSendingReply) return;

    final currentUser = Supabase.instance.client.auth.currentUser;
    if (currentUser == null) return;

    final isGroupStory = story['chat_id'] != null;
    String? targetUserId;

    if (isGroupStory) {
      // 🔥 FIX: We fetch the admin IDs directly from the database here because
      // the initial story fetch might not have included them to save bandwidth!
      try {
        final chatData = await Supabase.instance.client
            .from('chats')
            .select('story_admin_id, admin_id')
            .eq('id', story['chat_id'])
            .maybeSingle();

        if (chatData != null) {
          targetUserId = chatData['story_admin_id'] ?? chatData['admin_id'];
        }
      } catch (e) {
        debugPrint('Error fetching group admins: $e');
      }
    } else {
      targetUserId = story['user_id'];
    }

    if (targetUserId == null || currentUser.id == targetUserId) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Cannot reply to this story.')));
      return;
    }

    setState(() => _isSendingReply = true);
    final originalText = text;
    _replyController.clear();
    FocusScope.of(context).unfocus();

    try {
      final String chatId =
          await _getOrCreateDirectChat(currentUser.id, targetUserId);

      final String? storyImage = story['media_type'] == 'video'
          ? story['thumbnail_url'] ?? story['media_url']
          : story['media_url'];

      final String caption = (story['caption'] ?? '').toString().trim();
      final String replyPayload = caption.isNotEmpty
          ? 'Story_${story['id']}_$caption'
          : 'Story_${story['id']}';

      await Supabase.instance.client.from('messages').insert({
        'chat_id': chatId,
        'sender_id': currentUser.id,
        'content': originalText,
        'reply_content': replyPayload,
        'thumbnail_url': storyImage,
      });

      if (mounted) {
        _resumeStory();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Sent ✓', style: TextStyle(color: Colors.white)),
              backgroundColor: Colors.black87,
              duration: Duration(seconds: 1)),
        );
      }
    } catch (e) {
      debugPrint('Story Reply Error: $e');
      if (mounted) _replyController.text = originalText;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Failed to send reply.'),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSendingReply = false);
    }
  }

  Future<void> _deleteStory() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final shouldDelete = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Delete this story?',
                style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white)),
            const SizedBox(height: 8),
            const Text('This action cannot be undone.',
                style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 24),
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel',
                        style: TextStyle(color: Colors.white70)),
                  ),
                ),
                Expanded(
                  child: ElevatedButton(
                    style:
                        ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Delete',
                        style: TextStyle(color: Colors.white)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (shouldDelete != true) return;

    try {
      await Supabase.instance.client
          .from('stories')
          .delete()
          .eq('id', _sortedStories[_currentIndex]['id']);

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Story deleted'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      debugPrint('Delete error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not delete story'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  void _setupRealtimeLikes() {
    final storyId = _sortedStories[_currentIndex]['id'];
    _realtimeStoryChannel?.unsubscribe();

    _realtimeStoryChannel = Supabase.instance.client
        .channel('public:stories:$storyId')
        .onPostgresChanges(
            event: PostgresChangeEvent.update,
            schema: 'public',
            table: 'stories',
            filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'id',
                value: storyId),
            callback: (payload) {
              if (mounted) {
                setState(() {
                  _sortedStories[_currentIndex]['likes_count'] =
                      payload.newRecord['likes_count'];
                });
              }
            })
        .subscribe();
  }

  @override
  void dispose() {
    _replyController.dispose();
    _progressTimer?.cancel();
    _videoController?.removeListener(_videoProgressListener);
    _videoController?.dispose();
    _viewSubscription?.cancel();
    _preloadedController?.dispose();
    _realtimeStoryChannel?.unsubscribe();
    _pageController.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _fetchSharedItemData(String urlStr) async {
    try {
      final parsedIdStr = Uri.tryParse(urlStr)?.queryParameters['id'];
      final intId = int.tryParse(parsedIdStr ?? '');
      if (intId == null) return null;

      final table = urlStr.contains('type=moment') ? 'moments' : 'gists';
      final res = await Supabase.instance.client
          .from(table)
          .select('user_id, profiles:user_id(username, school_name)')
          .eq('id', intId)
          .maybeSingle();
      return res;
    } catch (e) {
      debugPrint("Fetch Shared Gist Error: $e");
      return null;
    }
  }

  // 🔥 FIX: Cache to store the Future so it doesn't reload infinitely during the progress bar animation
  final Map<String, Future<Map<String, dynamic>?>> _sharedDataCache = {};

  Future<Map<String, dynamic>?> _getCachedSharedItemData(String urlStr) {
    if (!_sharedDataCache.containsKey(urlStr)) {
      _sharedDataCache[urlStr] = _fetchSharedItemData(urlStr);
    }
    return _sharedDataCache[urlStr]!;
  }

  @override
  Widget build(BuildContext context) {
    final story = _sortedStories[_currentIndex];
    final currentUser = Supabase.instance.client.auth.currentUser;
    final isOwnStory = currentUser?.id == story['user_id'];

    // 🔥 THE FIX: Now using our new robust contiguous range tracker
    final (userStart, userEnd) = _getCurrentUserStoryRange();
    final userStoryCount = userEnd - userStart + 1;
    final currentUserPosition = _currentIndex - userStart;

    final profile = story['profiles'] as Map<String, dynamic>? ?? {};
    final chatInfo = story['chats'] as Map<String, dynamic>? ?? {};
    final isGroupStory = story['chat_id'] != null;

    final bool isPlus = profile['subscription_tier'] == 'Membership';
    final bool isSharedGist =
        story['url'] != null && story['url'].toString().contains('type=');
    final bool isStoryReshare = story['url'] != null &&
        story['url'].toString().startsWith('reshare://');

    final String? displayAvatarUrl = isGroupStory
        ? chatInfo['group_avatar'] as String?
        : profile['avatar_url'] as String?;
    final String displayName = isGroupStory
        ? (chatInfo['group_name']?.toString() ?? 'Group')
        : '@${profile['username'] ?? 'user'}';
    final String? schoolName = profile['school_name']?.toString();

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. THE MAIN BACKGROUND MEDIA
          PageView.builder(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() => _currentIndex = index);
              _isTransitioning = false;
              _playCurrentStory();
              _startProgressForCurrentStory();
              _markStoryAsViewed(index);
              _initViewCountAndSubscription();
              _setupRealtimeLikes();
            },
            itemCount: _sortedStories.length,
            itemBuilder: (context, index) {
              final storyItem = _sortedStories[index];
              final isVideo = storyItem['media_type'] == 'video';
              final isText = storyItem['media_type'] == 'text';
              final caption = (storyItem['caption'] ?? '').toString().trim();

              return GestureDetector(
                onLongPressStart: (_) => _pauseStory(),
                onLongPressEnd: (_) => _resumeStory(),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (isText)
                      Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xFF1A1A1A), Color(0xFF111111)]),
                        ),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 40),
                            child: Text(storyItem['caption'] ?? '',
                                style: const TextStyle(
                                    fontSize: 32,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white,
                                    height: 1.35,
                                    letterSpacing: -0.5),
                                textAlign: TextAlign.center),
                          ),
                        ),
                      )
                    else if (isVideo)
                      (_currentIndex == index &&
                              _videoController != null &&
                              _videoController!.value.isInitialized
                          ? Center(
                              child: AspectRatio(
                                  aspectRatio:
                                      _videoController!.value.aspectRatio,
                                  child: VideoPlayer(_videoController!)))
                          : const Center(child: CircularProgressIndicator()))
                    else
                      Center(
                          child: Image.network(storyItem['media_url'],
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => const Icon(
                                  Icons.error,
                                  color: Colors.white,
                                  size: 60))),
                    if (!isText && caption.isNotEmpty)
                      Positioned(
                        bottom: 85,
                        left: 16,
                        right: 16,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              vertical: 8, horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.65),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            caption,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              height: 1.3,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),

          // 2. THE TOP PROGRESS BAR
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            left: 16,
            right: 16,
            child: Row(
              children: List.generate(
                userStoryCount,
                (i) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: i < currentUserPosition
                            ? 1.0
                            : i == currentUserPosition
                                ? _progressValues[_currentIndex]
                                : 0.0,
                        minHeight: 3.5,
                        backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation(Colors.white),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // 3. PAGE GESTURE DETECTORS (Left/Right Tap)
          Positioned.fill(
            child: Row(
              children: [
                Expanded(
                    child: GestureDetector(
                        onTap: _goToPreviousStory,
                        behavior: HitTestBehavior.translucent)),
                Expanded(
                    child: GestureDetector(
                        onTap: _goToNextStory,
                        behavior: HitTestBehavior.translucent)),
              ],
            ),
          ),

          // 4. VIDEO PLAYER CONTROLS
          if (story['media_type'] == 'video' &&
              _videoController != null &&
              _videoController!.value.isInitialized)
            Positioned(
              bottom: 105,
              left: 16,
              right: 16,
              child: Row(
                children: [
                  GestureDetector(
                      onTap: () => _isPaused ? _resumeStory() : _pauseStory(),
                      child: Icon(
                          _isPaused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded,
                          color: Colors.white,
                          size: 30)),
                  const SizedBox(width: 8),
                  Text(
                      "${_formatDuration(_videoController!.value.position)} / ${_formatDuration(_videoController!.value.duration)}",
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold)),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                          trackHeight: 2,
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6),
                          activeTrackColor: Colors.white,
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white),
                      child: Slider(
                        value: _videoController!.value.position.inMilliseconds
                            .toDouble(),
                        min: 0.0,
                        max: _videoController!.value.duration.inMilliseconds
                            .toDouble(),
                        onChangeStart: (_) => _pauseStory(),
                        onChanged: (value) {
                          _videoController!
                              .seekTo(Duration(milliseconds: value.toInt()));
                          setState(() {});
                        },
                        onChangeEnd: (_) => _resumeStory(),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // 5. EXTERNAL LINK BUTTON
          if (story['url'] != null &&
              story['url'].toString().trim().isNotEmpty &&
              !isSharedGist &&
              !isStoryReshare)
            Positioned(
              bottom: 140,
              right: 24,
              child: GestureDetector(
                onTap: () async {
                  final uri = Uri.parse(story['url'] as String);
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24)),
                  child: const Icon(Icons.link, color: Colors.white, size: 28),
                ),
              ),
            ),

          // 6. THE TOP HEADER BAR (AVATAR, USERNAME, CLOSE BUTTON)
          Positioned(
            top: MediaQuery.paddingOf(context).top + 25,
            left: 16,
            right: 16,
            child: Row(
              children: [
                GestureDetector(
                  onTap: () {
                    if (isGroupStory) {
                      _pauseStory();
                      Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => GroupInviteScreen(
                                      chatId: story['chat_id'].toString(),
                                      userPreferences: widget.userPreferences)))
                          .then((_) => _resumeStory());
                    } else {
                      UniversalProfileCard.show(
                          context, story['user_id'], widget.userPreferences);
                    }
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Row(
                    children: [
                      CircleAvatar(
                          backgroundImage: (displayAvatarUrl != null &&
                                  displayAvatarUrl.isNotEmpty)
                              ? NetworkImage(displayAvatarUrl)
                              : null),
                      const SizedBox(width: 8),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(displayName,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16)),
                              if (isPlus && !isGroupStory) ...[
                                const SizedBox(width: 4),
                                const Icon(Icons.star,
                                    color: Colors.amber, size: 14)
                              ]
                            ],
                          ),
                          Row(
                            children: [
                              if (!isGroupStory &&
                                  schoolName != null &&
                                  schoolName.isNotEmpty) ...[
                                Text(schoolName,
                                    style: TextStyle(
                                        color: Colors.white.withOpacity(0.8),
                                        fontSize: 12)),
                                const Text(' • ',
                                    style: TextStyle(
                                        color: Colors.white54, fontSize: 12)),
                              ],
                              Text(_timeAgo(story['created_at']),
                                  style: const TextStyle(
                                      color: Colors.white54, fontSize: 12)),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (isGroupStory && !isOwnStory) ...[
                  const SizedBox(width: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.white,
                        minimumSize: const Size(60, 26),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20))),
                    onPressed: () {
                      _pauseStory();
                      Navigator.push(
                              context,
                              MaterialPageRoute(
                                  builder: (_) => GroupInviteScreen(
                                      chatId: story['chat_id'].toString(),
                                      userPreferences: widget.userPreferences)))
                          .then((_) => _resumeStory());
                    },
                    child: Text(
                        chatInfo['is_premium'] == true
                            ? 'Gain Access'
                            : 'Join Group',
                        style: const TextStyle(
                            color: Colors.black,
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  )
                ],
                const Spacer(),
                if (isOwnStory)
                  IconButton(
                      icon: const Icon(Icons.delete,
                          color: Colors.redAccent, size: 28),
                      onPressed: _deleteStory),
                IconButton(
                    icon:
                        const Icon(Icons.close, color: Colors.white, size: 30),
                    onPressed: () => Navigator.pop(context)),
              ],
            ),
          ),

          // 🔥 7A. STORY RESHARE TAG 🔥
          if (isStoryReshare)
            Positioned(
                top: MediaQuery.paddingOf(context).top + 90,
                left: 16,
                child: GestureDetector(
                    onTap: () {
                      _pauseStory();
                      final parts = story['url']
                          .toString()
                          .replaceFirst('reshare://', '')
                          .split('|');
                      final origId = parts.length > 0 ? parts[0] : '';
                      final origUser = parts.length > 1
                          ? Uri.decodeComponent(parts[1])
                          : 'User';
                      final origAvatar =
                          parts.length > 2 ? Uri.decodeComponent(parts[2]) : '';
                      final origSchool =
                          parts.length > 3 ? Uri.decodeComponent(parts[3]) : '';
                      final isGroup =
                          parts.length > 4 ? parts[4] == 'true' : false;

                      showModalBottomSheet(
                          context: context,
                          backgroundColor: Colors.grey[900],
                          shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(20))),
                          builder: (ctx) => Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircleAvatar(
                                      radius: 40,
                                      backgroundImage: origAvatar.isNotEmpty
                                          ? NetworkImage(origAvatar)
                                          : null,
                                      backgroundColor: Colors.grey[800],
                                      child: origAvatar.isEmpty
                                          ? Icon(
                                              isGroup
                                                  ? Icons.groups
                                                  : Icons.person,
                                              size: 40,
                                              color: Colors.white54)
                                          : null,
                                    ),
                                    const SizedBox(height: 16),
                                    const Text('Original Post by',
                                        style: TextStyle(
                                            color: Colors.white54,
                                            fontSize: 12)),
                                    Text(isGroup ? origUser : '@$origUser',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 20,
                                            fontWeight: FontWeight.bold)),
                                    if (origSchool.isNotEmpty)
                                      Text(origSchool,
                                          style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 14)),
                                    const SizedBox(height: 24),
                                    SizedBox(
                                        width: double.infinity,
                                        child: ElevatedButton(
                                          style: ElevatedButton.styleFrom(
                                              backgroundColor:
                                                  const Color(0xFF4CAF50),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      vertical: 16),
                                              shape: RoundedRectangleBorder(
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                          12))),
                                          onPressed: () {
                                            Navigator.pop(ctx);
                                            if (isGroup) {
                                              Navigator.push(
                                                  context,
                                                  MaterialPageRoute(
                                                      builder: (_) =>
                                                          GroupInviteScreen(
                                                              chatId: origId,
                                                              userPreferences:
                                                                  widget
                                                                      .userPreferences))).then(
                                                  (_) => _resumeStory());
                                            } else {
                                              UniversalProfileCard.show(
                                                  context,
                                                  origId,
                                                  widget.userPreferences);
                                            }
                                          },
                                          child: Text(
                                              isGroup
                                                  ? 'View Group'
                                                  : 'View Profile',
                                              style: const TextStyle(
                                                  color: Colors.black,
                                                  fontWeight: FontWeight.bold)),
                                        ))
                                  ]))).then((_) => _resumeStory());
                    },
                    child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.65),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: Colors.white24)),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.repeat,
                              color: Colors.white, size: 14),
                          const SizedBox(width: 6),
                          Text(
                              'Reshared from ${Uri.decodeComponent(story['url'].toString().replaceFirst('reshare://', '').split('|')[1])}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold)),
                        ]))))

          // 🔥 7B. SHARED GIST / MOMENT PREVIEW TAG 🔥
          else if (isSharedGist)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 90,
              left: 16,
              child: FutureBuilder<Map<String, dynamic>?>(
                future: _getCachedSharedItemData(story['url'].toString()),
                builder: (context, snapshot) {
                  final isMoment =
                      story['url'].toString().contains('type=moment');
                  final tagColor = isMoment ? Colors.amber : Colors.blueAccent;

                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                          color: Colors.black87,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: tagColor.withOpacity(0.5))),
                      child: const SizedBox(
                          width: 120,
                          height: 38,
                          child: Center(
                              child: LinearProgressIndicator(
                                  color: Colors.white24))),
                    );
                  }

                  final data = snapshot.data;
                  final sharedProfile =
                      data?['profiles'] as Map<String, dynamic>? ?? {};

                  final originalUser =
                      sharedProfile['username'] ?? 'Unknown User';
                  final originalSchool =
                      sharedProfile['school_name'] ?? 'Unknown Location';

                  return GestureDetector(
                    onTap: () {
                      final parsedIdStr = Uri.tryParse(story['url'].toString())
                          ?.queryParameters['id'];
                      if (parsedIdStr != null) {
                        _pauseStory();
                        if (!isMoment) {
                          Navigator.pushNamed(context, '/gist',
                                  arguments: {'id': parsedIdStr})
                              .then((_) => _resumeStory());
                        }
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.85),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: tagColor, width: 1.5),
                          boxShadow: [
                            BoxShadow(
                                color: tagColor.withOpacity(0.2),
                                blurRadius: 8,
                                spreadRadius: 1)
                          ]),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Icon(
                                isMoment ? Icons.photo_library : Icons.campaign,
                                color: tagColor,
                                size: 18),
                            const SizedBox(width: 6),
                            Text(isMoment ? 'Shared Moment' : 'Shared Gist',
                                style: TextStyle(
                                    color: tagColor,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                    letterSpacing: 0.5))
                          ]),
                          const SizedBox(height: 6),
                          Text('@$originalUser',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15)),
                          Text(originalSchool,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),

          // 8. THE BOTTOM INPUT BAR (REPLY / ACTIONS)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            bottom: MediaQuery.viewInsetsOf(context).bottom > 0
                ? MediaQuery.viewInsetsOf(context).bottom + 10
                : 30,
            left: 16,
            right: 16,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: Colors.white24)),
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        const Icon(Icons.emoji_emotions_outlined,
                            color: Colors.white60, size: 22),
                        Expanded(
                          child: TextField(
                            controller: _replyController,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 16),
                            onTap: _pauseStory,
                            onChanged: (value) => setState(() {}),
                            decoration: const InputDecoration(
                                hintText: 'Reply...',
                                hintStyle: TextStyle(color: Colors.white54),
                                border: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 12)),
                            onSubmitted: (_) => _sendStoryReply(story),
                          ),
                        ),
                        if (_replyController.text.isNotEmpty)
                          IconButton(
                              icon: const Icon(Icons.send, color: Colors.white),
                              onPressed: () => _sendStoryReply(story)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                if (!isOwnStory)
                  GestureDetector(
                      onTap: _reshareStory,
                      child: const Padding(
                          padding: EdgeInsets.only(bottom: 10),
                          child: Icon(Icons.repeat,
                              color: Colors.white, size: 28))),
                if (isOwnStory)
                  GestureDetector(
                      onTap: _showViewersList,
                      child: Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(children: [
                            const Icon(Icons.remove_red_eye,
                                color: Colors.white, size: 24),
                            const SizedBox(width: 4),
                            Text('$_viewCount',
                                style: const TextStyle(
                                    color: Colors.white, fontSize: 14))
                          ]))),
                const SizedBox(width: 16),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          icon: Icon(
                              _likedStoryIds.contains(story['id'])
                                  ? Icons.favorite
                                  : Icons.favorite_border,
                              color: _likedStoryIds.contains(story['id'])
                                  ? Colors.red
                                  : Colors.white,
                              size: 28),
                          onPressed: _toggleLike),
                      const SizedBox(width: 6),
                      Text('${story['likes_count'] ?? 0}',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
