// lib/screens/chat/individual_chat_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../widgets/universal_profile_card.dart';

class IndividualChatScreen extends StatefulWidget {
  final String chatId;
  final Map<String, dynamic> recipientProfile;

  const IndividualChatScreen({
    super.key,
    required this.chatId,
    required this.recipientProfile,
  });

  @override
  State<IndividualChatScreen> createState() => _IndividualChatScreenState();
}

class _IndividualChatScreenState extends State<IndividualChatScreen> {
  final supabase = Supabase.instance.client;
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  bool _isTyping = false;
  Timer? _typingTimer;
  bool _remoteUserIsTyping = false;
  bool _isFollowing = false;

  // FIX: Declare the stream here
  late final Stream<List<Map<String, dynamic>>> _messageStream;

  @override
  void initState() {
    super.initState();
    _setupMessageStream();
    _setupTypingListener();
    _checkFollowStatus();
    _markMessagesAsRead();
  }

  void _setupMessageStream() {
    _messageStream = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('chat_id', widget.chatId)
        .order('created_at', ascending: false);
  }

  Future<void> _markMessagesAsRead() async {
    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) return;

    try {
      // Only update messages in THIS chat that were NOT sent by ME
      await supabase.from('messages').update({'is_read': true}).match({
        'chat_id': widget.chatId,
      }).neq('sender_id', currentUser.id);

      debugPrint('Messages marked as read for chat: ${widget.chatId}');
    } catch (e) {
      // This will print the exact error to your Debug Console
      debugPrint('Supabase Error (_markMessagesAsRead): $e');
    }
  }

  Future<void> _checkFollowStatus() async {
    final res = await supabase
        .from('followers')
        .select()
        .eq('follower_id', supabase.auth.currentUser!.id)
        .eq('following_id', widget.recipientProfile['id'])
        .maybeSingle();

    if (mounted) setState(() => _isFollowing = res != null);
  }

  void _setupTypingListener() {
    supabase
        .from('chat_participants')
        .stream(primaryKey: ['chat_id', 'user_id'])
        .eq('chat_id', widget.chatId)
        .listen((data) {
          if (data.isNotEmpty && mounted) {
            final remote = data
                .where((p) => p['user_id'] != supabase.auth.currentUser!.id);
            if (remote.isNotEmpty) {
              setState(() =>
                  _remoteUserIsTyping = remote.first['is_typing'] == true);
            }
          }
        });
  }

  void _handleTyping(String value) {
    if (!_isTyping && value.isNotEmpty) _setTypingStatus(true);
    _typingTimer?.cancel();
    _typingTimer =
        Timer(const Duration(seconds: 2), () => _setTypingStatus(false));
  }

  Future<void> _setTypingStatus(bool status) async {
    if (_isTyping == status) return;
    setState(() => _isTyping = status);
    try {
      await supabase
          .from('chat_participants')
          .update({'is_typing': status}).match({
        'chat_id': widget.chatId,
        'user_id': supabase.auth.currentUser!.id,
      });
    } catch (_) {}
  }

  Future<void> _toggleFollow() async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;

    final targetId = widget.recipientProfile['id'];
    final wasFollowing = _isFollowing;

    // Optimistic UI update (feels instant to the user)
    setState(() => _isFollowing = !_isFollowing);

    try {
      if (!wasFollowing) {
        // Follow
        await supabase.from('followers').insert({
          'follower_id': myId,
          'following_id': targetId,
        });
      } else {
        // Unfollow
        await supabase.from('followers').delete().match({
          'follower_id': myId,
          'following_id': targetId,
        });
      }
    } catch (e) {
      // Revert if the database call fails
      setState(() => _isFollowing = wasFollowing);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Failed to update follow status: $e")),
        );
      }
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();
    _setTypingStatus(false);

    try {
      // 1. Insert the message
      await supabase.from('messages').insert({
        'chat_id': widget.chatId,
        'sender_id': supabase.auth.currentUser!.id,
        'content': text,
        'is_read': false,
      });

      // 2. THIS IS THE MAGIC FIX: Update the chat's timestamp so it jumps to the top!
      await supabase
          .from('chats')
          .update({'updated_at': DateTime.now().toUtc().toIso8601String()}).eq(
              'id', widget.chatId);
    } catch (e) {
      debugPrint('Detailed Supabase Error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: ${e.toString()}")),
        );
      }
    }
  }

  @override
  void dispose() {
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
                if (snapshot.hasError)
                  return const Center(
                      child: Text("Error loading chats",
                          style: TextStyle(color: Colors.red)));
                if (!snapshot.hasData)
                  return const Center(
                      child:
                          CircularProgressIndicator(color: Color(0xFF4CAF50)));

                final messages = snapshot.data!;
                return ListView.builder(
                  controller: _scrollController,
                  reverse: true,
                  padding: const EdgeInsets.all(16),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final isMe = messages[index]['sender_id'] ==
                        supabase.auth.currentUser!.id;
                    return _buildBubble(messages[index]['content'], isMe);
                  },
                );
              },
            ),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  AppBar _buildAppBar() {
    final isGroup = widget.recipientProfile['is_group'] == true;

    return AppBar(
      backgroundColor: Colors.grey[900],
      titleSpacing: 0,
      title: GestureDetector(
        onTap: () {
          if (!isGroup) {
            UniversalProfileCard.show(context, widget.recipientProfile['id']);
          }
        },
        child: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundImage: widget.recipientProfile['avatar_url'] != null
                  ? NetworkImage(widget.recipientProfile['avatar_url'])
                  : null,
              child: widget.recipientProfile['avatar_url'] == null
                  ? Icon(isGroup ? Icons.group : Icons.person,
                      color: Colors.white54)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.recipientProfile['username'] ?? 'User',
                      style: const TextStyle(fontSize: 16, color: Colors.white),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  Text(_remoteUserIsTyping ? 'typing...' : 'Online',
                      style: TextStyle(
                          fontSize: 11,
                          color: _remoteUserIsTyping
                              ? const Color(0xFF4CAF50)
                              : Colors.white54)),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        // ONLY show the Follow/Friends button if it is NOT a group chat
        if (!isGroup)
          TextButton.icon(
            onPressed: _toggleFollow,
            icon: Icon(
              _isFollowing ? Icons.check_circle : Icons.person_add_alt_1,
              color: _isFollowing ? const Color(0xFF4CAF50) : Colors.white54,
              size: 18,
            ),
            label: Text(
              _isFollowing ? 'Friends' : 'Follow',
              style: TextStyle(
                color: _isFollowing ? const Color(0xFF4CAF50) : Colors.white54,
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
        IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            onPressed: _showChatMenu),
      ],
    );
  }

  Widget _buildBubble(String content, bool isMe) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        // FIX: constraints instead of maxConstraints
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFF4CAF50) : Colors.grey[800],
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomRight:
                isMe ? const Radius.circular(0) : const Radius.circular(16),
            bottomLeft:
                isMe ? const Radius.circular(16) : const Radius.circular(0),
          ),
        ),
        child: Text(content,
            style: const TextStyle(color: Colors.white, fontSize: 15)),
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
                icon: const Icon(Icons.add, color: Color(0xFF4CAF50)),
                onPressed: _showPlusOptions),
            Expanded(
              child: TextField(
                controller: _messageController,
                onChanged: _handleTyping,
                style: const TextStyle(color: Colors.white),
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: 'Message...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  filled: true,
                  fillColor: Colors.black,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none),
                ),
              ),
            ),
            const SizedBox(width: 4),
            CircleAvatar(
              backgroundColor: const Color(0xFF4CAF50),
              child: IconButton(
                icon: const Icon(Icons.send, color: Colors.white, size: 20),
                onPressed: _sendMessage,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ... (Keep your existing _showPlusOptions, _plusTile, and _showChatMenu)
  void _showPlusOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _plusTile(Icons.insert_drive_file, "Add File"),
          _plusTile(Icons.photo, "Add Photo"),
          _plusTile(Icons.videocam, "Add Video"),
          _plusTile(Icons.camera_alt, "Take Photo/Video"),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _plusTile(IconData icon, String title) => ListTile(
        leading: Icon(icon, color: const Color(0xFF4CAF50)),
        title: Text(title, style: const TextStyle(color: Colors.white)),
        onTap: () => Navigator.pop(context),
      );

  void _showChatMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _plusTile(Icons.group_add, "Create Group with User"),
          _plusTile(Icons.block, "Block User"),
          _plusTile(Icons.archive, "Archive User"),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
