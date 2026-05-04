// lib/screens/chat/chat_room_screen.dart
import 'dart:async';
import 'dart:io';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/chat/create_group_screen.dart';
import 'package:allowance/widgets/universal_profile_card.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

class ChatRoomScreen extends StatefulWidget {
  final String chatId;
  final String chatTitle;
  final bool isGroup;
  final bool isAdmin;
  final UserPreferences userPreferences; // ← ADD THIS

  const ChatRoomScreen({
    super.key,
    required this.chatId,
    required this.chatTitle,
    required this.userPreferences, // ← Required
    required this.isAdmin,
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
  Map<String, dynamic>? _replyMessage;
  bool _showScrollToBottom = false;

  // For colored usernames
  final Map<String, Color> _userColors = {};

  String _memberSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_scrollListener); // NEW
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

  void _onSwipeToReply(Map<String, dynamic> message) {
    HapticFeedback.lightImpact(); // Provides tactile feedback like WhatsApp
    setState(() {
      _replyMessage = message;
    });
  }

  void _cancelReply() {
    setState(() {
      _replyMessage = null;
    });
  }

  Color _getUserColor(String userId) {
    if (_userColors.containsKey(userId)) return _userColors[userId]!;
    final hash = userId.hashCode.abs();
    final hue = (hash % 360).toDouble();
    final color = HSLColor.fromAHSL(1.0, hue, 0.85, 0.65).toColor();
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
    final myId = supabase.auth.currentUser?.id;

    if (myId == null || (text.isEmpty && _replyMessage == null)) return;

    final replyId = _replyMessage?['id'];

    // FIX: Simplified logic to ensure reply_content is never weird/null
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
    _messageController.clear();
    setState(() => _replyMessage = null);

    try {
      final Map<String, dynamic> payload = {
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': text.isNotEmpty ? text : ' ',
        'is_read': false,
      };

      if (replyId != null) {
        payload['reply_to_id'] = replyId;
        payload['reply_content'] = replySummary; // Clean string only
      }

      await supabase.from('messages').insert(payload);
      // ... rest of your metadata update code
    } catch (e) {
      debugPrint('Send error: $e');
      if (mounted) setState(() => _replyMessage = currentReply);
    }
  }

  // Update this method to handle the jump logic correctly
  void _scrollToMessage(
      dynamic replyToId, List<Map<String, dynamic>> currentMessages) {
    if (replyToId == null) return;

    // 1. Find the index of the message we want to jump to
    final index = currentMessages
        .indexWhere((m) => m['id'].toString() == replyToId.toString());

    if (index != -1) {
      HapticFeedback.mediumImpact();

      // 2. Calculate position. Note: This is an estimate based on average bubble height
      // For precise jumping in a dynamic list, Scrollable.ensureVisible is usually better
      // but requires global keys. This is a reliable quick-fix:
      _scrollController.animateTo(
        index * 100.0, // Assuming 100px average height
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Message too far back to jump to')),
      );
    }
  }

  Widget _buildReplyPreview() {
    final senderId = _replyMessage!['sender_id']?.toString() ?? '';
    final isMe = senderId == supabase.auth.currentUser?.id;
    final content = _replyMessage!['content']?.toString() ?? '';
    final mediaUrl = _replyMessage!['media_url']?.toString();

    // NEW: Look up the username and color of the person we are replying to
    String senderName = 'User';
    Color nameColor = const Color(0xFF4CAF50);

    if (isMe) {
      senderName = 'You';
    } else {
      final profile = _memberProfiles.firstWhere(
        (p) => p['id'].toString() == senderId,
        orElse: () => {'username': 'User'},
      );
      senderName = profile['username']?.toString() ?? 'User';
      nameColor = _getUserColor(senderId); // Match their assigned chat color
    }

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
            Container(width: 4, color: nameColor), // Dynamic colored bar
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isMe ? 'You' : '@$senderName', // Shows @username
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

  void _showPlusOptions() async {
    final rules = _chatMeta?['rules'] as Map<String, dynamic>? ?? {};

    final allowPhotos = rules['photos'] ?? true;
    final allowVideos = rules['videos'] ?? true;
    final allowFiles = rules['files'] ?? true;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (allowPhotos)
              _menuTile(Icons.photo_library, 'Add Photo', () async {
                Navigator.pop(ctx);
                await _pickAndUploadMedia(ImageSource.gallery, 'image');
              }),
            if (allowVideos)
              _menuTile(Icons.videocam, 'Add Video', () async {
                Navigator.pop(ctx);
                await _pickAndUploadMedia(ImageSource.gallery, 'video');
              }),
            if (allowFiles)
              _menuTile(Icons.insert_drive_file, 'Add File', () async {
                Navigator.pop(ctx);
                // TODO: Implement file picker (for PDFs, docs, etc.)
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('File picker coming soon')),
                );
              }),
            _menuTile(Icons.camera_alt, 'Take Photo/Video', () async {
              Navigator.pop(ctx);
              await _pickAndUploadMedia(ImageSource.camera, 'image');
            }),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  // NEW HELPER METHOD - Add this anywhere in the class
  Future<void> _pickAndUploadMedia(ImageSource source, String type) async {
    try {
      final picker = ImagePicker();
      List<XFile> pickedFiles = [];

      if (type == 'image') {
        if (source == ImageSource.gallery) {
          pickedFiles = await picker.pickMultiImage(imageQuality: 85);
        } else {
          final file = await picker.pickImage(source: source, imageQuality: 85);
          if (file != null) pickedFiles.add(file);
        }
      } else {
        final file = await picker.pickVideo(source: source);
        if (file != null) pickedFiles.add(file);
      }

      if (pickedFiles.isEmpty) return;

      // --- STEP 1: YOUR DIALOG LOGIC ---
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
                      child: type == 'image'
                          ? Image.file(
                              File(pickedFiles.first.path),
                              fit: BoxFit.contain,
                            )
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

      // --- STEP 2: METADATA & UPLOAD LOGIC ---
      List<String> uploadedUrls = [];
      String? thumbnailUrl;
      int totalSizeBytes = 0;

      for (var file in pickedFiles) {
        final bytes = await file.readAsBytes();
        totalSizeBytes += bytes.length;

        final ext = file.name.split('.').last.toLowerCase();
        final fileName =
            '${DateTime.now().millisecondsSinceEpoch}_${file.name.hashCode}.$ext';
        final path = 'chat_media/${widget.chatId}/$fileName';

        await supabase.storage.from('chat_media').uploadBinary(path, bytes);
        uploadedUrls
            .add(supabase.storage.from('chat_media').getPublicUrl(path));

        // Generate Video Thumbnail if it's a video
        if (type == 'video' && thumbnailUrl == null) {
          final String? thumbPath = await VideoThumbnail.thumbnailFile(
            video: file.path,
            thumbnailPath: (await getTemporaryDirectory()).path,
            imageFormat: ImageFormat.JPEG,
            quality: 50,
          );

          if (thumbPath != null) {
            final thumbBytes = await File(thumbPath).readAsBytes();
            await supabase.storage
                .from('chat_media')
                .uploadBinary('thumbnails/thumb_$fileName.jpg', thumbBytes);
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
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Media sent')),
        );
      }
    } catch (e) {
      debugPrint("Media error: $e");
    }
  }

  void _showChatMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            if (widget.isGroup) ...[
              // RESTORED: Group Management for Creators
              if (_isGroupCreator) ...[
                _menuTile(Icons.edit, 'Edit Group', () async {
                  Navigator.pop(ctx);
                  await _editGroup();
                }),
                _menuTile(Icons.link, 'Copy Group Link', () async {
                  Navigator.pop(ctx);
                  final link = 'allowance://group/${widget.chatId}';
                  await Clipboard.setData(ClipboardData(text: link));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Group link copied!')));
                  }
                }),
              ],

              _menuTile(Icons.info_outline, 'Group Info', () {
                Navigator.pop(ctx);
                // Navigate to info page logic here
              }),

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
            ],

            // THE TOGGLE SECTION (Maintained)
            StatefulBuilder(
              builder: (context, setModalState) => ListTile(
                leading: Icon(
                  widget.userPreferences.autoDownloadMedia
                      ? Icons.file_download_done
                      : Icons.file_download,
                  color: const Color(0xFF4CAF50),
                ),
                title: const Text(
                  'Auto-Download Media',
                  style: TextStyle(color: Colors.white),
                ),
                trailing: Switch(
                  value: widget.userPreferences.autoDownloadMedia,
                  activeColor: const Color(0xFF4CAF50),
                  onChanged: (val) async {
                    // 1. Update the UI inside the Modal
                    setModalState(
                        () => widget.userPreferences.autoDownloadMedia = val);

                    // 2. Update the main Chat Screen UI
                    setState(() {});

                    // 3. Save to SharedPreferences and Supabase
                    await widget.userPreferences.savePreferences();
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

// Helper widget for clean code
  Widget _menuTile(IconData icon, String title, VoidCallback onTap) {
    return ListTile(
      leading: Icon(icon, color: Colors.white70),
      title: Text(title, style: const TextStyle(color: Colors.white)),
      onTap: onTap,
    );
  }

  // NEW: Edit Group
  Future<void> _editGroup() async {
    if (_chatMeta == null) return;

    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CreateGroupScreen(
          userPreferences: widget.userPreferences,
          isEdit: true,
          chatId: widget.chatId,
          initialName: _chatMeta!['group_name'],
          initialAvatarUrl: _chatMeta!['group_avatar'],
          initialDescription: _chatMeta!['group_description'],
        ),
      ),
    );

    if (result == true && mounted) {
      await _loadChatMeta(); // Force refresh
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Group updated successfully!')),
      );
    }
  }

  String _formatTime(String? createdAt) {
    if (createdAt == null) return "";
    final date = DateTime.parse(createdAt).toLocal();
    final hour =
        date.hour > 12 ? date.hour - 12 : (date.hour == 0 ? 12 : date.hour);
    final minute = date.minute.toString().padLeft(2, '0');
    final amPm = date.hour >= 12 ? "PM" : "AM";
    return "$hour:$minute $amPm";
  }

  String _getDateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final msgDate = DateTime(date.year, date.month, date.day);

    if (msgDate == today) return "Today";
    if (msgDate == yesterday) return "Yesterday";

    // Format: May 4, 2026
    final months = [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec"
    ];
    return "${months[date.month - 1]} ${date.day}, ${date.year}";
  }

  Widget _buildBubble(List<Map<String, dynamic>> messages, int index) {
    final message = messages[index];
    final myId = supabase.auth.currentUser?.id;
    final isMe = message['sender_id']?.toString() == myId;
    final content = (message['content'] ?? '').toString();
    final timeStr = _formatTime(message['created_at']?.toString());
    final isRead = message['is_read'] == true;

    final senderId = message['sender_id']?.toString() ?? '';
    final senderProfile = _memberProfiles.firstWhere(
      (p) => p['id'].toString() == senderId,
      orElse: () => {'username': 'User', 'avatar_url': null},
    );

    final senderName = senderProfile['username']?.toString() ?? 'User';
    final avatarUrl = senderProfile['avatar_url']?.toString();

    final bubbleColor =
        isMe ? const Color(0xFF4CAF50) : const Color(0xFF202C33);

    final Color nameColor =
        _isUserStillInGroup(senderId) ? _getUserColor(senderId) : Colors.grey;

    // Avatar logic: only show for the last message in a sequence from a user
    bool showAvatar = false;
    if (!isMe) {
      if (index == messages.length - 1) {
        showAvatar = true;
      } else {
        final prevMessageSender = messages[index + 1]['sender_id']?.toString();
        if (prevMessageSender != senderId) {
          showAvatar = true;
        }
      }
    }

    // Media Logic
    final String? mediaUrlStr = message['media_url']?.toString();
    final bool hasMedia = mediaUrlStr != null && mediaUrlStr.isNotEmpty;
    final List<String> mediaUrls = hasMedia ? mediaUrlStr.split(',') : [];
    final String mediaType = message['media_type']?.toString() ?? 'image';

    final bool hasCaption = content.isNotEmpty &&
        content != '📸 Photo' &&
        content != '🎥 Video' &&
        content.trim() != '';

    return Dismissible(
      key: Key(message['id'].toString()),
      direction: DismissDirection.startToEnd,
      confirmDismiss: (direction) {
        _onSwipeToReply(message);
        return Future.value(false); // Don't actually dismiss the widget
      },
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: const Icon(Icons.reply, color: Color(0xFF4CAF50), size: 24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          mainAxisAlignment:
              isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMe) ...[
              SizedBox(
                width: 30,
                child: showAvatar
                    ? CircleAvatar(
                        radius: 15,
                        backgroundImage:
                            (avatarUrl != null && avatarUrl.isNotEmpty)
                                ? NetworkImage(avatarUrl)
                                : null,
                        child: (avatarUrl == null || avatarUrl.isEmpty)
                            ? const Icon(Icons.person,
                                size: 18, color: Colors.white)
                            : null,
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Container(
                constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.75),
                decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.circular(16).copyWith(
                    bottomRight: const Radius.circular(16),
                    topLeft: !isMe && showAvatar
                        ? const Radius.circular(2)
                        : const Radius.circular(16),
                    topRight: isMe
                        ? const Radius.circular(2)
                        : const Radius.circular(16),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16).copyWith(
                    bottomRight: const Radius.circular(16),
                    topLeft: !isMe && showAvatar
                        ? const Radius.circular(2)
                        : const Radius.circular(16),
                    topRight: isMe
                        ? const Radius.circular(2)
                        : const Radius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 1. REPLY UI SECTION
                      if (message['reply_to_id'] != null)
                        Builder(
                          builder: (context) {
                            final origMsgId = message['reply_to_id'].toString();
                            final origMsg = messages.firstWhere(
                              (m) => m['id'].toString() == origMsgId,
                              orElse: () => <String, dynamic>{},
                            );

                            String replySenderName = 'User';
                            Color replyNameColor = const Color(0xFF4CAF50);

                            if (origMsg.isNotEmpty) {
                              final origSenderId =
                                  origMsg['sender_id']?.toString() ?? '';
                              if (origSenderId == myId) {
                                replySenderName = 'You';
                              } else {
                                final origProfile = _memberProfiles.firstWhere(
                                  (p) => p['id'].toString() == origSenderId,
                                  orElse: () => {'username': 'User'},
                                );
                                replySenderName =
                                    origProfile['username']?.toString() ??
                                        'User';
                                replyNameColor = _getUserColor(origSenderId);
                              }
                            }

                            return GestureDetector(
                              onTap: () => _scrollToMessage(
                                  message['reply_to_id'], messages),
                              child: Container(
                                margin: const EdgeInsets.all(4),
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black26,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border(
                                    left: BorderSide(
                                        color: replyNameColor, width: 3),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      replySenderName == 'You'
                                          ? 'You'
                                          : '@$replySenderName',
                                      style: TextStyle(
                                        color: replyNameColor,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      message['reply_content'] ??
                                          'Original message',
                                      style: const TextStyle(
                                          color: Colors.white54, fontSize: 12),
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),

                      // 2. SENDER NAME (For Groups)
                      if (widget.isGroup && !isMe && showAvatar)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                          child: Text('@$senderName',
                              style: TextStyle(
                                  color: nameColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold)),
                        ),

                      // 3. MEDIA SECTION
                      if (hasMedia)
                        Container(
                          decoration: BoxDecoration(
                            border: hasCaption
                                ? Border(
                                    bottom: BorderSide(
                                        color: isMe
                                            ? const Color(0xFF388E3C)
                                            : const Color(0xFF182025),
                                        width: 1.5))
                                : null,
                          ),
                          child: _buildMediaWithOverlay(
                              mediaUrls,
                              mediaType,
                              timeStr,
                              isMe,
                              isRead,
                              message // Fixed: 6th argument added here
                              ),
                        ),

                      // 4. TEXT & TIMESTAMP SECTION
                      if (hasCaption || (!hasMedia && content.isNotEmpty))
                        _buildTextAndTimestamp(content, timeStr, isMe, isRead),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

// --- SUB-WIDGET: COMPACT MEDIA ---
  Widget _buildCompactMedia(
      List<String> urls, String type, Map<String, dynamic> message) {
    // Use the 'type' parameter passed from the parent and the 'message' map
    return urls.length == 1
        ? _buildSingleMediaItem(urls[0], type, urls, 0, message)
        : _buildMediaCollage(urls, type, message);
  }

  Widget _buildSingleMediaItem(String url, String mediaType,
      List<String> allUrls, int index, Map<String, dynamic> message,
      {double? height}) {
    final String? thumbUrl = message['thumbnail_url'];
    final int? sizeInBytes = message['file_size_bytes'];
    final String sizeLabel = sizeInBytes != null
        ? "${(sizeInBytes / 1024 / 1024).toStringAsFixed(1)} MB"
        : "";

    return GestureDetector(
      onTap: () => _openFullScreen(allUrls, mediaType, index),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            constraints: BoxConstraints(maxHeight: height ?? 180),
            width: double.infinity,
            child: CachedNetworkImage(
              imageUrl:
                  (mediaType == 'video' && thumbUrl != null) ? thumbUrl : url,
              fit: BoxFit.cover,
              placeholder: (context, url) => Container(color: Colors.grey[900]),
            ),
          ),
          // WhatsApp-style Video/Size Overlay
          if (mediaType == 'video')
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.play_arrow, color: Colors.white, size: 18),
                  if (sizeLabel.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Text(sizeLabel,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12)),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMediaWithOverlay(List<String> urls, String type, String time,
      bool isMe, bool isRead, Map<String, dynamic> message) {
    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        _buildCompactMedia(urls, type, message), // Passing message through
        _buildMediaTime(time, isMe, isRead),
      ],
    );
  }

// --- SUB-WIDGET: TEXT & TIME (For standard bubbles) ---
  Widget _buildTextAndTimestamp(
      String text, String time, bool isMe, bool isRead) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 4, 8, 4),
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 12, // Horizontal gap
        runSpacing: 2, // Vertical gap if it wraps
        children: [
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 15)),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(time,
                  style: TextStyle(
                      color: Colors.white.withOpacity(0.5), fontSize: 10)),
              if (isMe) ...[
                const SizedBox(width: 4),
                Icon(isRead ? Icons.done_all : Icons.done,
                    size: 14,
                    color: isRead ? const Color(0xFF53BDEB) : Colors.white54),
              ],
            ],
          ),
        ],
      ),
    );
  }

// Helper for time on top of images
  Widget _buildMediaTime(String time, bool isMe, bool isRead) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.black45, // Legibility overlay[cite: 11]
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(time,
                  style: const TextStyle(color: Colors.white, fontSize: 9)),
              if (isMe) ...[
                const SizedBox(width: 3),
                Icon(isRead ? Icons.done_all : Icons.done,
                    size: 12,
                    color: isRead ? Colors.blueAccent : Colors.white70),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // --- NEW HELPER METHODS FOR THE COLLAGE ---
  Widget _buildMediaCollage(
      List<String> urls, String mediaType, Map<String, dynamic> message) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 4,
        mainAxisSpacing: 4,
      ),
      itemCount: urls.length > 4 ? 4 : urls.length,
      itemBuilder: (context, index) {
        if (index == 3 && urls.length > 4) {
          return GestureDetector(
            onTap: () => _openFullScreen(urls, mediaType, index),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  imageUrl: urls[index],
                  fit: BoxFit.cover,
                  placeholder: (context, url) =>
                      Container(color: Colors.grey[900]),
                ),
                Container(
                  color: Colors.black54,
                  alignment: Alignment.center,
                  child: Text('+${urls.length - 4}',
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
        }
        // FIXED: Passing 'message' as the 5th argument here
        return _buildSingleMediaItem(
            urls[index], mediaType, urls, index, message);
      },
    );
  }

  // Update this method in your ChatRoomScreen state
  // This replaces _openFullScreenGlobal to support the collage swiping
  void _openFullScreen(List<String> urls, String type, int index) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenMediaPlayer(
          mediaUrls: urls,
          mediaType: type,
          initialIndex: index,
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

                // Creator Section
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
                    subtitle: const Text('Creator',
                        style: TextStyle(
                            color: Colors.amberAccent,
                            fontWeight: FontWeight.bold)),
                  ),
                  const Divider(color: Colors.white24),
                ],

                // Members Section
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
                  onChanged: (value) =>
                      setState(() => _memberSearchQuery = value),
                ),

                const SizedBox(height: 12),

                ListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: filteredMembers.length,
                  itemBuilder: (context, index) {
                    final member = filteredMembers[index];
                    final userId = member['id'].toString();
                    final isCreator = userId == _creatorId;
                    final isAdmin = _participants.any((p) =>
                        p['user_id']?.toString() == userId &&
                        (p['role'] == 'admin' || p['is_admin'] == true));

                    final hasStory = false; // TODO: Implement story check

                    return ListTile(
                      onTap: () {
                        Navigator.pop(context);
                        UniversalProfileCard.show(context, userId);
                      },
                      leading: Container(
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: hasStory
                                ? const Color(0xFF4CAF50)
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: CircleAvatar(
                          radius: 24,
                          backgroundImage: member['avatar_url'] != null
                              ? NetworkImage(member['avatar_url'])
                              : null,
                          child: member['avatar_url'] == null
                              ? Text(
                                  (member['username'] ?? 'U')[0].toUpperCase(),
                                  style: const TextStyle(color: Colors.white),
                                )
                              : null,
                        ),
                      ),
                      title: Text(
                        '@${member['username'] ?? 'User'}',
                        style: const TextStyle(color: Colors.white),
                      ),
                      subtitle: Row(
                        children: [
                          Text(
                            member['school_name'] ?? '',
                            style: const TextStyle(color: Colors.white54),
                          ),
                          if (isCreator)
                            const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Text('• Creator',
                                  style: TextStyle(
                                      color: Colors.amberAccent,
                                      fontWeight: FontWeight.bold)),
                            )
                          else if (isAdmin)
                            const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Text('• Admin',
                                  style: TextStyle(
                                      color: Color(0xFF4CAF50),
                                      fontWeight: FontWeight.bold)),
                            ),
                        ],
                      ),
                      trailing: _isGroupCreator && !isCreator
                          ? IconButton(
                              icon: const Icon(Icons.person_remove,
                                  color: Colors.redAccent),
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    backgroundColor: Colors.grey[900],
                                    title: const Text('Remove User?'),
                                    content: Text(
                                        'Remove @${member['username']} from group?'),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(ctx, false),
                                          child: const Text('Cancel')),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(ctx, true),
                                        child: const Text('Remove',
                                            style:
                                                TextStyle(color: Colors.red)),
                                      ),
                                    ],
                                  ),
                                );

                                if (confirm == true) {
                                  await supabase
                                      .from('chat_participants')
                                      .delete()
                                      .match({
                                    'chat_id': widget.chatId,
                                    'user_id': userId,
                                  });
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                          content: Text(
                                              '${member['username']} removed')),
                                    );
                                    _loadChatMeta();
                                  }
                                }
                              },
                            )
                          : null,
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

  // NEW: Checks if user scrolled up
  void _scrollListener() {
    if (_scrollController.offset >= 300 && !_showScrollToBottom) {
      setState(() => _showScrollToBottom = true);
    } else if (_scrollController.offset < 300 && _showScrollToBottom) {
      setState(() => _showScrollToBottom = false);
    }
  }

  // NEW: Jumps back to the present chat
  void _scrollToBottom() {
    _scrollController.animateTo(
      0.0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  @override
  void dispose() {
    _scrollController.removeListener(_scrollListener); // NEW
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
      appBar: _buildAppBar(), // Now correctly calls the updated AppBar
      body: Stack(
        children: [
          Column(
            children: [
              Expanded(
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: _messageStream,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(
                          child: CircularProgressIndicator(
                              color: Color(0xFF4CAF50)));
                    }
                    final messages = snapshot.data!;
                    return ListView.builder(
                      controller: _scrollController,
                      reverse: true,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      itemCount: messages.length,
                      itemBuilder: (_, index) {
                        final msg = messages[index];
                        final date =
                            DateTime.parse(msg['created_at']).toLocal();

                        bool showDateHeader = false;
                        if (index == messages.length - 1) {
                          showDateHeader = true;
                        } else {
                          final prevDate =
                              DateTime.parse(messages[index + 1]['created_at'])
                                  .toLocal();
                          if (date.day != prevDate.day ||
                              date.month != prevDate.month ||
                              date.year != prevDate.year) {
                            showDateHeader = true;
                          }
                        }

                        return Column(
                          children: [
                            if (showDateHeader)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 12),
                                child: Center(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.grey[850]!.withOpacity(0.7),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Text(
                                      _getDateLabel(date),
                                      style: const TextStyle(
                                          color: Colors.white70, fontSize: 11),
                                    ),
                                  ),
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
              _buildInputBar(),
            ],
          ),
          if (_showScrollToBottom)
            Positioned(
              bottom: 80,
              right: 16,
              child: GestureDetector(
                onTap: _scrollToBottom,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF202C33),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.5),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      )
                    ],
                  ),
                  child: const Icon(Icons.keyboard_double_arrow_down,
                      color: Colors.white, size: 24),
                ),
              ),
            ),
        ],
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
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_replyMessage != null) _buildReplyPreview(),
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
                    onChanged: _handleTyping, // Hooked up to remove the warning
                    style: const TextStyle(color: Colors.white),
                    maxLines: 5,
                    minLines: 1,
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
                IconButton(
                  icon: const Icon(Icons.send, color: Color(0xFF4CAF50)),
                  onPressed: _sendMessage,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class FullScreenMediaPlayer extends StatefulWidget {
  final List<String> mediaUrls;
  final String mediaType;
  final int initialIndex;

  const FullScreenMediaPlayer({
    super.key,
    required this.mediaUrls,
    required this.mediaType,
    this.initialIndex = 0,
  });

  @override
  State<FullScreenMediaPlayer> createState() => _FullScreenMediaPlayerState();
}

class _FullScreenMediaPlayerState extends State<FullScreenMediaPlayer> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialIndex);

    // Only initializing video if it's a video type (assuming single video for now)
    if (widget.mediaType == 'video' && widget.mediaUrls.isNotEmpty) {
      _initVideo(widget.mediaUrls.first);
    }
  }

  void _initVideo(String url) {
    _controller = VideoPlayerController.networkUrl(Uri.parse(url))
      ..initialize().then((_) {
        if (mounted) {
          setState(() => _isInitialized = true);
          _controller?.play();
        }
      }).catchError((e) {
        debugPrint("Video init error: $e");
      });
  }

  @override
  void dispose() {
    _controller?.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: const Key('media_player_dismiss'),
      direction: DismissDirection.vertical,
      onDismissed: (_) => Navigator.pop(context),
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        extendBodyBehindAppBar: true, // Lets image take full screen
        body: Center(
          child: widget.mediaType == 'video'
              ? _isInitialized && _controller != null
                  ? AspectRatio(
                      aspectRatio: _controller!.value.aspectRatio,
                      child: VideoPlayer(_controller!),
                    )
                  : const CircularProgressIndicator(color: Color(0xFF4CAF50))
              : PageView.builder(
                  controller: _pageController,
                  itemCount: widget.mediaUrls.length,
                  itemBuilder: (context, index) {
                    return InteractiveViewer(
                      child: Image.network(
                        widget.mediaUrls[index],
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => const Center(
                          child: Text(
                            'Failed to load image',
                            style: TextStyle(color: Colors.white),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
        floatingActionButton: widget.mediaType == 'video' &&
                _isInitialized &&
                _controller != null
            ? FloatingActionButton(
                backgroundColor: const Color(0xFF4CAF50),
                onPressed: () {
                  setState(() {
                    _controller!.value.isPlaying
                        ? _controller!.pause()
                        : _controller!.play();
                  });
                },
                child: Icon(
                  _controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                  color: Colors.black,
                ),
              )
            : null,
      ),
    );
  }
}
