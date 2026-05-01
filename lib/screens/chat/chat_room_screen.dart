// lib/screens/chat/chat_room_screen.dart
import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class ChatRoomScreen extends StatefulWidget {
  final String chatId;
  final String chatTitle;
  final bool isGroup;

  const ChatRoomScreen({
    super.key,
    required this.chatId,
    required this.chatTitle,
    this.isGroup = false,
  });

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final supabase = Supabase.instance.client;
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _memberSearchController = TextEditingController();

  late final Stream<List<Map<String, dynamic>>> _messageStream;

  bool _isTyping = false;
  bool _remoteUserIsTyping = false;
  Timer? _typingTimer;

  Map<String, dynamic>? _chatMeta;
  List<Map<String, dynamic>> _participants = [];
  List<Map<String, dynamic>> _memberProfiles = [];
  String? _creatorId;
  bool _isGroupCreator = false;

  // Color mapping for usernames
  final Map<String, Color> _userColors = {};

  String _memberSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _setupMessageStream();
    _loadChatMeta();
    _setupTypingListener();
    _markMessagesAsRead();
  }

  void _setupMessageStream() {
    _messageStream = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('chat_id', widget.chatId)
        .order('created_at', ascending: false);
  }

  Future<void> _loadChatMeta() async {
    try {
      final chatResp = await supabase
          .from('chats')
          .select('*, chat_participants!inner(*)')
          .eq('id', widget.chatId)
          .maybeSingle();

      if (chatResp == null) return;

      final currentUserId = supabase.auth.currentUser?.id;
      final creatorId = chatResp['admin_id']?.toString() ??
          chatResp['created_by']?.toString() ??
          chatResp['owner_id']?.toString();

      final participants =
          List<Map<String, dynamic>>.from(chatResp['chat_participants'] ?? []);

      final userIds = participants
          .map((p) => p['user_id']?.toString())
          .where((id) => id != null && id.isNotEmpty)
          .toList();

      List<Map<String, dynamic>> profiles = [];
      if (userIds.isNotEmpty) {
        final profileResp = await supabase
            .from('profiles')
            .select('id, username, avatar_url, school_name')
            .inFilter('id', userIds);
        profiles = List<Map<String, dynamic>>.from(profileResp);
      }

      final chatMap = Map<String, dynamic>.from(chatResp);
      chatMap['group_name'] =
          chatMap['group_name'] ?? chatMap['name'] ?? widget.chatTitle;
      chatMap['group_avatar'] =
          chatMap['group_avatar'] ?? chatMap['avatar_url'];
      chatMap['group_description'] =
          chatMap['group_description'] ?? chatMap['description'] ?? '';

      if (!mounted) return;

      setState(() {
        _chatMeta = chatMap;
        _participants = participants;
        _memberProfiles = profiles;
        _creatorId = creatorId;
        _isGroupCreator = currentUserId != null && creatorId == currentUserId;
      });
    } catch (e) {
      debugPrint("Load chat meta error: $e");
    }
  }

  Color _getUserColor(String userId) {
    if (_userColors.containsKey(userId)) return _userColors[userId]!;

    // Generate consistent color based on userId
    final hash = userId.hashCode.abs();
    final hue = (hash % 360).toDouble();
    final color = HSLColor.fromAHSL(1.0, hue, 0.8, 0.6).toColor();

    _userColors[userId] = color;
    return color;
  }

  bool _isUserStillInGroup(String userId) {
    return _participants.any((p) => p['user_id']?.toString() == userId);
  }

  Future<void> _markMessagesAsRead() async {
    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) return;
    try {
      await supabase.from('messages').update({'is_read': true}).match({
        'chat_id': widget.chatId,
      }).neq('sender_id', currentUser.id);
    } catch (e) {
      debugPrint('Mark as read error: $e');
    }
  }

  void _setupTypingListener() {
    supabase
        .from('chat_participants')
        .stream(primaryKey: ['chat_id', 'user_id'])
        .eq('chat_id', widget.chatId)
        .listen((data) {
          if (!mounted) return;
          final myId = supabase.auth.currentUser?.id;
          final remoteTyping = data.any((p) =>
              p['user_id']?.toString() != myId && p['is_typing'] == true);
          setState(() => _remoteUserIsTyping = remoteTyping);
        });
  }

  void _handleTyping(String value) {
    if (!_isTyping && value.isNotEmpty) _setTypingStatus(true);
    _typingTimer?.cancel();
    _typingTimer =
        Timer(const Duration(seconds: 2), () => _setTypingStatus(false));
  }

  Future<void> _setTypingStatus(bool status) async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null || _isTyping == status) return;
    setState(() => _isTyping = status);
    try {
      await supabase
          .from('chat_participants')
          .update({'is_typing': status}).match({
        'chat_id': widget.chatId,
        'user_id': myId,
      });
    } catch (e) {
      debugPrint("Typing update failed: $e");
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;

    _messageController.clear();
    _setTypingStatus(false);

    try {
      await supabase.from('messages').insert({
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': text,
        'is_read': false,
      });

      await supabase.from('chats').update({
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.chatId);
    } catch (e) {
      debugPrint('Send message error: $e');
    }
  }

  void _showPlusOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          _menuTile(Icons.photo_library, 'Add Photo', () {}),
          _menuTile(Icons.videocam, 'Add Video', () {}),
          _menuTile(Icons.insert_drive_file, 'Add File', () {}),
          _menuTile(Icons.camera_alt, 'Take Photo/Video', () {}),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }

  void _showChatMenu() {
    if (!widget.isGroup) return;
    // ... (your existing menu code - unchanged)
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_isGroupCreator) ...[
            _menuTile(Icons.edit, 'Edit Rules', () {}),
            _menuTile(Icons.link, 'Copy Group Link', () async {
              Navigator.pop(ctx);
              final link = 'allowance://group/${widget.chatId}';
              await Clipboard.setData(ClipboardData(text: link));
              if (mounted)
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Group link copied!')));
            }),
            _menuTile(Icons.admin_panel_settings, 'Appoint Admin', () {}),
            _menuTile(Icons.person_remove, 'Remove User', () {}),
            _menuTile(Icons.delete, 'Delete Group', () {}),
          ] else
            _menuTile(Icons.logout, 'Leave Group', () async {
              Navigator.pop(ctx);
              final myId = supabase.auth.currentUser?.id;
              if (myId == null) return;
              await supabase.from('chat_participants').delete().match({
                'chat_id': widget.chatId,
                'user_id': myId,
              });
              if (mounted) Navigator.pop(context);
            }),
          const SizedBox(height: 12),
        ]),
      ),
    );
  }

  Widget _menuTile(IconData icon, String title, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: const Color(0xFF4CAF50), size: 26),
      title: Text(title,
          style: const TextStyle(
              color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    );
  }

  Widget _buildBubble(List<Map<String, dynamic>> messages, int index) {
    final message = messages[index];
    final myId = supabase.auth.currentUser?.id;
    final isMe = message['sender_id']?.toString() == myId;
    final content = (message['content'] ?? '').toString();

    final senderId = message['sender_id']?.toString() ?? '';
    final senderProfile = _memberProfiles.firstWhere(
      (p) => p['id'].toString() == senderId,
      orElse: () => {'username': 'User', 'avatar_url': null},
    );

    final senderName = senderProfile['username']?.toString() ?? 'User';
    final avatarUrl = senderProfile['avatar_url']?.toString();

    final bool isStillInGroup = _isUserStillInGroup(senderId);
    final Color nameColor = isMe
        ? Colors.white
        : (isStillInGroup ? _getUserColor(senderId) : Colors.grey);

    // Show avatar only on first message of a group from same sender
    bool showAvatar = false;
    if (widget.isGroup && !isMe) {
      final prevSender = index < messages.length - 1
          ? messages[index + 1]['sender_id']?.toString()
          : null;
      showAvatar = prevSender != senderId;
    }

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment:
              isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
          children: [
            if (!isMe && widget.isGroup && showAvatar) ...[
              CircleAvatar(
                radius: 16,
                backgroundImage: avatarUrl != null && avatarUrl.isNotEmpty
                    ? NetworkImage(avatarUrl)
                    : null,
                child: (avatarUrl == null || avatarUrl.isEmpty)
                    ? Text(senderName[0].toUpperCase(),
                        style:
                            const TextStyle(fontSize: 12, color: Colors.white))
                    : null,
              ),
              const SizedBox(width: 8),
            ] else if (!isMe && widget.isGroup) ...[
              const SizedBox(width: 40),
            ],
            Flexible(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.75),
                decoration: BoxDecoration(
                  color: isMe ? const Color(0xFF4CAF50) : Colors.grey[850],
                  borderRadius: BorderRadius.circular(18).copyWith(
                    bottomRight: isMe ? Radius.zero : const Radius.circular(18),
                    bottomLeft: isMe ? const Radius.circular(18) : Radius.zero,
                  ),
                ),
                child: Column(
                  crossAxisAlignment:
                      isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    if (widget.isGroup && !isMe && showAvatar)
                      Text(
                        '@$senderName',
                        style: TextStyle(
                          color: nameColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    Text(content,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 15)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final avatarUrl = _chatMeta?['group_avatar']?.toString();
    final title = (_chatMeta?['group_name'] ?? widget.chatTitle).toString();

    return AppBar(
      backgroundColor: Colors.grey[900],
      titleSpacing: 0,
      elevation: 0,
      title: GestureDetector(
        onTap: widget.isGroup ? _showGroupInfo : () {},
        child: Row(
          children: [
            CircleAvatar(
              radius: 19,
              backgroundColor: Colors.grey[800],
              backgroundImage: (avatarUrl != null && avatarUrl.isNotEmpty)
                  ? NetworkImage(avatarUrl)
                  : null,
              child: (avatarUrl == null || avatarUrl.isEmpty)
                  ? Icon(widget.isGroup ? Icons.groups : Icons.person,
                      color: Colors.white54)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 16,
                          color: Colors.white,
                          fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(
                    _remoteUserIsTyping
                        ? 'typing...'
                        : (widget.isGroup
                            ? '${_participants.length} members'
                            : 'Online'),
                    style: TextStyle(
                        fontSize: 11,
                        color: _remoteUserIsTyping
                            ? const Color(0xFF4CAF50)
                            : Colors.white54),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onPressed: _showChatMenu),
      ],
    );
  }

  void _showGroupInfo() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (_, controller) {
          final filteredMembers = _memberProfiles.where((m) {
            final name = (m['username'] ?? '').toString().toLowerCase();
            return name.contains(_memberSearchQuery.toLowerCase());
          }).toList();

          final creatorProfile = _memberProfiles.firstWhere(
            (p) => p['id'].toString() == _creatorId,
            orElse: () => <String, dynamic>{},
          );

          return Container(
            decoration: const BoxDecoration(
              color: Color(0xFF111111),
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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

                // Group Header
                Row(
                  children: [
                    CircleAvatar(
                      radius: 35,
                      backgroundImage: _chatMeta?['group_avatar'] != null
                          ? NetworkImage(_chatMeta!['group_avatar'])
                          : null,
                      child: _chatMeta?['group_avatar'] == null
                          ? const Icon(Icons.groups,
                              size: 40, color: Colors.white54)
                          : null,
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _chatMeta?['group_name'] ?? widget.chatTitle,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold),
                          ),
                          Text(
                            _isGroupCreator
                                ? 'You created this group'
                                : 'Group',
                            style: const TextStyle(color: Colors.white70),
                          ),
                          if (_chatMeta?['group_description']?.isNotEmpty ==
                              true)
                            Text(
                              _chatMeta!['group_description'],
                              style: const TextStyle(
                                  color: Colors.white70, height: 1.4),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Creator
                if (creatorProfile.isNotEmpty) ...[
                  const Text('Creator',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  ListTile(
                    leading: CircleAvatar(
                      backgroundImage: creatorProfile['avatar_url'] != null
                          ? NetworkImage(creatorProfile['avatar_url'])
                          : null,
                    ),
                    title: Text('@${creatorProfile['username'] ?? 'Unknown'}',
                        style: const TextStyle(color: Colors.white)),
                    subtitle: Text(creatorProfile['school_name'] ?? '',
                        style: const TextStyle(color: Colors.white54)),
                  ),
                  const Divider(color: Colors.white24),
                ],

                // Members
                Text('Members (${filteredMembers.length})',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),

                CupertinoSearchTextField(
                  controller: _memberSearchController,
                  style: const TextStyle(color: Colors.white),
                  placeholder: 'Search members...',
                  onChanged: (value) {
                    setState(() => _memberSearchQuery = value);
                  },
                ),

                const SizedBox(height: 12),

                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: filteredMembers.length,
                  itemBuilder: (context, index) {
                    final member = filteredMembers[index];
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundImage: member['avatar_url'] != null
                            ? NetworkImage(member['avatar_url'])
                            : null,
                      ),
                      title: Text('@${member['username'] ?? 'User'}',
                          style: const TextStyle(color: Colors.white)),
                      subtitle: Text(member['school_name'] ?? '',
                          style: const TextStyle(color: Colors.white54)),
                    );
                  },
                ),

                const SizedBox(height: 30),
                ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                  label: const Text('Close'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4CAF50),
                    foregroundColor: Colors.black,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _memberSearchController.dispose();
    _typingTimer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _messageStream,
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(
                      child:
                          CircularProgressIndicator(color: Color(0xFF4CAF50)));
                }
                final messages = snapshot.data!;
                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (_, index) => _buildBubble(messages, index),
                );
              },
            ),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
      color: Colors.grey[900],
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.add, color: Color(0xFF4CAF50), size: 28),
              onPressed: _showPlusOptions,
            ),
            Expanded(
              child: TextField(
                controller: _messageController,
                onChanged: _handleTyping,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Message...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: Colors.black,
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.send, color: Color(0xFF4CAF50), size: 28),
              onPressed: _sendMessage,
            ),
          ],
        ),
      ),
    );
  }
}
