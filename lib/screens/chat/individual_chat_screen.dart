// lib/screens/chat/individual_chat_screen.dart
import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
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
  Map<String, dynamic>? _replyMessage;
  final bool _showScrollToBottom = false;
  // For file/media logic
  final Map<String, Color> _userColors = {};

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

  String _getDateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final dateToCheck = DateTime(date.year, date.month, date.day);

    if (dateToCheck == today) return 'Today';
    if (dateToCheck == yesterday) return 'Yesterday';
    return DateFormat('MMMM d, y').format(date);
  }

  String _formatTime(String createdAt) {
    final date = DateTime.parse(createdAt).toLocal();
    return DateFormat('h:mm a').format(date);
  }

  Future<void> _sendMessage(
      {String? mediaUrl, String? type, String? thumbUrl, int? size}) async {
    final text = _messageController.text.trim();
    final myId = supabase.auth.currentUser?.id;
    if (myId == null || (text.isEmpty && mediaUrl == null)) return;

    final replyId = _replyMessage?['id'];
    String replySummary = 'Original message';
    if (_replyMessage != null) {
      if (_replyMessage!['content']?.toString().isNotEmpty == true &&
          !_replyMessage!['content'].toString().contains('📸')) {
        replySummary = _replyMessage!['content'];
      } else {
        replySummary =
            _replyMessage!['media_type'] == 'video' ? '🎥 Video' : '📸 Photo';
      }
    }

    final currentReply = _replyMessage;
    _messageController.clear();
    setState(() => _replyMessage = null);

    try {
      final payload = {
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': text.isNotEmpty
            ? text
            : (type == 'image'
                ? '📸 Photo'
                : (type == 'video' ? '🎥 Video' : '')),
        'is_read': false,
        'reply_to_id': replyId,
        'reply_content': replyId != null ? replySummary : null,
        'media_url': mediaUrl,
        'media_type': type,
        'thumbnail_url': thumbUrl,
        'file_size_bytes': size,
      };

      await supabase.from('messages').insert(payload);

      // Update chat's last activity
      await supabase.from('chats').update({
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'last_message':
            text.isNotEmpty ? text : (type == 'image' ? 'Photo' : 'Video'),
      }).eq('id', widget.chatId);
    } catch (e) {
      debugPrint('Send error: $e');
      setState(() => _replyMessage = currentReply);
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
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: _messageStream,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    final messages = snapshot.data!;
                    return ListView.builder(
                      controller: _scrollController,
                      reverse: true,
                      padding: const EdgeInsets.all(12),
                      itemCount: messages.length,
                      itemBuilder: (context, index) {
                        final msg = messages[index];
                        final date =
                            DateTime.parse(msg['created_at']).toLocal();

                        // Date Header Logic
                        bool showDateHeader = false;
                        if (index == messages.length - 1) {
                          showDateHeader = true;
                        } else {
                          final prevDate =
                              DateTime.parse(messages[index + 1]['created_at'])
                                  .toLocal();
                          if (date.day != prevDate.day ||
                              date.year != prevDate.year) {
                            showDateHeader = true;
                          }
                        }

                        return Column(
                          children: [
                            if (showDateHeader)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                child: Center(
                                  child: Text(_getDateLabel(date),
                                      style: const TextStyle(
                                          color: Colors.white54, fontSize: 12)),
                                ),
                              ),
                            _buildBubble(messages, index),
                          ],
                        );
                      },
                    );
                  },
                ),
              ),
              // Input Bar with Reply Preview
              _buildInputBar(),
            ],
          ),
          // Scroll to Bottom FAB
          if (_showScrollToBottom)
            Positioned(
              bottom: 100,
              right: 16,
              child: FloatingActionButton.small(
                backgroundColor: const Color(0xFF202C33),
                onPressed: () => _scrollController.animateTo(0,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOut),
                child: const Icon(Icons.keyboard_double_arrow_down,
                    color: Colors.white),
              ),
            ),
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

  Widget _buildBubble(List<Map<String, dynamic>> messages, int index) {
    final message = messages[index];
    final isMe = message['sender_id'] == supabase.auth.currentUser!.id;
    final content = message['content'] ?? '';
    final timeStr = _formatTime(message['created_at']);
    final isRead = message['is_read'] == true;
    final hasMedia = message['media_url'] != null;

    return Dismissible(
      key: Key(message['id'].toString()),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (_) {
        HapticFeedback.lightImpact();
        setState(() => _replyMessage = message);
        return Future.value(false);
      },
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: const Icon(Icons.reply, color: Color(0xFF4CAF50)),
      ),
      child: Align(
        alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.75),
          decoration: BoxDecoration(
            color: isMe ? const Color(0xFF4CAF50) : Colors.grey[800],
            borderRadius: BorderRadius.circular(16).copyWith(
              bottomRight: isMe ? Radius.zero : const Radius.circular(16),
              bottomLeft: isMe ? const Radius.circular(16) : Radius.zero,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. Reply UI
                if (message['reply_to_id'] != null)
                  _buildReplyInsideBubble(message),

                // 2. Media UI
                if (hasMedia)
                  _buildMediaSection(message, isMe, isRead, timeStr),

                // 3. Text UI
                if (content.toString().isNotEmpty &&
                    content != '📸 Photo' &&
                    content != '🎥 Video')
                  _buildTextAndTimestamp(content, timeStr, isMe, isRead),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReplyInsideBubble(Map<String, dynamic> message) {
    return Container(
      margin: const EdgeInsets.all(4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black12,
        borderRadius: BorderRadius.circular(8),
        border:
            const Border(left: BorderSide(color: Color(0xFF4CAF50), width: 4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Replying to",
            style: TextStyle(
                color: _userColors['reply'] ?? Colors.greenAccent,
                fontSize: 11,
                fontWeight: FontWeight.bold),
          ),
          Text(
            message['reply_content'] ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaSection(
      Map<String, dynamic> message, bool isMe, bool isRead, String timeStr) {
    final isVideo = message['media_type'] == 'video';
    return Stack(
      alignment: Alignment.center,
      children: [
        CachedNetworkImage(
          imageUrl: message['thumbnail_url'] ?? message['media_url'],
          fit: BoxFit.cover,
          width: double.infinity,
          height: 200,
          placeholder: (context, url) =>
              Container(color: Colors.white10, height: 200),
        ),
        if (isVideo)
          const CircleAvatar(
            backgroundColor: Colors.black54,
            child: Icon(Icons.play_arrow, color: Colors.white),
          ),
      ],
    );
  }

  Widget _buildTextAndTimestamp(
      String content, String timeStr, bool isMe, bool isRead) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 8,
        children: [
          Text(
            content,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                timeStr,
                style: const TextStyle(color: Colors.white60, fontSize: 10),
              ),
              if (isMe) ...[
                const SizedBox(width: 4),
                Icon(
                  isRead ? Icons.done_all : Icons.done,
                  size: 14,
                  color: isRead ? Colors.blue : Colors.white60,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_replyMessage != null)
          Container(
            color: const Color(0xFF1F2C34),
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                const Icon(Icons.reply, color: Colors.white54),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _replyMessage!['content'] ?? 'Media',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
                IconButton(
                  icon:
                      const Icon(Icons.close, size: 18, color: Colors.white54),
                  onPressed: () => setState(() => _replyMessage = null),
                ),
              ],
            ),
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          color: Colors.black,
          child: Row(
            children: [
              // FIXED: Wired up the Plus Options menu
              IconButton(
                icon: const Icon(Icons.add, color: Color(0xFF4CAF50)),
                onPressed: _showPlusOptions,
              ),
              Expanded(
                child: TextField(
                  controller: _messageController,
                  // FIXED: Wired up the Typing indicator logic
                  onChanged: (value) => _handleTyping(value),
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: "Message",
                    hintStyle: const TextStyle(color: Colors.white38),
                    filled: true,
                    fillColor: const Color(0xFF202C33),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.send, color: Color(0xFF4CAF50)),
                onPressed: () => _sendMessage(),
              ),
            ],
          ),
        ),
      ],
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
