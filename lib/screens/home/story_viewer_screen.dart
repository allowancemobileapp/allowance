// lib/screens/home/story_viewer_screen.dart
import 'package:flutter/material.dart';
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

  const StoryViewerScreen({
    super.key,
    required this.stories,
    required this.initialIndex,
    required this.userPreferences,
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

  late final List<dynamic> _sortedStories;

  // Theme color for paywall (same as your app)
  final Color themeColor = const Color(0xFF4CAF50);

  @override
  void initState() {
    super.initState();
    _sortedStories = widget.stories;
    _currentIndex = widget.initialIndex;
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

  // === REPLACE YOUR _playCurrentStory METHOD WITH THIS ===
  void _playCurrentStory() {
    _videoController?.removeListener(_videoProgressListener);
    _videoController?.dispose();
    _videoController = null;

    final story = _sortedStories[_currentIndex];
    if (story['media_type'] == 'video') {
      // Use preloaded controller if available → instant play, no blank/loading
      if (_preloadedIndex == _currentIndex && _preloadedController != null) {
        _videoController = _preloadedController;
        _preloadedController = null;
        _preloadedIndex = null;
        if (!_isPaused) {
          _videoController!.play();
        }
      } else {
        // Fallback (first story or going backwards)
        _videoController = VideoPlayerController.network(story['media_url'])
          ..initialize().then((_) {
            if (mounted && !_isPaused) _videoController!.play();
          });
      }
    }

    // Preload the NEXT story’s video right now (this is what removes the break)
    _preloadNext();
  }

  // === ADD THIS NEW METHOD (place it right after _playCurrentStory) ===
  void _preloadNext() {
    // Clean up old preload
    _preloadedController?.dispose();
    _preloadedController = null;
    _preloadedIndex = null;

    if (_currentIndex + 1 >= _sortedStories.length) return;

    final nextStory = _sortedStories[_currentIndex + 1];
    if (nextStory['media_type'] != 'video') return;

    _preloadedIndex = _currentIndex + 1;
    _preloadedController = VideoPlayerController.network(nextStory['media_url'])
      ..initialize(); // ready in advance
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
    final currentUserId = currentStory['user_id'] as String?;

    if (currentUserId == null) {
      return (0, _sortedStories.length - 1);
    }

    // Find first story of this user
    int start = 0;
    for (int i = 0; i < _sortedStories.length; i++) {
      final userId = _sortedStories[i]['user_id'] as String?;
      if (userId == currentUserId) {
        start = i;
        break;
      }
    }

    // Find last story of this user
    int end = start;
    for (int i = start; i < _sortedStories.length; i++) {
      final userId = _sortedStories[i]['user_id'] as String?;
      if (userId != currentUserId) {
        end = i - 1;
        break;
      }
      end = i;
    }

    return (start, end);
  }

  // Helper to show "23h ago", "3m ago", "just now", etc.
  String _timeAgo(String createdAt) {
    final date = DateTime.parse(createdAt).toLocal();
    final difference = DateTime.now().difference(date);

    if (difference.inMinutes < 1) return 'just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }

  void _initViewCountAndSubscription() {
    final story = _sortedStories[_currentIndex];
    _viewCount = (story['story_views'] as List?)?.length ?? 0;

    _viewSubscription?.cancel();
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    if (currentUserId == null || currentUserId != story['user_id']) return;

    _viewSubscription = Supabase.instance.client
        .from('story_views')
        .stream(primaryKey: ['id'])
        .eq('story_id', story['id'] as int)
        .listen((payload) {
          if (mounted) {
            setState(() => _viewCount = payload.length);
          }
        });
  }

  // === REPLACE _videoProgressListener WITH THIS (fixes "doesn't advance to next story") ===
  void _videoProgressListener() {
    if (!mounted || _videoController == null || _isPaused || _isTransitioning) {
      return;
    }

    final controller = _videoController!;

    if (controller.value.isInitialized) {
      final position = controller.value.position;
      final duration = controller.value.duration;

      // Update progress bar
      final progress = position.inMilliseconds /
          duration.inMilliseconds.clamp(1, double.infinity);
      setState(() => _progressValues[_currentIndex] = progress.clamp(0.0, 1.0));

      // Trigger next story exactly when video ends
      if (duration.inMilliseconds > 0 && position >= duration) {
        _isTransitioning = true;
        controller.removeListener(_videoProgressListener);
        _goToNextStory();
      }
    }
  }

  // === REPLACE _goToNextStory WITH THIS ===
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

  // === REPLACE _goToPreviousStory WITH THIS ===
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

  // === REPLACE _toggleLike WITH THIS (fixes like count resetting to 0 even when RLS blocks count update) ===
  // === REPLACE _toggleLike WITH THIS (fixes count resetting to 0) ===
  // === REPLACE _toggleLike WITH THIS ===
  Future<void> _toggleLike() async {
    final story = _sortedStories[_currentIndex];
    final storyId = story['id'] as int;
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return;

    final wasLiked = _likedStoryIds.contains(storyId);
    final currentCount = (story['likes_count'] ?? 0) as int;

    // Optimistic UI update (instant feel)
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
      // Database operation only — the trigger handles the real count
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
      // Rollback UI only if DB failed
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
              const Text(
                'Join Allowance Plus',
                style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white),
              ),
              const SizedBox(height: 12),
              const Text(
                'JOIN ALLOWANCE PLUS TO POST STORY GIST AND PASS THE FUN!',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: Colors.white70),
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
                        builder: (_) => SubscriptionScreen(
                          userPreferences: widget.userPreferences,
                          themeColor: themeColor, // ← Fixed here
                        ),
                      ),
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: themeColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
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

    // Premium user - normal reshare
    final user = Supabase.instance.client.auth.currentUser;
    if (user == null) return;

    final original = _sortedStories[_currentIndex];

    final shouldReshare = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.black,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Reshare this story?',
              style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text(
              'It will appear on your profile as a new story.',
              style: TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
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
                        ElevatedButton.styleFrom(backgroundColor: Colors.white),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Reshare',
                        style: TextStyle(color: Colors.black)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    if (shouldReshare != true) return;

    try {
      await Supabase.instance.client.from('stories').insert({
        'user_id': user.id,
        'media_url': original['media_url'],
        'media_type': original['media_type'],
        'caption': original['caption'],
        'url': original['url'],
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Story reshared successfully!'),
              backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      debugPrint('Reshare error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not reshare story'),
              backgroundColor: Colors.red),
        );
      }
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
        Navigator.pop(context); // close viewer after delete
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

  // === REPLACE dispose WITH THIS ===
  @override
  void dispose() {
    _progressTimer?.cancel();
    _videoController?.removeListener(_videoProgressListener);
    _videoController?.dispose();
    _viewSubscription?.cancel();
    _preloadedController?.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final story = _sortedStories[_currentIndex];
    final currentUser = Supabase.instance.client.auth.currentUser;
    final isOwnStory = currentUser?.id == story['user_id'];

    // Get the range of stories belonging to the current user
    final (userStart, userEnd) = _getCurrentUserStoryRange();
    final userStoryCount = userEnd - userStart + 1;
    final currentUserPosition = _currentIndex - userStart;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // PageView
          PageView.builder(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() => _currentIndex = index);
              _playCurrentStory();
              _startProgressForCurrentStory();
              _markStoryAsViewed(index);
              _initViewCountAndSubscription();
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
                            colors: [Color(0xFF1A1A1A), Color(0xFF111111)],
                          ),
                        ),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 40),
                            child: Text(
                              storyItem['caption'] ?? '',
                              style: const TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                                height: 1.35,
                                letterSpacing: -0.5,
                              ),
                              textAlign: TextAlign.center,
                            ),
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
                                child: VideoPlayer(_videoController!),
                              ),
                            )
                          : const Center(child: CircularProgressIndicator()))
                    else
                      Center(
                        child: Image.network(
                          storyItem['media_url'],
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(Icons.error,
                              color: Colors.white, size: 60),
                        ),
                      ),
                    if (!isText && caption.isNotEmpty)
                      Positioned(
                        bottom: 140,
                        left: 24,
                        right: 24,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              vertical: 12, horizontal: 16),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.65),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            caption,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                              height: 1.4,
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

          // ==================== PROGRESS BARS - NOW PER USER ====================
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
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

          // Tap zones
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

          // Top bar
          Positioned(
            top: MediaQuery.of(context).padding.top + 45,
            left: 16,
            right: 16,
            child: Row(
              children: [
                CircleAvatar(
                  backgroundImage: story['profiles']?['avatar_url'] != null
                      ? NetworkImage(story['profiles']['avatar_url'])
                      : null,
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '@${story['profiles']?['username'] ?? 'user'}',
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                    Row(
                      children: [
                        if (story['profiles']?['school_name'] != null &&
                            story['profiles']!['school_name']
                                .toString()
                                .trim()
                                .isNotEmpty)
                          Text(
                            story['profiles']!['school_name'],
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.6),
                                fontSize: 12),
                          ),
                        if (story['profiles']?['school_name'] != null &&
                            story['profiles']!['school_name']
                                .toString()
                                .trim()
                                .isNotEmpty)
                          const Text(' • ',
                              style: TextStyle(
                                  color: Colors.white54, fontSize: 12)),
                        Text(
                          _timeAgo(story['created_at']),
                          style: const TextStyle(
                              color: Colors.white54, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
                const Spacer(),
                if (isOwnStory)
                  IconButton(
                    icon: const Icon(Icons.delete, color: Colors.red, size: 28),
                    onPressed: _deleteStory,
                  ),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),

          // URL icon
          if (story['url'] != null && story['url'].toString().trim().isNotEmpty)
            Positioned(
              bottom: 130,
              right: 24,
              child: GestureDetector(
                onTap: () async {
                  final uri = Uri.parse(story['url'] as String);
                  if (await canLaunchUrl(uri))
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                },
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.2),
                      shape: BoxShape.circle),
                  child: const Icon(Icons.link, color: Colors.white, size: 28),
                ),
              ),
            ),

          // Bottom actions
          Positioned(
            bottom: 40,
            left: 24,
            right: 24,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!isOwnStory)
                  GestureDetector(
                    onTap: _reshareStory,
                    child: Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          shape: BoxShape.circle),
                      child: const Icon(Icons.repeat,
                          color: Colors.white, size: 28),
                    ),
                  ),
                if (!isOwnStory) const SizedBox(width: 16),
                if (isOwnStory)
                  Column(
                    children: [
                      const Icon(Icons.remove_red_eye,
                          color: Colors.white, size: 32),
                      Text('$_viewCount',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 15)),
                    ],
                  ),
                if (isOwnStory) const SizedBox(width: 24),
                Column(
                  children: [
                    IconButton(
                      icon: Icon(
                        _likedStoryIds.contains(story['id'])
                            ? Icons.favorite
                            : Icons.favorite_border,
                        color: Colors.white,
                        size: 32,
                      ),
                      onPressed: _toggleLike,
                    ),
                    Text('${story['likes_count'] ?? 0}',
                        style:
                            const TextStyle(color: Colors.white, fontSize: 15)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
