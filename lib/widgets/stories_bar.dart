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
  late Future<List<dynamic>> _storiesFuture;
  late final RealtimeChannel _realtimeChannel;

  @override
  void initState() {
    super.initState();
    _loadStories();
    _setupRealtimeSubscription();
  }

  void refresh() {
    setState(() {
      _loadStories();
    });
  }

  void _loadStories() {
    final supabase = Supabase.instance.client;

    _storiesFuture = supabase
        .from('stories')
        .select('''
          id,
          user_id,
          media_url,
          media_type,
          caption,
          url,
          expires_at,
          created_at,
          likes_count,
          profiles:user_id(username, avatar_url, school_name),
          story_views!left(id)
        ''')
        .gt('expires_at', DateTime.now().toUtc().toIso8601String())
        .order('created_at', ascending: false);
  }

  void _setupRealtimeSubscription() {
    final supabase = Supabase.instance.client;

    _realtimeChannel = supabase.channel('stories-realtime');

    // Listen to ALL changes on stories table
    _realtimeChannel
        .onPostgresChanges(
          event: PostgresChangeEvent.all, // insert, update, delete
          schema: 'public',
          table: 'stories',
          callback: (_) => refresh(),
        )
        // Also listen to story_views (so "viewed" circle updates instantly)
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'story_views',
          callback: (_) => refresh(),
        )
        .subscribe();
  }

  // Helper to show "23h ago", "3m ago", etc.
  // ignore: unused_element
  String _timeAgo(String createdAt) {
    final date = DateTime.parse(createdAt).toLocal();
    final difference = DateTime.now().difference(date);

    if (difference.inMinutes < 1) return 'just now';
    if (difference.inMinutes < 60) return '${difference.inMinutes}m ago';
    if (difference.inHours < 24) return '${difference.inHours}h ago';
    return '${difference.inDays}d ago';
  }

  @override
  void dispose() {
    _realtimeChannel.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<dynamic>>(
      future: _storiesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            height: 88,
            color: Colors.grey[900],
            alignment: Alignment.center,
            child: const CircularProgressIndicator(color: Color(0xFF4CAF50)),
          );
        }

        if (snapshot.hasError || !snapshot.hasData) {
          return Container(
            height: 88,
            color: Colors.grey[900],
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

        uniqueUsers.sort((a, b) {
          bool aViewed =
              a.value.every((s) => (s['story_views'] as List).isNotEmpty);
          bool bViewed =
              b.value.every((s) => (s['story_views'] as List).isNotEmpty);
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

        return Container(
          height: 100,
          color: Colors.grey[900],
          child: uniqueUsers.isEmpty
              ? const Center(
                  child: Text("No stories yet",
                      style: TextStyle(color: Colors.white54, fontSize: 15)),
                )
              : ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  itemCount: uniqueUsers.length,
                  itemBuilder: (ctx, i) {
                    final username = uniqueUsers[i].key;
                    final userStories = uniqueUsers[i].value;

                    final isFullyViewed = userStories
                        .every((s) => (s['story_views'] as List).isNotEmpty);

                    final firstStory = userStories.first;
                    final profile =
                        firstStory['profiles'] as Map<String, dynamic>? ?? {};
                    final avatarUrl = profile['avatar_url'] as String?;

                    int startIndex = 0;
                    for (int j = 0; j < i; j++) {
                      startIndex += uniqueUsers[j].value.length;
                    }

                    return GestureDetector(
                      onTap: () async {
                        final sortedUserStories =
                            List<dynamic>.from(userStories);
                        sortedUserStories.sort((a, b) =>
                            DateTime.parse(b['created_at'])
                                .compareTo(DateTime.parse(a['created_at'])));

                        int localTargetIndex = 0;
                        for (int k = 0; k < sortedUserStories.length; k++) {
                          final views =
                              (sortedUserStories[k]['story_views'] as List? ??
                                  []);
                          if (views.isEmpty) {
                            localTargetIndex = k;
                            break;
                          }
                        }

                        final targetGlobalIndex = startIndex + localTargetIndex;

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
                        if (mounted) refresh(); // ← refresh after viewing
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
                                backgroundColor: Colors.grey[800],
                                backgroundImage:
                                    avatarUrl != null && avatarUrl.isNotEmpty
                                        ? NetworkImage(avatarUrl)
                                        : null,
                                child: (avatarUrl == null || avatarUrl.isEmpty)
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
  }
}
