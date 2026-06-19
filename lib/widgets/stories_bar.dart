// lib/widgets/stories_bar.dart
import 'package:allowance/screens/home/create_story_screen.dart';
import 'package:allowance/screens/home/story_viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../models/user_preferences.dart';

class StoriesBar extends StatefulWidget {
  final UserPreferences userPreferences;

  const StoriesBar({
    super.key,
    required this.userPreferences,
  });

  @override
  StoriesBarState createState() => StoriesBarState();
}

class StoriesBarState extends State<StoriesBar> {
  Future<List<dynamic>>? _storiesFuture;
  late final RealtimeChannel _realtimeChannel;
  String? _myId; // 🔥 NEW: Cache current user ID

  @override
  void initState() {
    super.initState();
    _myId = Supabase.instance.client.auth.currentUser?.id;
    _storiesFuture = _loadStories();
    _setupRealtimeSubscription();
  }

  void refresh() {
    if (mounted) {
      setState(() {
        _storiesFuture = _loadStories();
      });
    }
  }

  Future<List<dynamic>> _loadStories() async {
    final supabase = Supabase.instance.client;

    try {
      final response = await supabase
          .from('stories')
          .select('''
            id, user_id, media_url, media_type, caption, url, expires_at, created_at, likes_count,
            profiles:user_id(username, avatar_url, school_name, subscription_tier),
            story_views(user_id) 
          ''') // 🔥 FIX: Added 'subscription_tier' so the Plus Star works in the viewer!
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .order('created_at', ascending: false);

      if (mounted && response != null) {
        for (var story in response) {
          final avatarUrl = story['profiles']?['avatar_url'] as String?;
          if (avatarUrl != null && avatarUrl.isNotEmpty) {
            precacheImage(NetworkImage(avatarUrl), context);
          }
        }
      }

      return response as List<dynamic>;
    } catch (e) {
      debugPrint("Error fetching stories: $e");
      rethrow;
    }
  }

  void _setupRealtimeSubscription() {
    final supabase = Supabase.instance.client;

    _realtimeChannel = supabase.channel('stories-realtime');

    _realtimeChannel
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'stories',
          callback: (_) => refresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'story_views',
          callback: (_) => refresh(),
        )
        .subscribe();
  }

  @override
  void dispose() {
    _realtimeChannel.unsubscribe();
    super.dispose();
  }

  // 🔥 THE MISSING METHOD: This checks if YOU have viewed the story!
  bool _hasViewedStory(dynamic story) {
    if (_myId == null) return false;
    final views = story['story_views'] as List<dynamic>? ?? [];
    return views.any((v) => v['user_id'].toString() == _myId);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<dynamic>>(
      future: _storiesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            height: 100,
            color: const Color(0xFF121212),
            alignment: Alignment.center,
            child: const CircularProgressIndicator(color: Color(0xFF4CAF50)),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return Container(
            height: 100,
            color: const Color(0xFF121212),
            alignment: Alignment.center,
            child: const Text("Error loading stories",
                style: TextStyle(color: Colors.white54, fontSize: 12)),
          );
        }

        final allStories = snapshot.data!;
        final Map<String, List<dynamic>> grouped = {};
        for (var story in allStories) {
          final profile = story['profiles'] as Map<String, dynamic>? ?? {};
          final username = profile['username'] ?? 'unknown';
          grouped.putIfAbsent(username, () => []).add(story);
        }

        final uniqueUsers = grouped.entries.toList();

        // Sort users so people with unseen stories jump to the front!
        uniqueUsers.sort((a, b) {
          bool aViewed = a.value.every((s) => _hasViewedStory(s));
          bool bViewed = b.value.every((s) => _hasViewedStory(s));
          if (aViewed && !bViewed) return 1;
          if (!aViewed && bViewed) return -1;
          return 0;
        });

        final List<dynamic> continuousStories = [];
        for (var group in uniqueUsers) {
          final userStories = List<dynamic>.from(group.value);
          userStories.sort((a, b) => DateTime.parse(a['created_at'])
              .compareTo(DateTime.parse(b['created_at'])));
          continuousStories.addAll(userStories);
        }

        return ValueListenableBuilder<Map<String, dynamic>?>(
          valueListenable: CreateStoryScreen.pendingStoryUpload,
          builder: (context, pendingUpload, child) {
            final int itemCount =
                uniqueUsers.length + (pendingUpload != null ? 1 : 0);

            return Container(
              height: 100,
              color: const Color(0xFF121212),
              child: itemCount == 0
                  ? const Center(
                      child: Text("No stories yet",
                          style:
                              TextStyle(color: Colors.white54, fontSize: 15)),
                    )
                  : ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      itemCount: itemCount,
                      itemBuilder: (ctx, i) {
                        // --- POSTING UI RING ---
                        if (pendingUpload != null && i == 0) {
                          final progress =
                              pendingUpload['progress'] as double? ?? 0.0;
                          final percent = (progress * 100).toInt();
                          final avatarUrl = widget.userPreferences.avatarUrl;

                          return Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    SizedBox(
                                      width: 60,
                                      height: 60,
                                      child: CircularProgressIndicator(
                                        value: progress,
                                        color: const Color(0xFF4CAF50),
                                        backgroundColor: Colors.white24,
                                        strokeWidth: 3,
                                      ),
                                    ),
                                    CircleAvatar(
                                      radius: 26,
                                      backgroundColor: const Color(0xFF1E1E1E),
                                      backgroundImage: avatarUrl != null &&
                                              avatarUrl.isNotEmpty
                                          ? NetworkImage(avatarUrl)
                                          : null,
                                      child: (avatarUrl == null ||
                                              avatarUrl.isEmpty)
                                          ? const Icon(Icons.person,
                                              color: Colors.white, size: 28)
                                          : null,
                                    ),
                                    Container(
                                      width: 52,
                                      height: 52,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: Colors.black.withOpacity(0.6),
                                      ),
                                      child: Center(
                                        child: Text('$percent%',
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold)),
                                      ),
                                    )
                                  ],
                                ),
                                const SizedBox(height: 4),
                                const SizedBox(
                                  width: 68,
                                  child: Text('Posting...',
                                      style: TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFF4CAF50),
                                          fontWeight: FontWeight.bold),
                                      textAlign: TextAlign.center),
                                ),
                              ],
                            ),
                          );
                        }

                        // --- NORMAL STORY RING ---
                        final actualIndex = pendingUpload != null ? i - 1 : i;
                        final username = uniqueUsers[actualIndex].key;
                        final userStories = uniqueUsers[actualIndex].value;

                        final isFullyViewed =
                            userStories.every((s) => _hasViewedStory(s));

                        final firstStory = userStories.first;
                        final profile =
                            firstStory['profiles'] as Map<String, dynamic>? ??
                                {};
                        final userAvatarUrl = profile['avatar_url'] as String?;

                        int startIndex = 0;
                        for (int j = 0; j < actualIndex; j++) {
                          startIndex += uniqueUsers[j].value.length;
                        }

                        return GestureDetector(
                          onTap: () async {
                            final sortedUserStories =
                                List<dynamic>.from(userStories);

                            sortedUserStories.sort((a, b) =>
                                DateTime.parse(a['created_at']).compareTo(
                                    DateTime.parse(b['created_at'])));

                            int localTargetIndex = 0;
                            for (int k = 0; k < sortedUserStories.length; k++) {
                              if (!_hasViewedStory(sortedUserStories[k])) {
                                localTargetIndex = k;
                                break;
                              }
                            }

                            final targetGlobalIndex =
                                startIndex + localTargetIndex;

                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => StoryViewerScreen(
                                  stories: continuousStories,
                                  initialIndex: targetGlobalIndex,
                                  userPreferences: widget.userPreferences,
                                ),
                              ),
                            );
                            if (mounted) refresh();
                          },
                          child: Padding(
                            padding: const EdgeInsets.only(right: 16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: isFullyViewed
                                            ? Colors.grey[700]!
                                            : const Color(0xFF4CAF50),
                                        width: 2),
                                  ),
                                  child: CircleAvatar(
                                    radius: 28,
                                    backgroundColor: const Color(0xFF1E1E1E),
                                    backgroundImage: userAvatarUrl != null &&
                                            userAvatarUrl.isNotEmpty
                                        ? NetworkImage(userAvatarUrl)
                                        : null,
                                    child: (userAvatarUrl == null ||
                                            userAvatarUrl.isEmpty)
                                        ? const Icon(Icons.person,
                                            color: Colors.white, size: 28)
                                        : null,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                SizedBox(
                                  width: 68,
                                  child: Text(
                                    '@$username',
                                    style: TextStyle(
                                        fontSize: 10,
                                        color: isFullyViewed
                                            ? Colors.white38
                                            : Colors.white70),
                                    textAlign: TextAlign.center,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            );
          },
        );
      },
    );
  }
}
