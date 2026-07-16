// lib/screens/chat/chat_list_screen.dart
import 'dart:async';
import 'dart:convert';
import 'package:allowance/screens/chat/chat_room_screen.dart';
import 'package:allowance/screens/chat/individual_chat_screen.dart';
import 'package:allowance/screens/home/story_viewer_screen.dart';
import 'package:allowance/shared/services/chat_sync_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import '../../models/user_preferences.dart';

class ChatListScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  const ChatListScreen({super.key, required this.userPreferences});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  // <-- ADD MIXIN
  final Color themeColor = const Color(0xFF4CAF50);
  int _selectedTabIndex = 0; // 0: Friends, 1: General, 2: Groups
  final TextEditingController _searchController = TextEditingController();
  final supabase = Supabase.instance.client;

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
  late PageController _pageController; // <--- ADD THIS
  bool _isDisposed = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _pageController = PageController(initialPage: _selectedTabIndex);
    _myId = supabase.auth.currentUser?.id;

    if (_myId != null) {
      supabase
          .from('chat_participants')
          .update({'is_typing': false})
          .eq('user_id', _myId!)
          .catchError((_) {});

      _loadCachedData();
      _setupStreams();

      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted && !_isDisposed && _isLoading) {
          setState(() => _isLoading = false);
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _myId != null && !_isDisposed) {
      _fetchLatestData();
      _setupStreams();
    }
  }

  Future<void> _handleRefresh() async {
    _setupStreams(); // Re-trigger the backend fetch silently
    await Future.delayed(
        const Duration(seconds: 1)); // UX delay to show the spinner
  }

  Future<void> _loadCachedData() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedChats = prefs.getString('cached_chats_$_myId');
    final cachedParts = prefs.getString('cached_parts_$_myId');
    final cachedFolls = prefs.getString('cached_folls_$_myId');
    final cachedUnread = prefs.getString('cached_unread_$_myId');

    if (cachedChats != null && cachedParts != null) {
      try {
        if (mounted) {
          setState(() {
            _chats = List<Map<String, dynamic>>.from(jsonDecode(cachedChats));
            _allParticipants =
                List<Map<String, dynamic>>.from(jsonDecode(cachedParts));
            if (cachedFolls != null) {
              _followingIds = Set<String>.from(jsonDecode(cachedFolls));
            }
            if (cachedUnread != null) {
              _unreadMessages =
                  List<Map<String, dynamic>>.from(jsonDecode(cachedUnread));
            }
            _isLoading = false; // Instantly hides spinner!
          });
        }
      } catch (e) {
        debugPrint('Cache parsing error: $e');
      }
    }
  }

  // Set up streams ONCE so the app doesn't freeze when typing in search
  void _setupStreams() {
    if (_isDisposed) return;

    // 1. Fetch initial data instantly
    _fetchLatestData();

    final myId = _myId!;
    if (myId.isEmpty) return;

    // 2. Real-time Unread Messages Stream
    _unreadSub?.cancel();
    _unreadSub = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('is_read', false)
        .listen((msgs) {
          if (!mounted || _isDisposed) return;
          setState(() => _unreadMessages = msgs);
        });

    // 3. Real-time Followers Stream
    _followersSub?.cancel();
    _followersSub = supabase
        .from('followers')
        .stream(primaryKey: ['follower_id', 'following_id'])
        .eq('follower_id', myId)
        .listen((folls) async {
          if (!mounted || _isDisposed) return;
          setState(() {
            _followingIds =
                folls.map((f) => f['following_id'].toString()).toSet();
          });
          final prefs = await SharedPreferences.getInstance();
          prefs.setString(
              'cached_folls_$myId', jsonEncode(_followingIds.toList()));
        });

    // 4. Real-time Chat & Participants Stream
    _participantsSub?.cancel();
    _participantsSub = supabase
        .from('chat_participants')
        .stream(primaryKey: ['chat_id', 'user_id'])
        .eq('user_id', myId)
        .listen((records) {
          if (!mounted || _isDisposed) return;

          final myChatIds = records.map((p) => p['chat_id'] as Object).toList();
          if (myChatIds.isEmpty) return;

          _chatsSub?.cancel();
          _chatsSub = supabase
              .from('chats')
              .stream(primaryKey: ['id'])
              .inFilter('id', myChatIds)
              .listen((chats) {
                if (!mounted || _isDisposed) return;
                setState(() => _chats = chats);
              });

          _allParticipantsSub?.cancel();
          _allParticipantsSub = supabase
              .from('chat_participants')
              .stream(primaryKey: ['chat_id', 'user_id'])
              .inFilter('chat_id', myChatIds)
              .listen((parts) {
                if (!mounted || _isDisposed) return;
                setState(() => _allParticipants = parts);
              });
        });
  }

  // --- ⚡ LIGHTNING FAST PARALLEL FETCH ---
  Future<void> _fetchLatestData() async {
    final myId = _myId!;
    try {
      final myParts = await supabase
          .from('chat_participants')
          .select('chat_id')
          .eq('user_id', myId);
      final myChatIds = (myParts as List).map((p) => p['chat_id']).toList();

      if (myChatIds.isEmpty) {
        if (mounted && !_isDisposed) setState(() => _isLoading = false);
        return;
      }

      final futures = await Future.wait([
        supabase.from('chats').select().inFilter('id', myChatIds),
        supabase
            .from('chat_participants')
            .select()
            .inFilter('chat_id', myChatIds),
        supabase
            .from('followers')
            .select('following_id')
            .eq('follower_id', myId),
        supabase
            .from('messages')
            .select()
            .eq('is_read', false)
            .neq('sender_id', myId),
      ]);

      if (mounted && !_isDisposed) {
        setState(() {
          _chats = List<Map<String, dynamic>>.from(futures[0]);
          _allParticipants = List<Map<String, dynamic>>.from(futures[1]);
          _followingIds = (futures[2] as List)
              .map((f) => f['following_id'].toString())
              .toSet();

          final allUnread = List<Map<String, dynamic>>.from(futures[3]);
          _unreadMessages =
              allUnread.where((m) => myChatIds.contains(m['chat_id'])).toList();

          _isLoading = false;
        });
      }

      final prefs = await SharedPreferences.getInstance();
      prefs.setString('cached_chats_$myId', jsonEncode(_chats));
      prefs.setString('cached_parts_$myId', jsonEncode(_allParticipants));
      prefs.setString('cached_folls_$myId', jsonEncode(_followingIds.toList()));
      prefs.setString('cached_unread_$myId', jsonEncode(_unreadMessages));
    } catch (e) {
      debugPrint("Chat list fetch error: $e");
    }
  }

  @override
  void dispose() {
    _isDisposed = true;

    WidgetsBinding.instance.removeObserver(this);

    // Cancel ALL subscriptions and NULL them
    _participantsSub?.cancel();
    _participantsSub = null;
    _chatsSub?.cancel();
    _chatsSub = null;
    _followersSub?.cancel();
    _followersSub = null;
    _allParticipantsSub?.cancel();
    _allParticipantsSub = null;
    _unreadSub?.cancel();
    _unreadSub = null;

    _pageController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_myId == null) {
      return const Scaffold(body: Center(child: Text("Please log in")));
    }

    if (_isLoading) {
      return Scaffold(
        backgroundColor: Color(0xFF121212),
        appBar: AppBar(
          backgroundColor: Color(0xFF121212),
          elevation: 0,
          centerTitle: true,
          iconTheme: const IconThemeData(color: Colors.white),
          title: Image.asset(
            'assets/images/chats.png', // <--- Your custom Chats PNG
            height: 130,
            fit: BoxFit.contain,
          ),
        ),
        body: const Center(
            child: CircularProgressIndicator(color: Color(0xFF4CAF50))),
      );
    }

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

    return Scaffold(
      backgroundColor: const Color(0xFF121212), // <-- OFFICIAL BG
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212), // <-- OFFICIAL BG
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Image.asset('assets/images/chats.png',
            height: 100, fit: BoxFit.contain),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: CupertinoSearchTextField(
                controller: _searchController,
                backgroundColor:
                    const Color(0xFF1E1E1E), // <-- FIX: Visible Card Color
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
                  backgroundColor:
                      const Color(0xFF1E1E1E), // <-- FIX: Visible Card Color
                  thumbColor: const Color(0xFF2A2A2A),
                  groupValue: _selectedTabIndex,
                  children: {
                    0: _buildTabLabel('Friends', 0, friendsUnread),
                    1: _buildTabLabel('General', 1, generalUnread),
                    2: _buildTabLabel('Groups', 2, groupsUnread),
                  },
                  onValueChanged: (int? value) {
                    if (value != null) {
                      setState(() => _selectedTabIndex = value);
                      _pageController.animateToPage(value,
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut);
                    }
                  },
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (index) {
                  setState(() => _selectedTabIndex = index);
                },
                children: [
                  _buildChatListForTab(0),
                  _buildChatListForTab(1),
                  _buildChatListForTab(2),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatListForTab(int tabIndex) {
    final searchText = _searchController.text.toLowerCase();

    final filteredChats = _chats.where((chat) {
      final isGroup = chat['is_group'] == true;
      final chatIdStr = chat['id'].toString();

      if (tabIndex == 2) {
        if (!isGroup) return false;
        final chatName =
            (chat['group_name'] ?? chat['name'] ?? '').toString().toLowerCase();
        if (searchText.isNotEmpty && !chatName.contains(searchText))
          return false;
        return true;
      }

      if (isGroup) return false;

      final otherParticipant = _allParticipants.firstWhere(
        (p) => p['chat_id'].toString() == chatIdStr && p['user_id'] != _myId,
        orElse: () => <String, dynamic>{},
      );

      if (otherParticipant.isEmpty) return false;

      final targetUserId = otherParticipant['user_id'].toString();
      final isFollowing = _followingIds.contains(targetUserId);

      if (tabIndex == 0) return isFollowing;
      if (tabIndex == 1) return !isFollowing;

      return false;
    }).toList();

    filteredChats.sort((a, b) {
      final aTime = DateTime.tryParse(a['updated_at']?.toString() ??
              a['created_at']?.toString() ??
              '') ??
          DateTime(0);
      final bTime = DateTime.tryParse(b['updated_at']?.toString() ??
              b['created_at']?.toString() ??
              '') ??
          DateTime(0);
      return bTime.compareTo(aTime);
    });

    // --- NEW: Calculate unread counts globally so tiles don't have to! ---
    final unreadByChat = <String, int>{};
    for (var msg in _unreadMessages.where((m) => m['sender_id'] != _myId)) {
      final cId = msg['chat_id'].toString();
      unreadByChat[cId] = (unreadByChat[cId] ?? 0) + 1;
    }

    final seriousByChat = <String, int>{};
    for (var msg in _unreadMessages.where((m) => m['sender_id'] != _myId)) {
      final cId = msg['chat_id'].toString();
      final s = msg['seriousness'] as int? ?? 0;
      if (s > (seriousByChat[cId] ?? 0)) seriousByChat[cId] = s;
    }

    return RefreshIndicator(
      color: themeColor,
      onRefresh: _handleRefresh,
      child: filteredChats.isEmpty
          ? ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                SizedBox(height: MediaQuery.of(context).size.height * 0.3),
                _buildPlaceholder('No messages yet.'),
              ],
            )
          : ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: filteredChats.length,
              itemBuilder: (context, index) {
                final chat = filteredChats[index];
                final chatIdStr = chat['id'].toString();

                String targetUserId = '';
                if (chat['is_group'] != true) {
                  final otherP = _allParticipants.firstWhere(
                    (p) =>
                        p['chat_id'].toString() == chatIdStr &&
                        p['user_id'] != _myId,
                    orElse: () => <String, dynamic>{},
                  );
                  targetUserId =
                      otherP.isNotEmpty ? otherP['user_id'].toString() : '';
                }

                // Global data passed down
                final unreadCount = unreadByChat[chatIdStr] ?? 0;
                final String myUsername =
                    widget.userPreferences.username?.toLowerCase() ?? '';
                final hasMention = unreadCount > 0 &&
                    _unreadMessages.any((m) =>
                        m['chat_id'].toString() == chatIdStr &&
                        m['content']
                            .toString()
                            .toLowerCase()
                            .contains('@$myUsername'));
                final chatParts = _allParticipants
                    .where((p) => p['chat_id'].toString() == chatIdStr)
                    .toList();
                final isTyping = chatParts.any(
                    (p) => p['user_id'] != _myId && p['is_typing'] == true);
                final myPart = chatParts.firstWhere(
                    (p) => p['user_id'] == _myId,
                    orElse: () => <String, dynamic>{});
                final amIAdmin =
                    myPart['role'] == 'admin' || myPart['is_admin'] == true;

                return RepaintBoundary(
                    child: _ChatTile(
                  key: ValueKey(chatIdStr),
                  chat: chat,
                  myId: _myId!,
                  themeColor: themeColor,
                  userPreferences: widget.userPreferences,
                  searchQuery: searchText,
                  targetUserId: targetUserId,
                  unreadCount: unreadCount,
                  isTyping: isTyping,
                  amIAdmin: amIAdmin,
                  hasMention: hasMention,
                  onClearUnread: _clearUnreadForChat,
                  seriousness: seriousByChat[chatIdStr] ?? 0,
                ));
              },
            ),
    );
  }

  // 🔥 PASTE IT HERE: Inside _ChatListScreenState
  void _clearUnreadForChat(String chatIdStr) {
    if (!mounted) return;
    setState(() {
      _unreadMessages.removeWhere((m) => m['chat_id'].toString() == chatIdStr);
    });

    // Fire and forget update to the DB to ensure ghost messages are marked read
    supabase
        .from('messages')
        .update({'is_read': true})
        .match({'chat_id': chatIdStr, 'is_read': false})
        .neq('sender_id', _myId!)
        .catchError((_) {});
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
class _ChatTile extends StatefulWidget {
  final Map<String, dynamic> chat;
  final String myId;
  final Color themeColor;
  final UserPreferences userPreferences;
  final String searchQuery;
  final String targetUserId;
  final int unreadCount;
  final bool isTyping;
  final bool amIAdmin;
  final bool hasMention;
  final Function(String) onClearUnread;
  final int seriousness;

  const _ChatTile({
    super.key,
    required this.chat,
    required this.myId,
    required this.themeColor,
    required this.userPreferences,
    required this.targetUserId,
    required this.unreadCount,
    required this.isTyping,
    required this.amIAdmin,
    required this.onClearUnread,
    this.searchQuery = '',
    this.hasMention = false,
    this.seriousness = 0,
  });

  @override
  State<_ChatTile> createState() => _ChatTileState();
}

class _ChatTileState extends State<_ChatTile> {
  final supabase = Supabase.instance.client;
  Map<String, dynamic>? _metaData;
  bool _isLoadingMeta = true;

  // 🔥 NEW: Auto-clearing typing timer
  bool _localIsTyping = false;
  Timer? _typingClearTimer;
  String _lastMessageFallback = '';
  bool _hasLastMessageFallback = false;
  bool _isDisposed = false;

  @override
  void initState() {
    super.initState();
    _fetchMetaData();
    _fetchLastMessage();
    _handleTypingProp(widget.isTyping);
  }

  // 🔥 NEW: Fetches the real last message when the chat row cache is empty
  Future<void> _fetchLastMessage() async {
    final cached = widget.chat['last_message']?.toString() ?? '';
    if (cached.isNotEmpty) {
      if (mounted && !_isDisposed) {
        setState(() {
          _hasLastMessageFallback = true;
          _lastMessageFallback = cached;
        });
      }
      return;
    }

    try {
      final msg = await supabase
          .from('messages')
          .select('content, media_type')
          .eq('chat_id', widget.chat['id'])
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (mounted && !_isDisposed && msg != null) {
        final content = msg['content']?.toString() ?? '';
        final mType = msg['media_type']?.toString() ?? '';

        String text = content;
        if (text.isEmpty) {
          if (mType == 'image' || mType == 'video')
            text = '📷 Media';
          else if (mType.startsWith('view_once'))
            text = '📷 View once message';
          else if (mType == 'sticker')
            text = '🎭 Sticker';
          else if (mType == 'audio')
            text = '🎤 Voice message';
          else if (mType == 'file')
            text = '📎 File';
          else if (mType == 'order')
            text = '🛒 Order';
          else if (mType == 'event')
            text = '📅 Event';
          else if (mType == 'poll')
            text = '📊 Poll';
          else
            text = 'Tap to chat';
        }

        setState(() {
          _lastMessageFallback = text;
          _hasLastMessageFallback = true;
        });
      } else if (mounted && !_isDisposed) {
        setState(() => _hasLastMessageFallback = true);
      }
    } catch (_) {
      if (mounted && !_isDisposed)
        setState(() => _hasLastMessageFallback = true);
    }
  }

  // 🔥 NEW: Listens for changes from the database stream
  @override
  void didUpdateWidget(_ChatTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isTyping != oldWidget.isTyping) {
      _handleTypingProp(widget.isTyping);
    }
  }

  // 🔥 NEW: Kills the typing indicator after 4 seconds automatically!
  void _handleTypingProp(bool isTyping) {
    if (_isDisposed) return;

    if (isTyping) {
      if (mounted) setState(() => _localIsTyping = true);
      _typingClearTimer?.cancel();
      _typingClearTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && !_isDisposed) {
          setState(() => _localIsTyping = false);
        }
      });
    } else {
      _typingClearTimer?.cancel();
      if (_localIsTyping && mounted && !_isDisposed) {
        setState(() => _localIsTyping = false);
      }
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _typingClearTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchMetaData() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedMeta = prefs
        .getString('profile_cache_${widget.targetUserId}_${widget.chat['id']}');

    if (mounted && !_isDisposed) {
      if (cachedMeta != null) _metaData = jsonDecode(cachedMeta);
      if (_metaData != null) setState(() => _isLoadingMeta = false);
    }

    try {
      if (widget.chat['is_group'] == true) {
        final newMeta = {
          'title':
              widget.chat['group_name'] ?? widget.chat['name'] ?? "Group Chat",
          'avatar_url': widget.chat['group_avatar'],
          'is_plus': false,
          'has_story': false,
        };
        prefs.setString(
            'profile_cache_${widget.targetUserId}_${widget.chat['id']}',
            jsonEncode(newMeta));
        if (mounted && !_isDisposed) {
          setState(() {
            _metaData = newMeta;
            _isLoadingMeta = false;
          });
        }
        return;
      }

      if (widget.targetUserId.isEmpty) {
        if (mounted && !_isDisposed) setState(() => _isLoadingMeta = false);
        return;
      }

      final profileData = await supabase
          .from('profiles')
          .select('username, avatar_url, school_name, subscription_tier')
          .eq('id', widget.targetUserId)
          .maybeSingle();

      final storyCheck = await supabase
          .from('stories')
          .select('id')
          .eq('user_id', widget.targetUserId)
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .limit(1);

      final newMeta = {
        'title': profileData?['username']?.toString() ?? 'User',
        'avatar_url': profileData?['avatar_url']?.toString(),
        'school_name': profileData?['school_name']?.toString(),
        'is_plus':
            profileData?['subscription_tier']?.toString() == 'Membership',
        'has_story': storyCheck.isNotEmpty,
      };

      prefs.setString(
          'profile_cache_${widget.targetUserId}_${widget.chat['id']}',
          jsonEncode(newMeta));
      if (mounted && !_isDisposed) {
        setState(() {
          _metaData = newMeta;
          _isLoadingMeta = false;
        });
      }
    } catch (e) {
      if (mounted && !_isDisposed && _metaData == null) {
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
    if (widget.targetUserId.isEmpty) return;
    final response = await supabase
        .from('stories')
        .select(
            'id, user_id, media_url, media_type, caption, url, expires_at, created_at, likes_count, profiles:user_id(username, avatar_url)')
        .eq('user_id', widget.targetUserId)
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
                  userPreferences: widget.userPreferences)));
    }
  }

  String _formatTime(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return "";
    try {
      DateTime date = DateTime.parse(timestamp).toLocal();
      if (DateTime.now().difference(date).inDays == 0)
        return DateFormat('h:mm a').format(date);
      else
        return DateFormat('MMM d').format(date);
    } catch (e) {
      return "";
    }
  }

  // 🔥 FIX: Aggressively clears unread messages from local state AND Database

  @override
  Widget build(BuildContext context) {
    if (_isLoadingMeta) {
      return ListTile(
        leading:
            const CircleAvatar(radius: 28, backgroundColor: Color(0xFF121212)),
        title: Container(
            height: 12,
            width: 100,
            decoration: BoxDecoration(
                color: const Color(0xFF121212),
                borderRadius: BorderRadius.circular(4))),
        subtitle: Container(
            height: 10,
            width: 150,
            decoration: BoxDecoration(
                color: const Color(0xFF121212),
                borderRadius: BorderRadius.circular(4))),
      );
    }

    final title = _metaData?['title'] ?? "Chat";
    if (widget.searchQuery.isNotEmpty &&
        !title.toLowerCase().contains(widget.searchQuery)) {
      return const SizedBox.shrink();
    }

    final avatarUrl = _metaData?['avatar_url'];
    final chatId = widget.chat['id'];
    final hasStory = _metaData?['has_story'] == true;
    final isPlus = _metaData?['is_plus'] == true;
    final isGroup = widget.chat['is_group'] == true;

    // 🔥 Last message from chat row, updated instantly on send
    String rawContent = widget.chat['last_message']?.toString() ?? '';
    if (rawContent.isEmpty && _hasLastMessageFallback) {
      rawContent = _lastMessageFallback; // <-- USE REAL DB FALLBACK
    } else if (rawContent.isEmpty) {
      rawContent = 'Tap to chat';
    }
    if (rawContent == 'Sticker/GIF') rawContent = '🎭 Sticker';
    final String lastMessageTime = _formatTime(
        (widget.chat['updated_at'] ?? widget.chat['created_at'])?.toString());

    return ValueListenableBuilder<List<Map<String, dynamic>>>(
      valueListenable: ChatSyncService.instance.pendingMessages,
      builder: (context, pending, child) {
        final myPending = pending
            .where((m) => m['chat_id'].toString() == chatId.toString())
            .toList();
        final liveMsg = myPending.isNotEmpty ? myPending.first : null;

        String displayMsg = _localIsTyping ? "typing..." : rawContent;
        Color timeColor = (widget.unreadCount > 0 && widget.seriousness > 0)
            ? Colors.redAccent
            : Colors.white54;
        String displayTime = lastMessageTime;
        Color msgColor = _localIsTyping ? widget.themeColor : Colors.white54;

        if (liveMsg != null && !_localIsTyping) {
          displayTime = _formatTime(liveMsg['created_at']?.toString());
          final content = (liveMsg['content'] ?? '').toString().trim();
          displayMsg = content.isEmpty ? '📷 Media' : content;
          if (displayMsg == 'Sticker/GIF') displayMsg = '🎭 Sticker';
          if (liveMsg['media_type']?.toString().startsWith('view_once') ==
              true) {
            displayMsg = '📷 View once message';
          }
          if (liveMsg['is_failed'] == true) {
            displayMsg = '❌ Failed to send';
            timeColor = Colors.redAccent;
            msgColor = Colors.redAccent;
          } else if (liveMsg['is_pending'] == true) {
            displayMsg = '🕒 $displayMsg';
          }
        }

        return ListTile(
          onTap: () async {
            widget.onClearUnread(chatId.toString());
            if (isGroup) {
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => ChatRoomScreen(
                          chatId: chatId.toString(),
                          chatTitle: title,
                          isAdmin: widget.amIAdmin,
                          userPreferences: widget.userPreferences,
                          isGroup: true,
                          creatorId: widget.chat['creator_id']?.toString())));
            } else {
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (context) => IndividualChatScreen(
                          chatId: chatId.toString(),
                          recipientProfile: {
                            'id': widget.targetUserId,
                            'username': title,
                            'avatar_url': avatarUrl,
                            'school_name': _metaData?['school_name'],
                            'is_group': false
                          },
                          userPreferences: widget.userPreferences)));
            }
            widget.onClearUnread(chatId.toString());
          },
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          leading: GestureDetector(
            onTap: (isGroup || !hasStory) ? null : _openStory,
            child: Container(
              padding: hasStory ? const EdgeInsets.all(2.5) : EdgeInsets.zero,
              decoration: hasStory
                  ? BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: widget.themeColor, width: 2))
                  : null,
              // NEW (smooth — isolated repaint, cached image):
              child: RepaintBoundary(
                child: CircleAvatar(
                  radius: 28,
                  backgroundColor: const Color(0xFF121212),
                  backgroundImage: avatarUrl != null
                      ? ResizeImage(
                          NetworkImage(avatarUrl),
                          width: 112, // 28 * 4 for high DPI, capped memory
                          height: 112,
                        )
                      : null,
                  child: avatarUrl == null
                      ? Icon(isGroup ? Icons.group : Icons.person,
                          color: widget.themeColor)
                      : null,
                ),
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
                        child: Text(title,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 16),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis)),
                    if (isPlus) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.star, color: Colors.amber, size: 16)
                    ],
                  ],
                ),
              ),
              Text(displayTime,
                  style: TextStyle(color: timeColor, fontSize: 12)),
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
                    Text(displayMsg,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: msgColor,
                            fontStyle: _localIsTyping
                                ? FontStyle.italic
                                : FontStyle.normal,
                            fontSize: 14)),
                  ],
                ),
              ),
              if (widget.unreadCount > 0)
                Row(
                  children: [
                    if (widget.hasMention)
                      Container(
                          margin: const EdgeInsets.only(right: 6),
                          padding: const EdgeInsets.all(4),
                          decoration: const BoxDecoration(
                              color: Colors.grey, shape: BoxShape.circle),
                          child: const Text('@',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold))),
                    Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                            color: widget.seriousness > 0
                                ? Colors.redAccent
                                : widget.themeColor,
                            shape: BoxShape.circle),
                        child: Text(widget.unreadCount.toString(),
                            style: const TextStyle(
                                color: Color(0xFF121212),
                                fontSize: 10,
                                fontWeight: FontWeight.bold))),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}
