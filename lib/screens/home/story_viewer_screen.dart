// lib/screens/home/story_viewer_screen.dart
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:async';

class StoryViewerScreen extends StatefulWidget {
  final List<dynamic> stories;
  final int initialIndex;

  const StoryViewerScreen({
    super.key,
    required this.stories,
    required this.initialIndex,
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

  // For correct chronological order (earliest → latest)
  late final List<dynamic> _sortedStories;

  @override
  void initState() {
    super.initState();

    // Sort stories: earliest to latest
    _sortedStories = List.from(widget.stories)
      ..sort((a, b) {
        final dateA = DateTime.parse(a['created_at'] as String);
        final dateB = DateTime.parse(b['created_at'] as String);
        return dateA.compareTo(dateB);
      });

    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
    _progressValues = List.filled(_sortedStories.length, 0.0);

    _loadLikedStories();
    _playCurrentStory();
    _startProgressForCurrentStory();
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

  void _playCurrentStory() {
    _videoController?.removeListener(_videoProgressListener);
    _videoController?.dispose();
    _videoController = null;

    final story = _sortedStories[_currentIndex];
    if (story['media_type'] == 'video') {
      _videoController = VideoPlayerController.network(story['media_url'])
        ..initialize().then((_) {
          if (mounted && !_isPaused) _videoController!.play();
        });
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

  void _videoProgressListener() {
    if (!mounted || _videoController == null || _isPaused) return;
    final controller = _videoController!;

    if (controller.value.isInitialized) {
      final progress = controller.value.position.inMilliseconds /
          controller.value.duration.inMilliseconds.clamp(1, double.infinity);

      setState(() => _progressValues[_currentIndex] = progress.clamp(0.0, 1.0));

      if (progress >= 0.99) {
        _goToNextStory();
      }
    }
  }

  void _goToNextStory() {
    if (_currentIndex < _sortedStories.length - 1) {
      setState(() {
        _progressValues[_currentIndex] = 1.0;
        _currentIndex++;
      });
      _playCurrentStory();
      _startProgressForCurrentStory();
    } else {
      Navigator.pop(context);
    }
  }

  void _goToPreviousStory() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
        _progressValues[_currentIndex] = 0.0;
      });
      _playCurrentStory();
      _startProgressForCurrentStory();
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
    final newCount = wasLiked ? currentCount - 1 : currentCount + 1;

    try {
      if (wasLiked) {
        await supabase
            .from('story_likes')
            .delete()
            .eq('story_id', storyId)
            .eq('user_id', user.id);
        _likedStoryIds.remove(storyId);
      } else {
        await supabase
            .from('story_likes')
            .insert({'story_id': storyId, 'user_id': user.id});
        _likedStoryIds.add(storyId);
      }

      // Update database
      await supabase
          .from('stories')
          .update({'likes_count': newCount}).eq('id', storyId);

      // Update local data for instant UI feedback
      story['likes_count'] = newCount;

      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Like error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Could not update like'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  void dispose() {
    _progressTimer?.cancel();
    _videoController?.removeListener(_videoProgressListener);
    _videoController?.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final story = _sortedStories[_currentIndex];
    final isVideo = story['media_type'] == 'video';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Progress bars
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 16,
            right: 16,
            child: Row(
              children: List.generate(
                _sortedStories.length,
                (i) => Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: _progressValues[i],
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

          // === MEDIA (with proper long-press pause) ===
          GestureDetector(
            onLongPressStart: (_) => _pauseStory(),
            onLongPressEnd: (_) => _resumeStory(),
            child: isVideo
                ? (_videoController != null &&
                        _videoController!.value.isInitialized
                    ? VideoPlayer(_videoController!)
                    : const Center(child: CircularProgressIndicator()))
                : Center(
                    child: Image.network(
                      story['media_url'],
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Icon(Icons.error,
                          color: Colors.white, size: 60),
                    ),
                  ),
          ),

          // === TAP ZONES (left = previous, right = next) ===
          Positioned.fill(
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _goToPreviousStory,
                  ),
                ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _goToNextStory,
                  ),
                ),
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
                Text(
                  '@${story['profiles']?['username'] ?? 'user'}',
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),

          // Caption
          if (story['caption'] != null &&
              story['caption'].toString().isNotEmpty)
            Positioned(
              bottom: 100,
              left: 16,
              right: 16,
              child: Text(
                story['caption'],
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),

          // Like button
          Positioned(
            bottom: 40,
            right: 24,
            child: Column(
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
                Text(
                  '${story['likes_count'] ?? 0}',
                  style: const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
