// lib/screens/chat/explore_screen.dart
import 'package:allowance/screens/chat/chat_room_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:math';
import '../../models/user_preferences.dart';
import '../../widgets/universal_profile_card.dart';
import '../home/story_viewer_screen.dart';

class ExploreScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  const ExploreScreen({super.key, required this.userPreferences});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  final supabase = Supabase.instance.client;
  List<Map<String, dynamic>> _exploreItems = [];
  bool _isLoading = true;
  String _searchQuery = "";
  int _selectedSegment = 0; // 0 for People, 1 for Groups

  @override
  void initState() {
    super.initState();
    _fetchExploreData();
  }

  Future<void> _fetchExploreData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final currentUserId = supabase.auth.currentUser?.id;
      if (currentUserId == null) {
        if (mounted) setState(() => _isLoading = false);
        return;
      }

      List<Map<String, dynamic>> results = [];
      final now = DateTime.now().toUtc().toIso8601String();

      if (_selectedSegment == 0) {
        // --- FETCH PEOPLE ---
        var userQuery =
            supabase.from('profiles').select().neq('id', currentUserId);

        if (_searchQuery.isNotEmpty) {
          userQuery = userQuery.ilike('username', '%$_searchQuery%');
        }

        final List<dynamic> userResponse = await userQuery;

        final List<dynamic> activeStories = await supabase
            .from('stories')
            .select('user_id')
            .gt('expires_at', now);

        final Set<String> userIdsWithStories =
            activeStories.map((s) => s['user_id'].toString()).toSet();

        results = userResponse.map((u) {
          return {
            ...Map<String, dynamic>.from(u),
            'is_group': false,
            'has_active_story': userIdsWithStories.contains(u['id'].toString()),
          };
        }).toList();
      } else {
        // --- FETCH GROUPS (QUERYING CHATS TABLE) ---
        var groupQuery = supabase.from('chats').select().eq('is_group', true);

        if (_searchQuery.isNotEmpty) {
          groupQuery = groupQuery.ilike('group_name', '%$_searchQuery%');
        }

        final List<dynamic> groupResponse = await groupQuery;

        // DEBUG PRINT: Check your console to see if your created groups appear here
        debugPrint("Fetched ${groupResponse.length} groups from Supabase");
        for (var g in groupResponse) {
          debugPrint(
              "Found Group: ${g['group_name']} | Public: ${g['is_public']}");
        }

        results = groupResponse.map((g) {
          return {
            ...Map<String, dynamic>.from(g),
            'is_group': true,
          };
        }).toList();

        // Relaxed filter: Includes groups that are public OR have no public status set
        // If you still don't see your groups, comment out the lines below to see everything
        results = results
            .where((g) => g['is_public'] == true || g['is_public'] == null)
            .toList();
      }

      results.shuffle(Random());

      if (mounted) {
        setState(() {
          _exploreItems = results;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("Explore Fetch Error: $e");
      if (mounted) {
        setState(() {
          _exploreItems = [];
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _openStory(String userId) async {
    try {
      final response = await supabase
          .from('stories')
          .select(
              'id, media_url, media_type, caption, url, expires_at, created_at, likes_count, profiles:user_id(username, avatar_url)')
          .eq('user_id', userId)
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .order('created_at', ascending: false);

      if (response.isNotEmpty && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StoryViewerScreen(
              stories: List<Map<String, dynamic>>.from(response),
              initialIndex: 0,
              userPreferences: widget.userPreferences,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint("Error opening story: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        centerTitle: false,
        title: const Text(
          'Explore',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 24,
          ),
        ),
      ),
      body: Column(
        children: [
          // SEARCH BAR
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8),
            child: TextField(
              style: const TextStyle(color: Colors.white),
              onChanged: (value) {
                setState(() => _searchQuery = value);
                _fetchExploreData();
              },
              decoration: InputDecoration(
                hintText: _selectedSegment == 0
                    ? 'Search people...'
                    : 'Search groups...',
                hintStyle: const TextStyle(color: Colors.white54),
                prefixIcon: const Icon(Icons.search, color: Colors.white54),
                filled: true,
                fillColor: Colors.grey[900],
                contentPadding: EdgeInsets.zero,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // SEGMENTED CONTROL
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<int>(
                backgroundColor: Colors.grey[900]!.withOpacity(0.5),
                thumbColor: Colors.grey[800]!,
                groupValue: _selectedSegment,
                children: {
                  0: _buildSegmentText("People", 0),
                  1: _buildSegmentText("Groups", 1),
                },
                onValueChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _selectedSegment = value;
                      _exploreItems = [];
                    });
                    _fetchExploreData();
                  }
                },
              ),
            ),
          ),

          const SizedBox(height: 8),

          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF4CAF50),
                    ),
                  )
                : _exploreItems.isEmpty
                    ? _buildEmptyState()
                    : RefreshIndicator(
                        onRefresh: _fetchExploreData,
                        color: const Color(0xFF4CAF50),
                        child: GridView.builder(
                          padding: const EdgeInsets.all(12),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: 0.75,
                          ),
                          itemCount: _exploreItems.length,
                          itemBuilder: (context, index) {
                            final item = _exploreItems[index];
                            final cardChild = item['is_group'] == true
                                ? _buildGroupCard(item)
                                : _buildUserCard(item);

                            return TweenAnimationBuilder<double>(
                              duration: Duration(
                                milliseconds: 300 + (index % 6 * 50),
                              ),
                              curve: Curves.easeOut,
                              tween: Tween<double>(begin: 0, end: 1),
                              builder: (context, value, child) {
                                return Opacity(
                                  opacity: value,
                                  child: Transform.translate(
                                    offset: Offset(0, 20 * (1 - value)),
                                    child: child,
                                  ),
                                );
                              },
                              child: cardChild,
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentText(String text, int index) {
    final isSelected = _selectedSegment == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        text,
        style: TextStyle(
          color: isSelected ? Colors.white : Colors.white38,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          fontSize: 14,
        ),
      ),
    );
  }

  Widget _buildUserCard(Map<String, dynamic> user) {
    final hasStory = user['has_active_story'] == true;
    final isPlus = user['subscription_tier'] == 'Membership';

    return GestureDetector(
      onTap: () => UniversalProfileCard.show(context, user['id']),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(16),
          border: isPlus
              ? Border.all(color: Colors.amber.withOpacity(0.3), width: 1)
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: hasStory ? () => _openStory(user['id']) : null,
              child: Container(
                padding: EdgeInsets.all(hasStory ? 2.5 : 0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: hasStory
                      ? Border.all(color: const Color(0xFF4CAF50), width: 2)
                      : null,
                ),
                child: CircleAvatar(
                  radius: 26,
                  backgroundColor: Colors.grey[800],
                  backgroundImage: user['avatar_url'] != null
                      ? CachedNetworkImageProvider(user['avatar_url'])
                      : null,
                  child: user['avatar_url'] == null
                      ? Text(user['username'].toString()[0].toUpperCase(),
                          style: const TextStyle(
                              fontSize: 18, color: Colors.white))
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      '${user['username']}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (isPlus)
                    const Padding(
                      padding: EdgeInsets.only(left: 2.0),
                      child: Icon(Icons.star, color: Colors.amber, size: 10),
                    ),
                ],
              ),
            ),
            Text(
              user['school_name'] ?? 'Allowance',
              style: const TextStyle(color: Colors.white54, fontSize: 10),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Future<Map<String, dynamic>> _fetchGroupPreviewData(
      Map<String, dynamic> group) async {
    final currentUserId = supabase.auth.currentUser?.id;
    final groupIdRaw = group['id'];
    final groupIdText = groupIdRaw.toString();

    final creatorId = (group['created_by'] ??
            group['creator_id'] ??
            group['owner_id'] ??
            group['user_id'] ??
            group['admin_id'])
        ?.toString();

    Map<String, dynamic>? creatorProfile;

    if (creatorId != null && creatorId.isNotEmpty) {
      creatorProfile = await supabase
          .from('profiles')
          .select('id, username, avatar_url, school_name')
          .eq('id', creatorId)
          .maybeSingle();
    }

    final List<Map<String, dynamic>> members = [];

    try {
      final participantRows = await supabase
          .from('chat_participants')
          .select('user_id')
          .eq('chat_id', groupIdRaw);

      final participantIds = <String>{
        for (final row in participantRows) row['user_id'].toString(),
      };

      if (participantIds.isNotEmpty) {
        final profileRows = await supabase
            .from('profiles')
            .select('id, username, avatar_url, school_name')
            .inFilter('id', participantIds.toList());

        for (final profile in profileRows) {
          members.add({
            'user_id': profile['id'],
            'profiles': Map<String, dynamic>.from(profile),
          });
        }
      }
    } catch (e) {
      debugPrint('Member fetch error: $e');
    }

    // Fallback: if no participant rows exist, still show the creator or current user
    if (members.isEmpty) {
      if (creatorProfile != null) {
        members.add({
          'user_id': creatorProfile['id'],
          'profiles': creatorProfile,
        });
      } else if (currentUserId != null) {
        final myProfile = await supabase
            .from('profiles')
            .select('id, username, avatar_url, school_name')
            .eq('id', currentUserId)
            .maybeSingle();

        if (myProfile != null) {
          members.add({
            'user_id': myProfile['id'],
            'profiles': Map<String, dynamic>.from(myProfile),
          });
        }
      }
    }

    final isMember = members.any(
      (m) => m['user_id'].toString() == currentUserId.toString(),
    );

    return {
      'members': members,
      'creator_profile': creatorProfile,
      'is_member': isMember,
      'creator_id': creatorId,
      'group_id_text': groupIdText,
    };
  }

  Future<void> _joinAndOpenGroup(Map<String, dynamic> group) async {
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in first.')),
      );
      return;
    }

    final chatIdRaw = group['id'];
    final chatId = chatIdRaw.toString();

    try {
      final existingMember = await supabase
          .from('chat_participants')
          .select('chat_id, user_id')
          .eq('chat_id', chatIdRaw)
          .eq('user_id', currentUserId)
          .maybeSingle();

      if (existingMember == null) {
        await supabase.from('chat_participants').insert({
          'chat_id': chatIdRaw,
          'user_id': currentUserId,
        });
      }

      if (!mounted) return;

      Navigator.pop(context);

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ChatRoomScreen(
            chatId: chatId,
            chatTitle: group['group_name'] ?? 'Group Chat',
            isGroup: true,
          ),
        ),
      );
    } catch (e) {
      debugPrint("Join/Open group error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not join group: $e')),
        );
      }
    }
  }

  Future<void> _showGroupPreview(Map<String, dynamic> group) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.82,
          minChildSize: 0.58,
          maxChildSize: 0.96,
          builder: (_, controller) {
            return FutureBuilder<Map<String, dynamic>>(
              future: _fetchGroupPreviewData(group),
              builder: (context, snapshot) {
                final groupName = group['group_name'] ?? 'Unknown Group';
                final groupAvatar = group['group_avatar'];
                final groupDescription =
                    group['group_description'] ?? 'No description provided.';
                final isPublic = group['is_public'] == true;

                final members = List<Map<String, dynamic>>.from(
                    snapshot.data?['members'] ?? []);
                final creatorProfile =
                    snapshot.data?['creator_profile'] as Map<String, dynamic>?;
                final isMember = snapshot.data?['is_member'] == true;

                return Container(
                  decoration: const BoxDecoration(
                    color: Color(0xFF111111),
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(24)),
                  ),
                  child: ListView(
                    controller: controller,
                    padding: const EdgeInsets.all(20),
                    children: [
                      Center(
                        child: Container(
                          width: 44,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                      const SizedBox(height: 18),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(18),
                            child: Container(
                              width: 84,
                              height: 84,
                              color: Colors.grey[900],
                              child: groupAvatar != null
                                  ? CachedNetworkImage(
                                      imageUrl: groupAvatar,
                                      fit: BoxFit.cover,
                                      placeholder: (context, url) =>
                                          Container(color: Colors.grey[850]),
                                      errorWidget: (context, url, error) =>
                                          const Icon(Icons.groups,
                                              color: Colors.white54, size: 34),
                                    )
                                  : const Icon(Icons.groups,
                                      color: Colors.white54, size: 34),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  groupName,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  isPublic ? 'Public Group' : 'Private Group',
                                  style: TextStyle(
                                    color: isPublic
                                        ? Colors.greenAccent
                                        : Colors.orangeAccent,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  groupDescription,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      if (creatorProfile != null) ...[
                        const Text(
                          'Creator',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 10),
                        _buildPersonRow(
                          avatarUrl: creatorProfile['avatar_url'],
                          username: creatorProfile['username'] ?? 'Creator',
                          schoolName: creatorProfile['school_name'],
                        ),
                        const SizedBox(height: 18),
                      ],
                      const Text(
                        'Members',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (snapshot.connectionState == ConnectionState.waiting)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 20),
                          child: Center(
                            child: CircularProgressIndicator(
                              color: Color(0xFF4CAF50),
                            ),
                          ),
                        )
                      else if (members.isEmpty)
                        const Text(
                          'No members found.',
                          style: TextStyle(color: Colors.white54),
                        )
                      else
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: members.length,
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: 0.72,
                          ),
                          itemBuilder: (context, index) {
                            final member = members[index];
                            final profile =
                                member['profiles'] as Map<String, dynamic>?;

                            return Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor: Colors.grey[800],
                                  backgroundImage:
                                      profile?['avatar_url'] != null
                                          ? CachedNetworkImageProvider(
                                              profile!['avatar_url'])
                                          : null,
                                  child: profile?['avatar_url'] == null
                                      ? Text(
                                          (profile?['username'] ?? 'U')
                                              .toString()[0]
                                              .toUpperCase(),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        )
                                      : null,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  profile?['username'] ?? 'User',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (profile?['school_name'] != null)
                                  Text(
                                    profile!['school_name'],
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 9,
                                    ),
                                  ),
                              ],
                            );
                          },
                        ),
                      const SizedBox(height: 22),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: snapshot.connectionState ==
                                  ConnectionState.waiting
                              ? null
                              : () => _joinAndOpenGroup(group),
                          icon: Icon(
                            isMember
                                ? Icons.chat_bubble_outline
                                : Icons.group_add,
                          ),
                          label: Text(isMember ? 'Open Group' : 'Join Group'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4CAF50),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildPersonRow({
    required String? avatarUrl,
    required String username,
    String? schoolName,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: Colors.grey[800],
            backgroundImage: avatarUrl != null
                ? CachedNetworkImageProvider(avatarUrl)
                : null,
            child: avatarUrl == null
                ? Text(
                    username.isNotEmpty ? username[0].toUpperCase() : 'U',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  username,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
                if (schoolName != null)
                  Text(
                    schoolName,
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupCard(Map<String, dynamic> group) {
    return GestureDetector(
      onTap: () => _showGroupPreview(group),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.blueGrey[900]!.withOpacity(0.5),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.blue.withOpacity(0.2), width: 1),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: Colors.blueGrey[800],
              ),
              clipBehavior: Clip.hardEdge,
              child: group['group_avatar'] != null
                  ? CachedNetworkImage(
                      imageUrl: group['group_avatar'],
                      fit: BoxFit.cover,
                      placeholder: (context, url) =>
                          Container(color: Colors.grey[800]),
                      errorWidget: (context, url, error) =>
                          const Icon(Icons.groups, color: Colors.white54),
                    )
                  : const Icon(Icons.groups, color: Colors.white, size: 26),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Text(
                group['group_name'] ?? 'Unknown Group',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
                maxLines: 1,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Text(
              'Group',
              style: TextStyle(color: Colors.blueAccent, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.explore_outlined, size: 60, color: Colors.grey[800]),
          const SizedBox(height: 16),
          Text(
            _selectedSegment == 0 ? "No people found" : "No groups found",
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
                fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          const Text("Try searching for something else",
              style: TextStyle(color: Colors.white38, fontSize: 13)),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: _fetchExploreData,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text("Refresh"),
            style:
                TextButton.styleFrom(foregroundColor: const Color(0xFF4CAF50)),
          )
        ],
      ),
    );
  }
}
