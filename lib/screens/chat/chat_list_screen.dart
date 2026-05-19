// lib/screens/chat/chat_list_screen.dart
import 'dart:async';
import 'package:allowance/screens/chat/chat_room_screen.dart';
import 'package:allowance/screens/chat/individual_chat_screen.dart';
import 'package:allowance/screens/chat/create_group_screen.dart';
import 'package:allowance/screens/chat/explore_screen.dart';
import 'package:allowance/screens/home/story_viewer_screen.dart';
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

  // --- Highly Optimized State Variables ---
  StreamSubscription? _participantsSub;
  StreamSubscription? _chatsSub;
  StreamSubscription? _followersSub;
  StreamSubscription? _allParticipantsSub;
  StreamSubscription? _unreadSub;

  List<Map<String, dynamic>> _chats = [];
  Set<String> _followingIds = {};
  List<Map<String, dynamic>> _allParticipants = [];
  List<Map<String, dynamic>> _unreadMessages = [];

  bool _isLoading = true;
  String? _myId;

  @override
  void initState() {
    super.initState();
    _myId = supabase.auth.currentUser?.id;
    if (_myId != null) {
      _setupStreams();
    }
  }

  // Set up streams ONCE so the app doesn't freeze when typing in search
  void _setupStreams() {
    final myId = _myId!;

    // 1. My participants
    _participantsSub = supabase
        .from('chat_participants')
        .stream(primaryKey: ['chat_id', 'user_id'])
        .eq('user_id', myId)
        .listen((records) {
          final myChatIds = records.map((p) => p['chat_id'] as Object).toList();

          if (myChatIds.isEmpty) {
            if (mounted) setState(() => _isLoading = false);
            return;
          }

          // 2. Chats (Using myChatIds)
          _chatsSub?.cancel();
          _chatsSub = supabase
              .from('chats')
              .stream(primaryKey: ['id'])
              .inFilter('id', myChatIds)
              .listen((chats) {
                _chats = chats;
                if (mounted) setState(() => _isLoading = false);
              });

          // 3. All Participants in those chats
          _allParticipantsSub?.cancel();
          _allParticipantsSub = supabase
              .from('chat_participants')
              .stream(primaryKey: ['chat_id', 'user_id'])
              .inFilter('chat_id', myChatIds)
              .listen((parts) {
                _allParticipants = parts;
                if (mounted) setState(() {});
              });
        });

    // 4. Followers (To determine Friends vs General)
    _followersSub = supabase
        .from('followers')
        .stream(primaryKey: ['follower_id', 'following_id'])
        .eq('follower_id', myId)
        .listen((folls) {
          _followingIds =
              folls.map((f) => f['following_id'].toString()).toSet();
          if (mounted) setState(() {});
        });

    // 5. Unread Messages Global Stream
    _unreadSub = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('is_read', false)
        .listen((msgs) {
          _unreadMessages = msgs;
          if (mounted) setState(() {});
        });
  }

  @override
  void dispose() {
    _participantsSub?.cancel();
    _chatsSub?.cancel();
    _followersSub?.cancel();
    _allParticipantsSub?.cancel();
    _unreadSub?.cancel();
    _searchController.dispose();
    super.dispose();
  }

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
              title: const Text('Explore',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              subtitle: const Text('Discover new users and public groups',
                  style: TextStyle(color: Colors.white54)),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => ExploreScreen(
                          userPreferences: widget.userPreferences)),
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
              title: const Text('Create Group',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              subtitle: const Text('Start a public or private community',
                  style: TextStyle(color: Colors.white54)),
              onTap: () {
                Navigator.pop(ctx);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => CreateGroupScreen(
                          userPreferences: widget.userPreferences)),
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
    if (_myId == null) {
      return const Scaffold(body: Center(child: Text("Please log in")));
    }

    if (_isLoading) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          elevation: 0,
          title: const Text('Messages',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        ),
        body: const Center(
            child: CircularProgressIndicator(color: Color(0xFF4CAF50))),
      );
    }

    // 1. Calculate Unread Counts per tab
    int friendsUnread = 0;
    int generalUnread = 0;
    int groupsUnread = 0;

    final unreadMsgs =
        _unreadMessages.where((m) => m['sender_id'] != _myId).toList();
    final unreadByChat = <String, int>{};
    for (var msg in unreadMsgs) {
      final cId = msg['chat_id'].toString();
      unreadByChat[cId] = (unreadByChat[cId] ?? 0) + 1;
    }

    for (var chat in _chats) {
      final chatIdStr = chat['id'].toString();
      final unreadCount = unreadByChat[chatIdStr] ?? 0;

      if (unreadCount > 0) {
        final isGroup = chat['is_group'] == true;
        if (isGroup) {
          groupsUnread += unreadCount;
        } else {
          final otherParticipant = _allParticipants.firstWhere(
            (p) =>
                p['chat_id'].toString() == chatIdStr && p['user_id'] != _myId,
            orElse: () => <String, dynamic>{},
          );
          if (otherParticipant.isNotEmpty) {
            final targetUserId = otherParticipant['user_id'].toString();
            if (_followingIds.contains(targetUserId)) {
              friendsUnread += unreadCount;
            } else {
              generalUnread += unreadCount;
            }
          }
        }
      }
    }

    // 2. Filter Chats based on Tab and Search
    final filteredChats = _chats.where((chat) {
      final isGroup = chat['is_group'] == true;
      final chatIdStr = chat['id'].toString();
      final chatName = (chat['name'] ?? '').toString().toLowerCase();
      final searchText = _searchController.text.toLowerCase();

      if (searchText.isNotEmpty && !chatName.contains(searchText)) return false;
      if (_selectedTabIndex == 2) return isGroup;
      if (isGroup) return false;

      final otherParticipant = _allParticipants.firstWhere(
        (p) => p['chat_id'].toString() == chatIdStr && p['user_id'] != _myId,
        orElse: () => <String, dynamic>{},
      );

      if (otherParticipant.isEmpty) return false;

      final targetUserId = otherParticipant['user_id'].toString();
      final isFollowing = _followingIds.contains(targetUserId);

      if (_selectedTabIndex == 0) return isFollowing;
      if (_selectedTabIndex == 1) return !isFollowing;

      return false;
    }).toList();

    // 3. WHATSAPP STYLE SORTING
    filteredChats.sort((a, b) {
      final aTime = DateTime.tryParse(a['updated_at']?.toString() ??
              a['created_at']?.toString() ??
              '') ??
          DateTime(0);
      final bTime = DateTime.tryParse(b['updated_at']?.toString() ??
              b['created_at']?.toString() ??
              '') ??
          DateTime(0);
      return bTime.compareTo(aTime); // Newest first
    });

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('Messages',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
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
                    0: _buildTabLabel('Friends', 0, friendsUnread),
                    1: _buildTabLabel('General', 1, generalUnread),
                    2: _buildTabLabel('Groups', 2, groupsUnread),
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
              child: filteredChats.isEmpty
                  ? _buildPlaceholder('No messages yet.')
                  : ListView.builder(
                      itemCount: filteredChats.length,
                      itemBuilder: (context, index) {
                        final chat = filteredChats[index];
                        return _ChatTile(
                          key: Key(chat['id'].toString()),
                          chat: chat,
                          myId: _myId!,
                          themeColor: themeColor,
                          userPreferences: widget.userPreferences,
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

  Widget _buildTabLabel(String text, int index, int unreadCount) {
    final isSelected = _selectedTabIndex == index;
    final displayText = unreadCount > 0 ? '$text ($unreadCount)' : text;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        displayText,
        style: TextStyle(
          color: isSelected ? Colors.white : Colors.white54,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }

  Widget _buildPlaceholder(String text) {
    return Center(
      child: Text(text,
          style: const TextStyle(color: Colors.white54, fontSize: 16)),
    );
  }
}

/// A dedicated widget for each chat row.
/// FIX: Moved its streams to initState to stop it from crashing the app!
class _ChatTile extends StatefulWidget {
  final Map<String, dynamic> chat;
  final String myId;
  final Color themeColor;
  final UserPreferences userPreferences;

  const _ChatTile({
    super.key,
    required this.chat,
    required this.myId,
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

  late final Stream<List<Map<String, dynamic>>> _messagesStream;
  late final Stream<List<Map<String, dynamic>>> _participantsStream;

  @override
  void initState() {
    super.initState();
    // Cache streams here so they don't rebuild infinitely
    _messagesStream = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('chat_id', widget.chat['id'])
        .order('created_at', ascending: false);

    _participantsStream = supabase.from('chat_participants').stream(
        primaryKey: ['chat_id', 'user_id']).eq('chat_id', widget.chat['id']);

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

      final profileData = await supabase
          .from('profiles')
          .select('username, avatar_url, school_name, subscription_tier')
          .eq('id', _targetUserId)
          .maybeSingle();

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
            'is_plus': profileData?['subscription_tier'] == 'Membership',
            'has_story': storyCheck.isNotEmpty,
          };
          _isLoadingMeta = false;
        });
      }
    } catch (e) {
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

  Future<void> _openStory() async {
    if (_targetUserId.isEmpty) return;
    final response = await supabase
        .from('stories')
        .select(
            'id, media_url, media_type, caption, url, expires_at, created_at, likes_count, profiles:user_id(username, avatar_url)')
        .eq('user_id', _targetUserId)
        .gt('expires_at', DateTime.now().toUtc().toIso8601String())
        .order('created_at', ascending: true);

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
    final chatId = widget.chat['id'];
    final hasStory = _metaData?['has_story'] == true;
    final isPlus = _metaData?['is_plus'] == true;

    final dynamic isGroupRaw = widget.chat['is_group'];
    final bool isGroup = isGroupRaw == true ||
        isGroupRaw == 1 ||
        isGroupRaw.toString() == 'true';

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _messagesStream,
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
          stream: _participantsStream,
          builder: (context, partSnapshot) {
            final participants = partSnapshot.data ?? [];
            bool isTyping = participants.any(
                (p) => p['user_id'] != widget.myId && p['is_typing'] == true);

            final myParticipant = participants.firstWhere(
              (p) => p['user_id'] == widget.myId,
              orElse: () => <String, dynamic>{},
            );
            final bool localIsAdmin = myParticipant['role'] == 'admin' ||
                myParticipant['is_admin'] == true;

            return ListTile(
              onTap: () {
                if (isGroup) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => ChatRoomScreen(
                        chatId: chatId,
                        chatTitle: title,
                        isAdmin: localIsAdmin,
                        userPreferences: widget.userPreferences,
                        isGroup: true,
                        creatorId: widget.chat['creator_id']?.toString(),
                      ),
                    ),
                  );
                } else {
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
                          'is_group': false,
                        },
                        userPreferences: widget.userPreferences,
                      ),
                    ),
                  );
                }
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
                          border:
                              Border.all(color: widget.themeColor, width: 2),
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
                          const Icon(Icons.star, color: Colors.amber, size: 16),
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
