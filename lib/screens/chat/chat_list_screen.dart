// lib/screens/chat/chat_list_screen.dart
import 'package:allowance/screens/chat/individual_chat_screen.dart';
import 'package:allowance/screens/chat/create_group_screen.dart';
import 'package:allowance/screens/chat/explore_screen.dart';
import 'package:allowance/screens/home/story_viewer_screen.dart'; // Added for Stories
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../models/user_preferences.dart';

class ChatListScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  const ChatListScreen({super.key, required this.userPreferences});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  final Color themeColor = const Color(0xFF4CAF50);
  int _selectedTabIndex = 0; // 0: Friends, 1: General, 2: Groups
  final TextEditingController _searchController = TextEditingController();
  final supabase = Supabase.instance.client;

  void _showPlusMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.blueAccent.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.explore, color: Colors.blueAccent),
              ),
              title: const Text(
                'Explore',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold),
              ),
              subtitle: const Text('Discover new users and public groups',
                  style: TextStyle(color: Colors.white54)),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        ExploreScreen(userPreferences: widget.userPreferences),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            ListTile(
              leading: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: themeColor.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.group_add, color: themeColor),
              ),
              title: const Text(
                'Create Group',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold),
              ),
              subtitle: const Text('Start a public or private community',
                  style: TextStyle(color: Colors.white54)),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => CreateGroupScreen(
                        userPreferences: widget.userPreferences),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myId = supabase.auth.currentUser?.id;

    if (myId == null) {
      return const Scaffold(body: Center(child: Text("Please log in")));
    }

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text(
          'Messages',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        centerTitle: false,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: CupertinoSearchTextField(
                controller: _searchController,
                backgroundColor: Colors.grey[900],
                style: const TextStyle(color: Colors.white),
                placeholderStyle: const TextStyle(color: Colors.white54),
                placeholder: 'Search chats, friends, or groups...',
                onChanged: (value) => setState(() {}),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: SizedBox(
                width: double.infinity,
                child: CupertinoSlidingSegmentedControl<int>(
                  backgroundColor: Colors.grey[900]!,
                  thumbColor: Colors.grey[700]!,
                  groupValue: _selectedTabIndex,
                  children: {
                    0: _buildTabLabel('Friends', 0),
                    1: _buildTabLabel('General', 1),
                    2: _buildTabLabel('Groups', 2),
                  },
                  onValueChanged: (int? value) {
                    if (value != null) {
                      setState(() => _selectedTabIndex = value);
                    }
                  },
                ),
              ),
            ),
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: supabase.from('chat_participants').stream(
                  primaryKey: ['chat_id', 'user_id'],
                ).eq('user_id', myId),
                builder: (context, participantSnapshot) {
                  if (participantSnapshot.connectionState ==
                      ConnectionState.waiting) {
                    return const Center(
                      child: CircularProgressIndicator(
                        color: Color(0xFF4CAF50),
                      ),
                    );
                  }

                  final participantRecords = participantSnapshot.data ?? [];
                  if (participantRecords.isEmpty) {
                    return _buildPlaceholder('No messages yet.');
                  }

                  final List<Object> myChatIds = participantRecords
                      .map((p) => p['chat_id'] as Object)
                      .toList();

                  return StreamBuilder<List<Map<String, dynamic>>>(
                    stream: supabase
                        .from('chats')
                        .stream(primaryKey: ['id'])
                        .inFilter('id', myChatIds)
                        .order('updated_at', ascending: false),
                    builder: (context, chatSnapshot) {
                      if (!chatSnapshot.hasData) {
                        return const Center(
                          child: CircularProgressIndicator(
                            color: Color(0xFF4CAF50),
                          ),
                        );
                      }

                      return StreamBuilder<List<Map<String, dynamic>>>(
                        stream: supabase.from('followers').stream(primaryKey: [
                          'follower_id',
                          'following_id'
                        ]).eq('follower_id', myId),
                        builder: (context, followerSnapshot) {
                          if (!followerSnapshot.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(
                                color: Color(0xFF4CAF50),
                              ),
                            );
                          }

                          final followingIds = followerSnapshot.data!
                              .map((f) => f['following_id'].toString())
                              .toSet();

                          return StreamBuilder<List<Map<String, dynamic>>>(
                            stream: supabase.from('chat_participants').stream(
                              primaryKey: ['chat_id', 'user_id'],
                            ).inFilter('chat_id', myChatIds),
                            builder: (context, allParticipantsSnapshot) {
                              if (!allParticipantsSnapshot.hasData) {
                                return const Center(
                                  child: CircularProgressIndicator(
                                    color: Color(0xFF4CAF50),
                                  ),
                                );
                              }

                              final allParticipants =
                                  allParticipantsSnapshot.data!;

                              final filteredChats =
                                  chatSnapshot.data!.where((chat) {
                                final isGroup = chat['is_group'] == true;
                                final chatIdStr = chat['id'].toString();
                                final chatName = (chat['name'] ?? '')
                                    .toString()
                                    .toLowerCase();
                                final searchText =
                                    _searchController.text.toLowerCase();

                                if (searchText.isNotEmpty &&
                                    !chatName.contains(searchText)) {
                                  return false;
                                }

                                if (_selectedTabIndex == 2) return isGroup;
                                if (isGroup) return false;

                                final otherParticipant =
                                    allParticipants.firstWhere(
                                  (p) =>
                                      p['chat_id'].toString() == chatIdStr &&
                                      p['user_id'] != myId,
                                  orElse: () => <String, dynamic>{},
                                );

                                if (otherParticipant.isEmpty) return false;

                                final targetUserId =
                                    otherParticipant['user_id'].toString();
                                final isFollowing =
                                    followingIds.contains(targetUserId);

                                if (_selectedTabIndex == 0) return isFollowing;
                                if (_selectedTabIndex == 1) return !isFollowing;

                                return false;
                              }).toList();

                              filteredChats.sort((a, b) {
                                final aTime = DateTime.tryParse(
                                        (a['updated_at'] ?? '').toString()) ??
                                    DateTime.fromMillisecondsSinceEpoch(0);
                                final bTime = DateTime.tryParse(
                                        (b['updated_at'] ?? '').toString()) ??
                                    DateTime.fromMillisecondsSinceEpoch(0);
                                return bTime.compareTo(aTime);
                              });

                              if (filteredChats.isEmpty) {
                                return _buildPlaceholder('No messages yet.');
                              }

                              return ListView.builder(
                                itemCount: filteredChats.length,
                                itemBuilder: (context, index) {
                                  final chat = filteredChats[index];
                                  return _ChatTile(
                                    key: Key(chat['id'].toString()),
                                    chat: chat,
                                    myId: myId,
                                    tabIndex: _selectedTabIndex,
                                    themeColor: themeColor,
                                    userPreferences: widget.userPreferences,
                                  );
                                },
                              );
                            },
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: themeColor,
        onPressed: _showPlusMenu,
        child: const Icon(Icons.add, color: Colors.white, size: 32),
      ),
    );
  }

  Widget _buildTabLabel(String text, int index) {
    final isSelected = _selectedTabIndex == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        text,
        style: TextStyle(
          color: isSelected ? Colors.white : Colors.white54,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }

  Widget _buildPlaceholder(String text) {
    return Center(
      child: Text(
        text,
        style: const TextStyle(color: Colors.white54, fontSize: 16),
      ),
    );
  }
}

/// A dedicated widget for each chat row to handle its own real-time streams and metadata
class _ChatTile extends StatefulWidget {
  final Map<String, dynamic> chat;
  final String myId;
  final int tabIndex;
  final Color themeColor;
  final UserPreferences userPreferences;

  const _ChatTile({
    super.key,
    required this.chat,
    required this.myId,
    required this.tabIndex,
    required this.themeColor,
    required this.userPreferences,
  });

  @override
  State<_ChatTile> createState() => _ChatTileState();
}

class _ChatTileState extends State<_ChatTile> {
  final supabase = Supabase.instance.client;
  Map<String, dynamic>? _metaData;
  bool _isLoadingMeta = true;
  String _targetUserId = '';

  @override
  void initState() {
    super.initState();
    _fetchMetaData();
  }

  Future<void> _fetchMetaData() async {
    try {
      if (widget.chat['is_group'] == true) {
        if (mounted) {
          setState(() {
            _metaData = {
              'title': widget.chat['group_name'] ?? "Group Chat",
              'avatar_url': widget.chat['group_avatar'],
              'is_plus': false,
              'has_story': false,
            };
            _isLoadingMeta = false;
          });
        }
        return;
      }

      // 1. Get the other participant's user_id
      final participantData = await supabase
          .from('chat_participants')
          .select('user_id')
          .eq('chat_id', widget.chat['id'])
          .neq('user_id', widget.myId)
          .maybeSingle();

      if (participantData == null) {
        if (mounted) {
          setState(() {
            _metaData = {
              'title': "Unknown User",
              'avatar_url': null,
              'is_plus': false,
              'has_story': false
            };
            _isLoadingMeta = false;
          });
        }
        return;
      }

      _targetUserId = participantData['user_id'] ?? '';

      // 2. Fetch profile (checking subscription_tier for the star)
      final profileData = await supabase
          .from('profiles')
          .select('username, avatar_url, school_name, subscription_tier')
          .eq('id', _targetUserId)
          .maybeSingle();

      // 3. Check for active stories (created in last 24 hours)
      final DateTime yesterday =
          DateTime.now().subtract(const Duration(hours: 24));
      final storyCheck = await supabase
          .from('stories')
          .select('id')
          .eq('user_id', _targetUserId)
          .gte('created_at', yesterday.toIso8601String())
          .limit(1);

      if (mounted) {
        setState(() {
          _metaData = {
            'title': profileData?['username'] ?? "User",
            'avatar_url': profileData?['avatar_url'],
            'school_name': profileData?['school_name'],
            'is_plus': profileData?['subscription_tier'] ==
                'plus', // Check for Plus status
            'has_story':
                storyCheck.isNotEmpty, // Check if they have an active story
          };
          _isLoadingMeta = false;
        });
      }
    } catch (e) {
      debugPrint("Error fetching chat metadata: $e");
      if (mounted) {
        setState(() {
          _metaData = {
            'title': "Chat",
            'avatar_url': null,
            'is_plus': false,
            'has_story': false
          };
          _isLoadingMeta = false;
        });
      }
    }
  }

  // FIX: Stories now start from the first posted (Oldest to Newest)
  Future<void> _openStory() async {
    if (_targetUserId.isEmpty) return;
    final response = await supabase
        .from('stories')
        .select(
            'id, media_url, media_type, caption, url, expires_at, created_at, likes_count, profiles:user_id(username, avatar_url)')
        .eq('user_id', _targetUserId)
        .gt('expires_at', DateTime.now().toUtc().toIso8601String())
        .order('created_at', ascending: true); // CHANGED TO TRUE

    final stories = response as List<dynamic>;

    if (stories.isNotEmpty && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => StoryViewerScreen(
            stories: stories,
            initialIndex: 0,
            userPreferences: widget.userPreferences,
          ),
        ),
      );
    }
  }

  String _formatTime(String? timestamp) {
    if (timestamp == null) return "";
    try {
      DateTime date = DateTime.parse(timestamp).toLocal();
      if (DateTime.now().difference(date).inDays == 0) {
        return DateFormat('h:mm a').format(date);
      } else {
        return DateFormat('MMM d').format(date);
      }
    } catch (e) {
      return "";
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoadingMeta) {
      return ListTile(
        leading: CircleAvatar(radius: 28, backgroundColor: Colors.grey[900]),
        title: Container(
            height: 12,
            width: 100,
            decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(4))),
        subtitle: Container(
            height: 10,
            width: 150,
            decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(4))),
      );
    }

    final title = _metaData?['title'] ?? "Chat";
    final avatarUrl = _metaData?['avatar_url'];
    final isGroup = widget.chat['is_group'] == true;
    final chatId = widget.chat['id'];
    final hasStory = _metaData?['has_story'] == true;
    final isPlus = _metaData?['is_plus'] == true;

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: supabase
          .from('messages')
          .stream(primaryKey: ['id'])
          .eq('chat_id', chatId)
          .order('created_at', ascending: false),
      builder: (context, msgSnapshot) {
        final messages = msgSnapshot.data ?? [];
        int unreadCount = messages
            .where(
                (m) => m['is_read'] == false && m['sender_id'] != widget.myId)
            .length;
        String lastMessage = messages.isNotEmpty
            ? (messages.first['content'] ?? '📷 Media')
            : "Tap to chat";
        String lastMessageTime = messages.isNotEmpty
            ? _formatTime(messages.first['created_at'])
            : '';

        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: supabase
              .from('chat_participants')
              .stream(primaryKey: ['chat_id', 'user_id']).eq('chat_id', chatId),
          builder: (context, partSnapshot) {
            final participants = partSnapshot.data ?? [];
            bool isTyping = participants.any(
                (p) => p['user_id'] != widget.myId && p['is_typing'] == true);

            return ListTile(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => IndividualChatScreen(
                      chatId: chatId,
                      recipientProfile: {
                        'id': _targetUserId,
                        'username': title,
                        'avatar_url': avatarUrl,
                        'school_name': _metaData?['school_name'],
                        'is_group': isGroup,
                      },
                    ),
                  ),
                );
              },
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: GestureDetector(
                onTap: (isGroup || !hasStory) ? null : _openStory,
                child: Container(
                  padding:
                      hasStory ? const EdgeInsets.all(2.5) : EdgeInsets.zero,
                  decoration: hasStory
                      ? BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: widget.themeColor,
                              width: 2), // The Story Ring
                        )
                      : null,
                  child: CircleAvatar(
                    radius: 28,
                    backgroundColor: Colors.grey[900],
                    backgroundImage:
                        avatarUrl != null ? NetworkImage(avatarUrl) : null,
                    child: avatarUrl == null
                        ? Icon(isGroup ? Icons.group : Icons.person,
                            color: widget.themeColor)
                        : null,
                  ),
                ),
              ),
              title: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 16),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (isPlus) ...[
                          const SizedBox(width: 4),
                          const Icon(Icons.stars,
                              color: Colors.amber, size: 16), // The Plus Star
                        ],
                      ],
                    ),
                  ),
                  Text(
                    isTyping ? "typing..." : lastMessageTime,
                    style: TextStyle(
                        color: isTyping ? widget.themeColor : Colors.white54,
                        fontSize: 12),
                  ),
                ],
              ),
              subtitle: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_metaData?['school_name'] != null && !isGroup)
                          Text(_metaData!['school_name'],
                              style: TextStyle(
                                  color: widget.themeColor.withOpacity(0.7),
                                  fontSize: 12)),
                        Text(
                          isTyping ? "typing..." : lastMessage,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color:
                                  isTyping ? widget.themeColor : Colors.white54,
                              fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  if (unreadCount > 0)
                    Container(
                      padding: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                          color: widget.themeColor, shape: BoxShape.circle),
                      child: Text(unreadCount.toString(),
                          style: const TextStyle(
                              color: Colors.black,
                              fontSize: 10,
                              fontWeight: FontWeight.bold)),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}
