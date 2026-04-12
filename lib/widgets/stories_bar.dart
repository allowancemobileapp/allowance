// lib/widgets/stories_bar.dart
import 'package:allowance/screens/home/story_viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class StoriesBar extends StatefulWidget {
  const StoriesBar({super.key});

  @override
  State<StoriesBar> createState() => _StoriesBarState();
}

class _StoriesBarState extends State<StoriesBar> {
  late Future<List<dynamic>> _storiesFuture;

  @override
  void initState() {
    super.initState();
    _loadStories();
  }

  void _loadStories() {
    _storiesFuture = Supabase.instance.client
        .from('stories')
        .select('''
          id, media_url, media_type, caption, url, expires_at, created_at, likes_count,
          profiles:user_id(username, avatar_url)
        ''')
        .gt('expires_at', DateTime.now().toUtc().toIso8601String())
        .order('created_at', ascending: false);
  }

  // Public method to refresh after posting a new story
  void refresh() {
    if (mounted) setState(() => _loadStories());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<dynamic>>(
      future: _storiesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Container(
            height: 88, // Must be 110 to fit all elements + padding
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
          final userId = profile['username'] ?? 'unknown';
          grouped.putIfAbsent(userId, () => []).add(story);
        }

        final uniqueUsers = grouped.entries.toList();

        return Container(
          height: 100, // DO NOT REDUCE THIS BELOW 100
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
                    final firstStory = userStories.first;
                    final profile =
                        firstStory['profiles'] as Map<String, dynamic>? ?? {};
                    final avatarUrl = profile['avatar_url'] as String?;

                    return GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => StoryViewerScreen(
                              stories: userStories,
                              initialIndex: 0,
                            ),
                          ),
                        );
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
                                    color: const Color(0xFF4CAF50), width: 2),
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
                                style: const TextStyle(
                                    fontSize: 10, color: Colors.white70),
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
