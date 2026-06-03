// lib/screens/chat/individual_chat_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/chat/chat_room_screen.dart';
import 'package:allowance/screens/home/story_viewer_screen.dart';
import 'package:allowance/shared/services/fcm_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../../widgets/universal_profile_card.dart';

class IndividualChatScreen extends StatefulWidget {
  final String chatId;
  final Map<String, dynamic> recipientProfile;
  final UserPreferences userPreferences;

  const IndividualChatScreen({
    super.key,
    required this.chatId,
    required this.recipientProfile,
    required this.userPreferences,
  });

  @override
  State<IndividualChatScreen> createState() => _IndividualChatScreenState();
}

class _IndividualChatScreenState extends State<IndividualChatScreen> {
  final supabase = Supabase.instance.client;
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _focusNode = FocusNode(); // <--- KEEPS KEYBOARD STABLE

  bool _isTyping = false;
  Timer? _typingTimer;
  bool _remoteUserIsTyping = false;
  bool _isFollowing = false;
  Map<String, dynamic>? _replyMessage;
  bool _showScrollToBottom = false; // <-- REMOVED "final"
  Timer? _remoteTypingTimer;

  // For file/media logic
  final Map<String, Color> _userColors = {};
  String? _highlightedMessageId;
  Map<String, dynamic>? _pendingOrder;
  List<Map<String, dynamic>> _messages = [];
  StreamSubscription? _msgSub;

  // (Deleted the unused _messageStream entirely)

  @override
  void initState() {
    super.initState();
    activeChatId = widget.chatId;

    // --- NEW: Catch Pending Orders ---
    // --- FIX: Catch Pending Orders cleanly on Web ---
    final po = widget.recipientProfile['pending_order'];
    if (po != null) {
      try {
        // On web, it might already be parsed into a map by Flutter!
        _pendingOrder = po is String ? jsonDecode(po) : po;
      } catch (e) {
        debugPrint('Error parsing order: $e');
      }
    }

    _setupMessageStream();
    _setupTypingListener();
    _checkFollowStatus();
    _markMessagesAsRead();
  }

  // --- NEW: Order Preview Attachment ---
  Widget _buildOrderPreview() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF4CAF50).withOpacity(0.15),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        border: Border.all(color: const Color(0xFF4CAF50), width: 1),
      ),
      child: Row(
        children: [
          const Icon(Icons.fastfood, color: Color(0xFF4CAF50), size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Order Attached',
                    style: TextStyle(
                        color: Color(0xFF4CAF50),
                        fontWeight: FontWeight.bold,
                        fontSize: 14)),
                Text('From ${_pendingOrder!['vendor']}',
                    style:
                        const TextStyle(color: Colors.white70, fontSize: 12)),
              ],
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _pendingOrder = null),
            child: const Icon(Icons.close, color: Colors.white54),
          ),
        ],
      ),
    );
  }

  // --- NEW: Stunnning Green Order Card in Chat ---
  // --- UPDATED: Stunnning Green Order Card with Timestamps ---
  Widget _buildOrderCard(
      String jsonStr, String timeStr, bool isMe, bool isRead) {
    try {
      // --- FIX: Safely decode strings vs maps for Web ---
      final data = jsonStr is String ? jsonDecode(jsonStr) : jsonStr;
      final vendor = data['vendor'] ?? 'Vendor';
      final items = data['items'] as List<dynamic>? ?? [];
      final total = data['total'] ?? '0';

      return Container(
        width: 260,
        decoration: BoxDecoration(
          color: Colors.grey[850],
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: const Color(0xFF4CAF50).withOpacity(0.4), width: 1.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                color: Color(0xFF4CAF50),
                borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.receipt_long, color: Colors.black, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      vendor,
                      style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 16),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...items.map((item) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${item['qty']}x ',
                                style: const TextStyle(
                                    color: Color(0xFF4CAF50),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14)),
                            Expanded(
                                child: Text('${item['name']}',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 14))),
                            Text('₦${item['price']}',
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 14)),
                          ],
                        ),
                      )),
                  const Divider(color: Colors.white24, height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('TOTAL',
                          style: TextStyle(
                              color: Colors.white54,
                              fontWeight: FontWeight.bold)),
                      Text('₦$total',
                          style: const TextStyle(
                              color: Color(0xFF4CAF50),
                              fontWeight: FontWeight.bold,
                              fontSize: 18)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // --- NEW: TIME AND READ RECEIPT FOR ORDER CARD ---
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        timeStr,
                        style: const TextStyle(
                            color: Colors.white60, fontSize: 10),
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
            ),
          ],
        ),
      );
    } catch (e) {
      return const Padding(
          padding: EdgeInsets.all(8.0),
          child:
              Text('Invalid Order Data', style: TextStyle(color: Colors.red)));
    }
  }

  Future<void> _setupMessageStream() async {
    final prefs = await SharedPreferences.getInstance();
    final cachedMsgs = prefs.getString('msgs_${widget.chatId}');

    if (cachedMsgs != null && mounted) {
      // SPEED FIX: Only load the first 100 into UI to prevent 5-minute freezes
      final List<dynamic> decoded = jsonDecode(cachedMsgs);
      setState(() {
        _messages = List<Map<String, dynamic>>.from(decoded.take(100));
      });
    }

    _msgSub = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('chat_id', widget.chatId)
        .order('created_at', ascending: false)
        .limit(100) // SPEED FIX: Stop fetching 10,000 messages at once
        .listen((data) {
          if (mounted) {
            setState(() => _messages = data);
          }
          prefs.setString('msgs_${widget.chatId}', jsonEncode(data));
        });
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
          if (!mounted) return;
          final myId = supabase.auth.currentUser?.id;
          final remoteTyping = data.any((p) =>
              p['user_id']?.toString() != myId && p['is_typing'] == true);

          setState(() => _remoteUserIsTyping = remoteTyping);

          // BUG FIX: Auto-clear stuck typing indicators after 4 seconds
          if (remoteTyping) {
            _remoteTypingTimer?.cancel();
            _remoteTypingTimer = Timer(const Duration(seconds: 4), () {
              if (mounted) setState(() => _remoteUserIsTyping = false);
            });
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

    if (myId == null ||
        (text.isEmpty && mediaUrl == null && _pendingOrder == null)) return;

    final replyId = _replyMessage?['id'];
    String replySummary = 'Original message';
    if (_replyMessage != null) {
      if (_replyMessage!['content']?.toString().isNotEmpty == true &&
          !_replyMessage!['content'].toString().contains('📸') &&
          !_replyMessage!['content'].toString().contains('🎥')) {
        replySummary = _replyMessage!['content'];
      } else {
        replySummary =
            _replyMessage!['media_type'] == 'video' ? '🎥 Video' : '📸 Photo';
      }
    }

    final currentReply = _replyMessage;
    final currentOrder = _pendingOrder;

    _messageController.clear();
    _focusNode.requestFocus();
    setState(() {
      _replyMessage = null;
      _pendingOrder = null;
    });

    // --- OPTIMISTIC UI: INSTANT SPEED OVERRIDE ---
    if (currentOrder != null) {
      setState(() {
        _messages.insert(0, {
          'id': DateTime.now().millisecondsSinceEpoch,
          'chat_id': widget.chatId,
          'sender_id': myId,
          'content': jsonEncode(currentOrder),
          'media_type': 'order',
          'is_read': false,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        });
      });
    }

    if (text.isNotEmpty || mediaUrl != null) {
      setState(() {
        _messages.insert(0, {
          'id': DateTime.now().millisecondsSinceEpoch,
          'chat_id': widget.chatId,
          'sender_id': myId,
          'content': text.isNotEmpty
              ? text
              : (type == 'image'
                  ? '📸 Photo'
                  : (type == 'video' ? '🎥 Video' : '')),
          'is_read': false,
          'media_url': mediaUrl,
          'media_type': type ?? 'text',
          'thumbnail_url': thumbUrl,
          'file_size_bytes': size,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          if (replyId != null) 'reply_to_id': replyId,
          if (replyId != null) 'reply_content': replySummary,
        });
      });
    }
    // ---------------------------------------------

    try {
      if (currentOrder != null) {
        await supabase.from('messages').insert({
          'chat_id': widget.chatId,
          'sender_id': myId,
          'content': jsonEncode(currentOrder),
          'media_type': 'order',
          'is_read': false,
        });
      }

      if (text.isNotEmpty || mediaUrl != null) {
        final Map<String, dynamic> payload = {
          'chat_id': widget.chatId,
          'sender_id': myId,
          'content': text.isNotEmpty
              ? text
              : (type == 'image'
                  ? '📸 Photo'
                  : (type == 'video' ? '🎥 Video' : '')),
          'is_read': false,
          'media_url': mediaUrl,
          'media_type': type ?? 'text',
          'thumbnail_url': thumbUrl,
          'file_size_bytes': size,
        };

        if (replyId != null) {
          payload['reply_to_id'] = replyId;
          payload['reply_content'] = replySummary;
        }

        await supabase.from('messages').insert(payload);
      }

      await supabase.from('chats').update({
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.chatId);
    } catch (e) {
      debugPrint('Send error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Failed to send: $e'), backgroundColor: Colors.red));
        setState(() {
          _replyMessage = currentReply;
          _pendingOrder = currentOrder;
        });
      }
    }
  }

  // --- ADD THIS MISSING SCROLL LISTENER ---
  void _scrollListener() {
    if (!_scrollController.hasClients) return; // <-- Prevents layout crashes
    if (_scrollController.offset >= 300 && !_showScrollToBottom) {
      setState(() => _showScrollToBottom = true);
    } else if (_scrollController.offset < 300 && _showScrollToBottom) {
      setState(() => _showScrollToBottom = false);
    }
  }

  // --- REPLACE YOUR DISPOSE METHOD WITH THIS (Fixed errors) ---
  @override
  void dispose() {
    if (activeChatId == widget.chatId) {
      activeChatId = null;
    }
    _scrollController.removeListener(_scrollListener);
    _msgSub?.cancel();
    _typingTimer?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // --- REPLACE YOUR BUILD METHOD WITH THIS (Uses cached _messages) ---
  @override
  Widget build(BuildContext context) {
    // 🔥 FIX: Calculate max width exactly ONCE per screen build, protecting the chat bubbles from keyboard resizes!
    final double maxBubbleWidth = MediaQuery.sizeOf(context).width * 0.75;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _buildAppBar(),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Stack(
                children: [
                  _messages.isEmpty
                      ? const Center(
                          child: Text(
                            "Send a message to start chatting!",
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          reverse: true,
                          // Removed cacheExtent here to save RAM as well
                          addRepaintBoundaries: true,
                          addAutomaticKeepAlives: true,
                          keyboardDismissBehavior:
                              ScrollViewKeyboardDismissBehavior.onDrag,
                          padding: const EdgeInsets.all(12),
                          itemCount: _messages.length,
                          itemBuilder: (context, index) {
                            final msg = _messages[index];
                            final date =
                                DateTime.parse(msg['created_at']).toLocal();
                            bool showDateHeader = false;

                            if (index == _messages.length - 1) {
                              showDateHeader = true;
                            } else {
                              final prevDate = DateTime.parse(
                                      _messages[index + 1]['created_at'])
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
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 16),
                                    child: Center(
                                      child: Text(_getDateLabel(date),
                                          style: const TextStyle(
                                              color: Colors.white54,
                                              fontSize: 12)),
                                    ),
                                  ),
                                // 🔥 FIX: Pass the pre-calculated width down!
                                _buildBubble(_messages, index, maxBubbleWidth),
                              ],
                            );
                          },
                        ),
                  if (_showScrollToBottom)
                    Positioned(
                      bottom: 16,
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
            ),
            _buildInputBar(),
          ],
        ),
      ),
    );
  }

  void _cancelReply() {
    setState(() {
      _replyMessage = null;
    });
  }

  Widget _buildReplyPreview() {
    final senderId = _replyMessage!['sender_id']?.toString() ?? '';
    final isMe = senderId == supabase.auth.currentUser?.id;
    final content = _replyMessage!['content']?.toString() ?? '';
    final mediaUrl = _replyMessage!['media_url']?.toString();

    String senderName =
        isMe ? 'You' : (widget.recipientProfile['username'] ?? 'User');
    Color nameColor = const Color(0xFF4CAF50);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.grey[900],
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: IntrinsicHeight(
        child: Row(
          children: [
            Container(width: 4, color: nameColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isMe ? 'You' : '@$senderName',
                    style: TextStyle(
                      color: nameColor,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                  Text(
                    mediaUrl != null && content.isEmpty ? 'Photo' : content,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (mediaUrl != null)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: Image.network(mediaUrl.split(',').first,
                      width: 40, height: 40, fit: BoxFit.cover),
                ),
              ),
            GestureDetector(
              onTap: _cancelReply,
              child: const Icon(Icons.close, size: 20, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border(top: BorderSide(color: Colors.grey[900]!)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyMessage != null) _buildReplyPreview(),
          if (_pendingOrder != null) _buildOrderPreview(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              IconButton(
                icon: const Icon(Icons.add, color: Color(0xFF4CAF50)),
                onPressed: _showPlusOptions,
              ),
              Expanded(
                child: TextField(
                  controller: _messageController,
                  focusNode: _focusNode,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 5,
                  minLines: 1,
                  textInputAction: TextInputAction.newline,
                  keyboardType: TextInputType.multiline,
                  // --- FIX: Using the proper _handleTyping method! ---
                  onChanged: _handleTyping,
                  decoration: InputDecoration(
                    hintText: 'Message...',
                    hintStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: const Color(0xFF1C1C1E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(24),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                  ),
                ),
              ),
              ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _messageController,
                  builder: (context, value, child) {
                    return IconButton(
                      icon: Icon(Icons.send,
                          color: value.text.trim().isNotEmpty
                              ? const Color(0xFF4CAF50)
                              : Colors.grey),
                      onPressed: value.text.trim().isNotEmpty
                          ? () => _sendMessage()
                          : null,
                    );
                  }),
            ],
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
      iconTheme: const IconThemeData(
          color: Colors.white), // <--- FIX: White back button
      title: GestureDetector(
        onTap: () {
          if (!isGroup) {
            UniversalProfileCard.show(
                context, widget.recipientProfile['id'], widget.userPreferences);
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

  // --- NEW: MESSAGE OPTIONS (EDIT / DELETE) ---
  void _showMessageOptions(Map<String, dynamic> message, bool isMe) {
    final createdAt = DateTime.parse(message['created_at']).toLocal();
    final canEdit = DateTime.now().difference(createdAt).inMinutes <= 5;
    final isText = message['media_url'] == null &&
        (message['media_type'] == 'text' || message['media_type'] == null);
    final hasContent = message['content'] != null &&
        message['content'].toString().trim().isNotEmpty;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // --- NEW: COPY TEXT BUTTON (AVAILABLE TO EVERYONE) ---
          if (hasContent)
            ListTile(
              leading: const Icon(Icons.copy, color: Colors.white),
              title: const Text('Copy Text',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                Clipboard.setData(ClipboardData(text: message['content']));
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied to clipboard')));
              },
            ),

          if (isMe && canEdit && isText)
            ListTile(
              leading: const Icon(Icons.edit, color: Colors.white),
              title: const Text('Edit Message',
                  style: TextStyle(color: Colors.white)),
              onTap: () {
                Navigator.pop(ctx);
                _showEditDialog(message);
              },
            ),
          if (isMe)
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.redAccent),
              title: const Text('Delete Message',
                  style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteMessage(message['id']);
              },
            ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  void _showEditDialog(Map<String, dynamic> message) {
    final editController = TextEditingController(text: message['content']);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title:
            const Text('Edit Message', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: editController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Enter new message',
            hintStyle: TextStyle(color: Colors.white54),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () async {
              final newText = editController.text.trim();
              if (newText.isNotEmpty && newText != message['content']) {
                await supabase
                    .from('messages')
                    .update({'content': newText}).eq('id', message['id']);
              }
              if (mounted) Navigator.pop(ctx);
            },
            child: const Text('Save',
                style: TextStyle(
                    color: Color(0xFF4CAF50), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteMessage(dynamic messageId) async {
    try {
      await supabase.from('messages').delete().eq('id', messageId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to delete message')));
      }
    }
  }

  Widget _buildBubble(
      List<Map<String, dynamic>> messages, int index, double maxWidth) {
    final message = messages[index];
    final messageId = message['id'].toString();

    // NOTE FOR CHAT_ROOM_SCREEN:
    // In Chat_Room_Screen, the isMe logic is: final myId = supabase.auth.currentUser?.id; final isMe = message['sender_id']?.toString() == myId;
    // In Individual_Chat_Screen, the isMe logic is: final isMe = message['sender_id'] == supabase.auth.currentUser!.id;
    // Ensure you keep your respective screen's `isMe` and rendering logic inside this block, just make sure to REMOVE View.of(context) and use `maxWidth` in the constraints!

    final isMe =
        message['sender_id']?.toString() == supabase.auth.currentUser?.id;
    final content = (message['content'] ?? '').toString();
    final timeStr =
        _formatTime(message['created_at']?.toString() ?? message['created_at']);
    final isRead = message['is_read'] == true;

    final hasMedia = message['media_url'] != null;
    final mediaType = message['media_type']?.toString() ?? 'text';
    final isFile = mediaType == 'file';

    // (If pasting this in IndividualChatScreen, leave the isOrder logic here)
    final isOrder = mediaType == 'order';

    final bool isHighlighted = _highlightedMessageId == messageId;

    return RepaintBoundary(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 2),
        decoration: BoxDecoration(
          color: isHighlighted
              ? const Color(0xFF4CAF50).withOpacity(0.3)
              : Colors.transparent,
        ),
        child: Dismissible(
          key: Key('dismiss_$messageId'),
          direction: DismissDirection.startToEnd,
          confirmDismiss: (_) {
            HapticFeedback.lightImpact();
            // Call _onSwipeToReply(message) if in ChatRoomScreen
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
            child: GestureDetector(
              onLongPress: () => _showMessageOptions(message, isMe),
              child: Container(
                key: ValueKey(messageId),
                margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                // 🔥 FIX: We now use the passed-in maxWidth, preventing the 60fps layout recalculation!
                constraints: BoxConstraints(maxWidth: maxWidth),
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
                      // *Keep your existing rendering logic for _buildOrderCard, _buildReplyInsideBubble, _buildMediaSection, etc. here depending on which screen you are pasting this into!*

                      if (isOrder) // Individual Chat Only
                        _buildOrderCard(content, timeStr, isMe, isRead),

                      if (message['reply_to_id'] != null ||
                          (message['reply_content']?.startsWith('Story_') ??
                              false))
                        _buildReplyInsideBubble(message),

                      if (hasMedia) // In chat_room it's called _buildMediaWithOverlay or _buildMediaSection depending on file. Use whatever was already there!
                        _buildMediaSection(message, isMe, isRead, timeStr),

                      if (!isOrder &&
                          !isFile &&
                          content.isNotEmpty &&
                          content != '📸 Photo' &&
                          content != '🎥 Video')
                        _buildTextAndTimestamp(content, timeStr, isMe, isRead),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReplyInsideBubble(Map<String, dynamic> message) {
    final replyContent = message['reply_content']?.toString() ?? '';
    final bool isStoryReply =
        replyContent.startsWith('Story_') || replyContent == 'Story';
    final String? storyImageUrl = message['thumbnail_url'];

    // Extract the caption if it exists
    String displayReplyText = replyContent;
    if (isStoryReply && replyContent.startsWith('Story_')) {
      final parts = replyContent.split('_');
      if (parts.length > 2) {
        displayReplyText = parts.sublist(2).join('_'); // Get the caption
      } else {
        displayReplyText = "Story";
      }
    }

    return GestureDetector(
      onTap: () => _handleReplyReferenceTap(message),
      child: Container(
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(8),
          border: const Border(
              left: BorderSide(color: Color(0xFF4CAF50), width: 4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isStoryReply ? "Replying to Story" : "Replying to",
                      style: TextStyle(
                          color: _userColors['reply'] ?? Colors.greenAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      displayReplyText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            // Renders the Story thumbnail on the right side
            if (isStoryReply && storyImageUrl != null)
              ClipRRect(
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(8),
                  bottomRight: Radius.circular(8),
                ),
                child: CachedNetworkImage(
                  imageUrl: storyImageUrl,
                  width: 50,
                  height: 50,
                  fit: BoxFit.cover,
                  placeholder: (context, url) =>
                      Container(color: Colors.white10, width: 50, height: 50),
                  errorWidget: (context, url, error) => const Icon(
                      Icons.image_not_supported,
                      color: Colors.white54,
                      size: 20),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleReplyReferenceTap(Map<String, dynamic> message) async {
    final String replyContent = message['reply_content'] ?? '';

    if (replyContent.startsWith('Story_')) {
      final storyId = replyContent.split('_')[1];

      final response = await supabase
          .from('stories')
          .select('*, profiles:user_id(username, avatar_url, school_name)')
          .eq('id', storyId)
          .maybeSingle();

      if (response != null && mounted) {
        Navigator.push(
            context,
            MaterialPageRoute(
                builder: (_) => StoryViewerScreen(
                    stories: [response],
                    initialIndex: 0,
                    userPreferences: widget.userPreferences,
                    storyId: storyId)));
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Story is no longer available.'),
            backgroundColor: Colors.black87,
            duration: Duration(seconds: 2)));
      }
    } else if (message['reply_to_id'] != null) {
      final targetId = message['reply_to_id'].toString();

      // WhatsApp-style visual highlight
      setState(() => _highlightedMessageId = targetId);
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _highlightedMessageId = null);
      });

      // --- FIX: ULTRA-FAST SCROLL CALCULATION (NO GLOBAL KEYS) ---
      final targetIndex =
          _messages.indexWhere((m) => m['id'].toString() == targetId);

      if (targetIndex != -1) {
        // We use the index to estimate the position and scroll down smoothly.
        final estimatedOffset = targetIndex * 80.0;

        _scrollController.animateTo(
          estimatedOffset,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Message is too far back to scroll to.'),
            backgroundColor: Colors.black87,
            duration: Duration(seconds: 2)));
      }
    }
  }

  Widget _buildMediaSection(
      Map<String, dynamic> message, bool isMe, bool isRead, String timeStr) {
    final isVideo = message['media_type'] == 'video';
    final isFile = message['media_type'] == 'file';

    final String? mediaUrlStr = message['media_url']?.toString();
    final List<String> mediaUrls = mediaUrlStr != null && mediaUrlStr.isNotEmpty
        ? mediaUrlStr.split(',')
        : [];

    // --- Handle Files (Tap to open in external app/browser) ---
    if (isFile) {
      return GestureDetector(
        onTap: () async {
          if (mediaUrls.isNotEmpty) {
            final uri = Uri.parse(mediaUrls.first);
            if (await canLaunchUrl(uri)) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            } else {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Could not open file')));
              }
            }
          }
        },
        child: Container(
          margin: const EdgeInsets.all(4),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
              color: Colors.black26, borderRadius: BorderRadius.circular(8)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file,
                  color: Colors.blueAccent, size: 30),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message['content'] ?? 'Document',
                  style: const TextStyle(
                    color: Colors.blueAccent,
                    fontWeight: FontWeight.bold,
                    decoration: TextDecoration.underline,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // --- Handle Images/Videos (Tap to Expand to Fullscreen!) ---
    final rawUrl =
        (message['thumbnail_url'] ?? message['media_url']).toString();
    final firstUrl = rawUrl.split(',').first;

    return GestureDetector(
      onTap: () {
        if (mediaUrls.isNotEmpty) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => FullScreenMediaPlayer(
                mediaUrls: mediaUrls,
                mediaType: message['media_type'] ?? 'image',
                initialIndex: 0,
              ),
            ),
          );
        }
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          CachedNetworkImage(
            imageUrl: firstUrl,
            fit: BoxFit.cover,
            width: double.infinity,
            height: 200,
            placeholder: (context, url) =>
                Container(color: Colors.white10, height: 200),
            errorWidget: (context, url, error) => Container(
                color: Colors.white10,
                height: 200,
                child: const Icon(Icons.broken_image, color: Colors.white54)),
          ),
          if (isVideo)
            const CircleAvatar(
              backgroundColor: Colors.black54,
              child: Icon(Icons.play_arrow, color: Colors.white),
            ),
        ],
      ),
    );
  }

  // --- UPDATED: Text colors dynamically change based on isMe ---
  // --- UPDATED: Handles VERY LONG TEXT to prevent GPU vanishing bug ---
  Widget _buildTextAndTimestamp(
      String content, String timeStr, bool isMe, bool isRead) {
    return ExpandableMessageText(
      text: content,
      timeStr: timeStr,
      isMe: isMe,
      isRead: isRead,
      parentContext: context,
    );
  }

  // ... (Keep your existing _showPlusOptions, _plusTile, and _showChatMenu)
  void _showPlusOptions() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
                leading: const Icon(Icons.insert_drive_file,
                    color: Color(0xFF4CAF50)),
                title: const Text('Add File',
                    style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _pickAndUploadFile();
                }),
            ListTile(
                leading:
                    const Icon(Icons.photo_library, color: Color(0xFF4CAF50)),
                title: const Text('Add Photo',
                    style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _pickAndUploadMedia(ImageSource.gallery, 'image');
                }),
            ListTile(
                leading: const Icon(Icons.videocam, color: Color(0xFF4CAF50)),
                title: const Text('Add Video',
                    style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _pickAndUploadMedia(ImageSource.gallery, 'video');
                }),
            ListTile(
                leading: const Icon(Icons.camera_alt, color: Color(0xFF4CAF50)),
                title: const Text('Take Photo/Video',
                    style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(ctx);
                  await _pickAndUploadMedia(ImageSource.camera, 'image');
                }),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  // --- NEW: FILE UPLOADER ---
  // --- NEW: FILE UPLOADER (Memory Optimized) ---
  Future<void> _pickAndUploadFile() async {
    try {
      final result = await FilePicker.platform
          .pickFiles(withData: kIsWeb); // <--- Web Needs withData
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;

      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Uploading file...')));

      final ext = file.extension ?? 'file';
      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_${file.name.hashCode}.$ext';
      final path = 'chat_media/${widget.chatId}/$fileName';

      // --- FIX: WEB vs MOBILE FILE UPLOAD ---
      if (kIsWeb) {
        final bytes = file.bytes;
        if (bytes == null) return;
        await supabase.storage.from('chat_media').uploadBinary(path, bytes);
      } else {
        final filePath = file.path;
        if (filePath == null) return;
        final diskFile = File(filePath);
        await supabase.storage.from('chat_media').upload(path, diskFile);
      }

      final publicUrl = supabase.storage.from('chat_media').getPublicUrl(path);

      final myId = supabase.auth.currentUser?.id;
      if (myId == null) return;

      await supabase.from('messages').insert({
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': file.name,
        'media_url': publicUrl,
        'media_type': 'file',
        'file_size_bytes': file.size,
        'is_read': false,
      });
    } catch (e) {
      debugPrint("File upload error: $e");
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Failed to send file')));
    }
  }

  // --- NEW: MEDIA UPLOADER (Memory Optimized) ---
  Future<void> _pickAndUploadMedia(ImageSource source, String type) async {
    try {
      final picker = ImagePicker();
      List<XFile> pickedFiles = [];

      if (type == 'image') {
        if (source == ImageSource.gallery) {
          // --- FIX: CRUSH IMAGE QUALITY TO 50% ---
          pickedFiles = await picker.pickMultiImage(imageQuality: 50);
        } else {
          // --- FIX: CRUSH IMAGE QUALITY TO 50% ---
          final file = await picker.pickImage(source: source, imageQuality: 50);
          if (file != null) pickedFiles.add(file);
        }
      } else {
        final file = await picker.pickVideo(source: source);
        if (file != null) pickedFiles.add(file);
      }

      if (pickedFiles.isEmpty) return;

      final captionController = TextEditingController();
      final shouldSend = await showDialog<bool>(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.grey[900],
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    type == 'image' ? 'Send Photo(s)' : 'Send Video',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      height: 260,
                      width: double.infinity,
                      color: Colors.black,
                      // --- FIX: WEB SAFE IMAGE PREVIEW ---
                      child: type == 'image'
                          ? (kIsWeb
                              ? Image.network(pickedFiles.first.path,
                                  fit: BoxFit.contain)
                              : Image.file(File(pickedFiles.first.path),
                                  fit: BoxFit.contain))
                          : const Center(
                              child: Icon(Icons.play_circle,
                                  size: 80, color: Colors.white70)),
                    ),
                  ),
                  if (pickedFiles.length > 1)
                    Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: Text('+ ${pickedFiles.length - 1} more selected',
                          style: const TextStyle(
                              color: Colors.white70,
                              fontWeight: FontWeight.bold)),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: captionController,
                    style: const TextStyle(color: Colors.white),
                    maxLines: 4,
                    minLines: 1,
                    decoration: const InputDecoration(
                      hintText: "Add a caption (optional)",
                      hintStyle: TextStyle(color: Colors.white54),
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.all(12),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel',
                            style: TextStyle(color: Colors.white70)),
                      ),
                      const SizedBox(width: 24),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Send',
                            style: TextStyle(
                                color: Color(0xFF4CAF50),
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      if (shouldSend != true) return;

      List<String> uploadedUrls = [];
      String? thumbnailUrl;
      int totalSizeBytes = 0;

      for (var file in pickedFiles) {
        // --- FIX: WEB SAFE UPLOAD (BYTES INSTEAD OF FILE) ---
        final bytes = await file.readAsBytes();
        totalSizeBytes += bytes.length;

        final ext = file.name.split('.').last.toLowerCase();
        final fileName =
            '${DateTime.now().millisecondsSinceEpoch}_${file.name.hashCode}.$ext';
        final path = 'chat_media/${widget.chatId}/$fileName';

        await supabase.storage.from('chat_media').uploadBinary(path, bytes);
        uploadedUrls
            .add(supabase.storage.from('chat_media').getPublicUrl(path));

        // Generate Video Thumbnail if it's a video (Mobile Only, Web fallback to null)
        if (type == 'video' && thumbnailUrl == null && !kIsWeb) {
          final String? thumbPath = await VideoThumbnail.thumbnailFile(
            video: file.path,
            thumbnailPath: (await getTemporaryDirectory()).path,
            imageFormat: ImageFormat.JPEG,
            quality: 50,
          );

          if (thumbPath != null) {
            final thumbFile = File(thumbPath);
            await supabase.storage
                .from('chat_media')
                .upload('thumbnails/thumb_$fileName.jpg', thumbFile);
            thumbnailUrl = supabase.storage
                .from('chat_media')
                .getPublicUrl('thumbnails/thumb_$fileName.jpg');
          }
        }
      }

      final myId = supabase.auth.currentUser?.id;
      if (myId == null) return;

      final finalContent = captionController.text.trim().isNotEmpty
          ? captionController.text.trim()
          : (type == 'image' ? '📸 Photo' : '🎥 Video');

      await supabase.from('messages').insert({
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': finalContent,
        'media_url': uploadedUrls.join(','),
        'media_type': type,
        'thumbnail_url': thumbnailUrl,
        'file_size_bytes': totalSizeBytes,
        'is_read': false,
      });

      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Media sent')));
      }
    } catch (e) {
      debugPrint("Media error: $e");
    }
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

class CachedLinkify extends StatefulWidget {
  final String text;
  final TextStyle? style;
  final TextStyle? linkStyle;
  final Function(LinkableElement) onOpen;

  const CachedLinkify({
    super.key,
    required this.text,
    required this.onOpen,
    this.style,
    this.linkStyle,
  });

  @override
  State<CachedLinkify> createState() => _CachedLinkifyState();
}

class _CachedLinkifyState extends State<CachedLinkify> {
  late final Widget _cachedWidget;

  @override
  void initState() {
    super.initState();
    // Cache the parsed Linkify widget so layout passes skip regex calculation entirely
    _cachedWidget = Linkify(
      onOpen: widget.onOpen,
      text: widget.text,
      style: widget.style,
      linkStyle: widget.linkStyle,
    );
  }

  @override
  Widget build(BuildContext context) {
    return _cachedWidget;
  }
}

// =========================================================================
// EXPANDABLE TEXT WIDGET (Fixes disappearing long messages)
// =========================================================================
class ExpandableMessageText extends StatefulWidget {
  final String text;
  final String timeStr;
  final bool isMe;
  final bool isRead;
  final BuildContext parentContext;

  const ExpandableMessageText({
    super.key,
    required this.text,
    required this.timeStr,
    required this.isMe,
    required this.isRead,
    required this.parentContext,
  });

  @override
  State<ExpandableMessageText> createState() => _ExpandableMessageTextState();
}

class _ExpandableMessageTextState extends State<ExpandableMessageText> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    const int limit = 400; // Character limit before truncation
    final bool isLong = widget.text.length > limit;
    final String displayText = (isLong && !_isExpanded)
        ? '${widget.text.substring(0, limit)}...'
        : widget.text;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 8,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min, // Keeps it inline if text is short
            children: [
              Linkify(
                onOpen: (link) async {
                  final String urlString = link.url;
                  if (urlString.contains('allowanceapp.org/gist/')) {
                    final gistId = urlString.split('/').last;
                    Navigator.pushNamed(widget.parentContext, '/gist',
                        arguments: {'id': gistId});
                    return;
                  }
                  final Uri url = Uri.parse(urlString);
                  if (await canLaunchUrl(url)) {
                    await launchUrl(url, mode: LaunchMode.externalApplication);
                  }
                },
                text: displayText,
                style: TextStyle(
                  color: widget.isMe ? Colors.black : Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
                linkStyle: TextStyle(
                  color: widget.isMe ? Colors.black87 : const Color(0xFF53BDEB),
                  decoration: TextDecoration.underline,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (isLong && !_isExpanded)
                GestureDetector(
                  onTap: () => setState(() => _isExpanded = true),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8.0, bottom: 2.0),
                    child: Text(
                      'Read more',
                      style: TextStyle(
                        color: widget.isMe
                            ? Colors.black54
                            : const Color(0xFF4CAF50),
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.timeStr,
                style: TextStyle(
                  color: widget.isMe ? Colors.black54 : Colors.white60,
                  fontSize: 10,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (widget.isMe) ...[
                const SizedBox(width: 4),
                Icon(
                  widget.isRead ? Icons.done_all : Icons.done,
                  size: 14,
                  color: widget.isRead ? Colors.blue : Colors.black54,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
