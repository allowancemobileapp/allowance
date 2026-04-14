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
  // === ADD THESE NEW FIELDS (right after `bool _isPaused = false;`) ===
  VideoPlayerController? _preloadedController;
  int? _preloadedIndex;
  bool _isTransitioning = false;

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

  // === REPLACE _videoProgressListener WITH THIS (fixes "doesn't advance to next story") ===
  // === REPLACE _videoProgressListener WITH THIS ===
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

  // === REPLACE dispose WITH THIS ===
  @override
  void dispose() {
    _progressTimer?.cancel();
    _videoController?.removeListener(_videoProgressListener);
    _videoController?.dispose();
    _preloadedController?.dispose();
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

          PageView.builder(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() => _currentIndex = index);
              _playCurrentStory();
              _startProgressForCurrentStory();
            },
            itemCount: _sortedStories.length,
            itemBuilder: (context, index) {
              final story = _sortedStories[index];
              final isVideo = story['media_type'] == 'video';

              return GestureDetector(
                onLongPressStart: (_) => _pauseStory(),
                onLongPressEnd: (_) => _resumeStory(),
                child: isVideo
                    ? (_currentIndex == index &&
                            _videoController != null &&
                            _videoController!.value.isInitialized
                        ? Center(
                            child: AspectRatio(
                              aspectRatio: _videoController!.value.aspectRatio,
                              child: VideoPlayer(_videoController!),
                            ),
                          )
                        : const Center(child: CircularProgressIndicator()))
                    : Center(
                        child: Image.network(
                          story['media_url'],
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(Icons.error,
                              color: Colors.white, size: 60),
                        ),
                      ),
              );
            },
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
