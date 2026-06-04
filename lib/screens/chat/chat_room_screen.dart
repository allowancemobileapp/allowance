// lib/screens/chat/chat_room_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/chat/create_group_screen.dart';
import 'package:allowance/screens/home/story_viewer_screen.dart';
import 'package:allowance/widgets/universal_profile_card.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../shared/services/fcm_service.dart';
import '../../shared/services/chat_local_db.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:http/http.dart' as http;

class ChatRoomScreen extends StatefulWidget {
  final String chatId;
  final String chatTitle;
  final bool isAdmin;
  final UserPreferences userPreferences;
  final bool isGroup; // ADD THIS
  final String? creatorId; // ADD THIS

  const ChatRoomScreen({
    super.key,
    required this.chatId,
    required this.chatTitle,
    required this.isAdmin,
    required this.userPreferences,
    this.isGroup = false, // ADD THIS
    this.creatorId, // ADD THIS
  });

  @override
  State<ChatRoomScreen> createState() => _ChatRoomScreenState();
}

class _ChatRoomScreenState extends State<ChatRoomScreen> {
  final supabase = Supabase.instance.client;
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _memberSearchController = TextEditingController();
  final FocusNode _focusNode = FocusNode(); // <--- KEEPS KEYBOARD STABLE
  final Map<String, Uint8List> _chatVideoThumbCache = {};
  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  String _recordDuration = "00:00";
  Timer? _recordTimer;
  int _recordSeconds = 0;

  bool _isTyping = false;
  bool _remoteUserIsTyping = false;
  Timer? _typingTimer;
  List<Map<String, dynamic>> _messages = [];
  RealtimeChannel? _realtimeChannel;
  Timer? _remoteTypingTimer;

  Map<String, dynamic>? _chatMeta;
  List<Map<String, dynamic>> _participants = [];
  List<Map<String, dynamic>> _memberProfiles = [];
  String? _creatorId;
  bool _isGroupCreator = false;
  Map<String, dynamic>? _replyMessage;
  bool _showScrollToBottom = false;

  // For colored usernames
  final Map<String, Color> _userColors = {};
  final Map<String, List<InlineSpan>> _regexCache = {};
  String _memberSearchQuery = '';
  String? _highlightedMessageId;

  @override
  void initState() {
    super.initState();
    activeChatId = widget.chatId;

    // 🔥 FIX: Instantly populate the UI with the data we already know!
    _chatMeta = {
      'group_name': widget.chatTitle,
      'group_avatar': null, // Will update when network loads
      'group_description': 'Loading group info...',
    };

    _scrollController.addListener(_scrollListener);
    _setupMessageStream();
    _loadChatMeta();
    _setupTypingListener();
    _markMessagesAsRead();
  }

  Future<void> _loadChatMeta() async {
    try {
      // 1. Instantly load from cache to stop jitter
      final prefs = await SharedPreferences.getInstance();
      final cachedParticipants =
          prefs.getString('cached_parts_${supabase.auth.currentUser!.id}');
      if (cachedParticipants != null && mounted) {
        final allParts =
            List<Map<String, dynamic>>.from(jsonDecode(cachedParticipants));
        final myGroupParts = allParts
            .where((p) => p['chat_id'].toString() == widget.chatId)
            .toList();
        if (myGroupParts.isNotEmpty) {
          setState(() => _participants = myGroupParts);
        }
      }

      // 2. Fetch fresh data silently
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

      final Set<String> userIdsToFetch = participants
          .map((p) => p['user_id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toSet();

      final msgResp = await supabase
          .from('messages')
          .select('sender_id')
          .eq('chat_id', widget.chatId)
          .limit(200);
      for (var m in msgResp as List) {
        if (m['sender_id'] != null)
          userIdsToFetch.add(m['sender_id'].toString());
      }

      List<Map<String, dynamic>> profiles = [];
      if (userIdsToFetch.isNotEmpty) {
        final profileResp = await supabase
            .from('profiles')
            .select('id, username, avatar_url, school_name')
            .inFilter('id', userIdsToFetch.toList());
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

          // 🔥 THE FIX: Auto-kill the typing indicator after 5 seconds!
          // If their app crashes or loses internet, this cures the "Ghost Typing"
          if (remoteTyping) {
            _remoteTypingTimer?.cancel();
            _remoteTypingTimer = Timer(const Duration(seconds: 5), () {
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
    final myId = supabase.auth.currentUser?.id;
    if (myId == null || _isTyping == status) return;

    // 🔥 FIX 1: Removed setState()! The UI doesn't need to rebuild
    // just because we are telling the database we are typing.
    _isTyping = status;

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

  // =========================================================================
  // VOICE NOTE LOGIC (WEB & MOBILE SAFE)
  // =========================================================================
  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        String? filePath;

        // 🔥 FIX: Web doesn't use file paths. Mobile does.
        if (!kIsWeb) {
          final dir = await getApplicationDocumentsDirectory();
          filePath =
              '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
        }

        // Passing empty string for path on web triggers the browser blob memory
        await _audioRecorder.start(
            const RecordConfig(encoder: AudioEncoder.aacLc),
            path: filePath ?? '');

        setState(() {
          _isRecording = true;
          _recordSeconds = 0;
          _recordDuration = "00:00";
        });

        _recordTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
          if (!mounted) return;
          setState(() {
            _recordSeconds++;
            final minutes =
                (_recordSeconds / 60).floor().toString().padLeft(2, '0');
            final seconds = (_recordSeconds % 60).toString().padLeft(2, '0');
            _recordDuration = "$minutes:$seconds";
          });
        });
      }
    } catch (e) {
      debugPrint("Recording error: $e");
    }
  }

  Future<void> _stopAndSendRecording() async {
    _recordTimer?.cancel();
    if (!mounted) return;
    setState(() => _isRecording = false);

    final path = await _audioRecorder.stop();
    if (path != null && _recordSeconds >= 1) {
      // Prevents accidental 0-second taps
      _uploadAndSendAudio(path);
    }
  }

  Future<void> _uploadAndSendAudio(String filePath) async {
    try {
      Uint8List bytes;

      // 🔥 FIX: Fetch bytes from browser blob on Web, or read file on Mobile
      if (kIsWeb) {
        final response = await http.get(Uri.parse(filePath));
        bytes = response.bodyBytes;
      } else {
        bytes = await File(filePath).readAsBytes();
      }

      final fileName = 'vn_${DateTime.now().millisecondsSinceEpoch}.m4a';
      final storagePath = 'chat_media/${widget.chatId}/$fileName';

      await supabase.storage.from('chat_media').uploadBinary(storagePath, bytes,
          fileOptions: const FileOptions(contentType: 'audio/m4a'));

      final publicUrl =
          supabase.storage.from('chat_media').getPublicUrl(storagePath);

      final myId = supabase.auth.currentUser?.id;
      if (myId == null) return;

      await supabase.from('messages').insert({
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': '🎤 Voice Note',
        'media_url': publicUrl,
        'media_type': 'audio',
        'file_size_bytes': bytes.length,
        'is_read': false,
      });
    } catch (e) {
      debugPrint("Voice note upload error: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to send voice note')));
      }
    }
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
    _focusNode.requestFocus();
    setState(() => _replyMessage = null);

    setState(() {
      _messages.insert(0, {
        'id': DateTime.now().millisecondsSinceEpoch,
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': text.isNotEmpty ? text : ' ',
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

    try {
      final Map<String, dynamic> payload = {
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': text.isNotEmpty ? text : ' ',
        'is_read': false,
        if (mediaUrl != null) 'media_url': mediaUrl,
        if (type != null) 'media_type': type,
        if (thumbUrl != null) 'thumbnail_url': thumbUrl,
        if (size != null) 'file_size_bytes': size,
      };

      if (replyId != null) {
        payload['reply_to_id'] = replyId;
        payload['reply_content'] = replySummary;
      }

      await supabase.from('messages').insert(payload);
      await supabase.from('chats').update({
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'last_message': text.isNotEmpty ? text : 'New message',
      }).eq('id', widget.chatId);

      // 🔥 THE FIX: TAGGING / MENTIONS LOGIC (Dart Syntax Fixed)
      if (text.contains('@') && widget.isGroup) {
        final RegExp mentionRegex = RegExp(r'@([a-zA-Z0-9_]+)');
        final Iterable<RegExpMatch> matches = mentionRegex.allMatches(text);
        final List<String> mentionedUsernames =
            matches.map((m) => m.group(1) ?? '').toList();

        for (var username in mentionedUsernames) {
          if (username.isEmpty) continue;
          final targetProfile = _memberProfiles.firstWhere(
            (p) =>
                p['username']?.toString().toLowerCase() ==
                username.toLowerCase(),
            orElse: () => <String, dynamic>{},
          );

          if (targetProfile.isNotEmpty && targetProfile['id'] != myId) {
            await supabase.from('notifications').insert({
              'user_id': targetProfile['id'],
              'title': 'You were mentioned!',
              'body':
                  '@${widget.userPreferences.username} mentioned you in ${widget.chatTitle}: "$text"',
              'data': {
                'type': 'chat',
                'chat_id': widget.chatId,
                'sender_id': myId
              },
              'sent_at': DateTime.now().toUtc().toIso8601String()
            });
          }
        }
      }
    } catch (e) {
      debugPrint('Send error: $e');
      if (mounted) setState(() => _replyMessage = currentReply);
    }
  }

  // Update this method to handle the jump logic correctly

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
            if (allowFiles)
              _menuTile(Icons.insert_drive_file, 'Add File', () async {
                Navigator.pop(ctx);
                await _pickAndUploadFile();
              }),
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

  void _showChatMenu() {
    final rules = _chatMeta?['rules'] as Map<String, dynamic>? ?? {};
    final bool allowShareLink = rules['share_link'] ?? false;

    final myId = supabase.auth.currentUser?.id;
    final amICreator = myId == _creatorId;
    final amIAdmin = _participants
        .any((p) => p['user_id']?.toString() == myId && p['role'] == 'admin');

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
              // 🔥 THE FIX: Allows Admins & Creators to ADD members
              if (amICreator || amIAdmin)
                _menuTile(Icons.person_add, 'Add Members', () {
                  Navigator.pop(ctx);
                  _showAddMemberSheet();
                }, color: const Color(0xFF4CAF50)),

              if (amICreator)
                _menuTile(Icons.edit, 'Edit Group', () async {
                  Navigator.pop(ctx);
                  await _editGroup();
                }),

              if (allowShareLink)
                _menuTile(Icons.link, 'Copy Group Link', () async {
                  Navigator.pop(ctx);
                  final link = 'allowance://group/${widget.chatId}';
                  await Clipboard.setData(ClipboardData(text: link));
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Group link copied!')));
                  }
                }),

              _menuTile(Icons.logout, 'Leave Group', () {
                Navigator.pop(ctx);
                _confirmLeaveGroup();
              }, color: Colors.orangeAccent),

              if (amICreator)
                _menuTile(Icons.delete_forever, 'Delete Group', () {
                  Navigator.pop(ctx);
                  _confirmDeleteGroup();
                }, color: Colors.redAccent),
            ],
            StatefulBuilder(
              builder: (context, setModalState) => ListTile(
                leading: Icon(
                  widget.userPreferences.autoDownloadMedia
                      ? Icons.file_download_done
                      : Icons.file_download,
                  color: const Color(0xFF4CAF50),
                ),
                title: const Text('Auto-Download Media',
                    style: TextStyle(color: Colors.white)),
                trailing: Switch(
                  value: widget.userPreferences.autoDownloadMedia,
                  activeColor: const Color(0xFF4CAF50),
                  onChanged: (val) async {
                    setModalState(
                        () => widget.userPreferences.autoDownloadMedia = val);
                    setState(() {});
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

  // 🔥 THE FIX: Opens a list of users to add to the group
  void _showAddMemberSheet() async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: Text('Add Members',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
            ),
            const Divider(color: Colors.white24),
            Expanded(
              child: FutureBuilder<List<dynamic>>(
                // Fetch people the user follows
                future: supabase
                    .from('followers')
                    .select('profiles!following_id(id, username, avatar_url)')
                    .eq('follower_id', myId),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting)
                    return const Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFF4CAF50)));
                  final friends = snapshot.data ?? [];
                  if (friends.isEmpty)
                    return const Center(
                        child: Text("Follow people to add them",
                            style: TextStyle(color: Colors.white54)));

                  return ListView.builder(
                    controller: scrollController,
                    itemCount: friends.length,
                    itemBuilder: (context, index) {
                      final profile = friends[index]['profiles'];
                      if (profile == null) return const SizedBox.shrink();

                      final isAlreadyInGroup = _participants
                          .any((p) => p['user_id'] == profile['id']);

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: Colors.grey[800],
                          backgroundImage: profile['avatar_url'] != null
                              ? NetworkImage(profile['avatar_url'])
                              : null,
                          child: profile['avatar_url'] == null
                              ? const Icon(Icons.person, color: Colors.white54)
                              : null,
                        ),
                        title: Text(profile['username'] ?? 'Unknown',
                            style: const TextStyle(color: Colors.white)),
                        trailing: isAlreadyInGroup
                            ? const Text('Added',
                                style: TextStyle(color: Colors.white38))
                            : ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF4CAF50),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(12))),
                                onPressed: () async {
                                  try {
                                    await supabase
                                        .from('chat_participants')
                                        .insert({
                                      'chat_id': widget.chatId,
                                      'user_id': profile['id']
                                    });
                                    await _sendSystemMessage(
                                        'Admin added @${profile['username']}');
                                    await _loadChatMeta(); // Refresh list behind the scenes
                                    if (mounted) Navigator.pop(ctx);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                            content: Text(
                                                'Added @${profile['username']}!')));
                                  } catch (e) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                            content:
                                                Text('Failed to add user.')));
                                  }
                                },
                                child: const Text('Add',
                                    style: TextStyle(
                                        color: Colors.black,
                                        fontWeight: FontWeight.bold)),
                              ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

// Helper widget for clean code
  Widget _menuTile(IconData icon, String title, VoidCallback onTap,
      {Color? color}) {
    return ListTile(
      leading: Icon(icon, color: color ?? Colors.white70),
      title: Text(title, style: TextStyle(color: color ?? Colors.white)),
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

  // --- NEW: MEMBER OPTIONS & ADMIN PRIVILEGES ---
  // --- FIX: REMOVED is_admin, RELIES ONLY ON role = 'admin' ---
  void _showMemberOptions(Map<String, dynamic> member) {
    final targetUserId = member['id'].toString();
    final myId = supabase.auth.currentUser?.id;

    final amICreator = myId == _creatorId;
    final amIAdmin = _participants
        .any((p) => p['user_id']?.toString() == myId && p['role'] == 'admin');

    final isTargetCreator = targetUserId == _creatorId;
    final isTargetAdmin = _participants.any((p) =>
        p['user_id']?.toString() == targetUserId && p['role'] == 'admin');

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.person, color: Colors.white),
            title: const Text('View Profile',
                style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(ctx);
              Navigator.pop(context); // Close the group info sheet too
              UniversalProfileCard.show(
                  context, targetUserId, widget.userPreferences);
            },
          ),
          if (amICreator && !isTargetCreator && !isTargetAdmin)
            ListTile(
              leading: const Icon(Icons.admin_panel_settings,
                  color: Color(0xFF4CAF50)),
              title: const Text('Make Admin',
                  style: TextStyle(color: Color(0xFF4CAF50))),
              onTap: () async {
                Navigator.pop(ctx);
                await _updateMemberRole(targetUserId, 'admin');
              },
            ),
          if (amICreator && !isTargetCreator && isTargetAdmin)
            ListTile(
              leading: const Icon(Icons.remove_moderator, color: Colors.orange),
              title: const Text('Dismiss as Admin',
                  style: TextStyle(color: Colors.orange)),
              onTap: () async {
                Navigator.pop(ctx);
                await _updateMemberRole(targetUserId, 'member');
              },
            ),
          if ((amICreator || amIAdmin) &&
              !isTargetCreator &&
              targetUserId != myId)
            ListTile(
              leading: const Icon(Icons.person_remove, color: Colors.redAccent),
              title: const Text('Remove from Group',
                  style: TextStyle(color: Colors.redAccent)),
              onTap: () async {
                Navigator.pop(ctx);
                _removeMember(targetUserId, member['username']);
              },
            ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // --- NEW: SYSTEM MESSAGE HELPER ---
  Future<void> _sendSystemMessage(String content) async {
    try {
      await supabase.from('messages').insert({
        'chat_id': widget.chatId,
        'sender_id': supabase.auth.currentUser!.id,
        'content': content,
        'media_type': 'system', // Triggers the center label
        'is_read': true,
      });
    } catch (e) {
      debugPrint("System message error: $e");
    }
  }

  Future<void> _confirmLeaveGroup() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title:
            const Text('Leave Group?', style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to leave? You will no longer be able to see new messages.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('CANCEL',
                  style: TextStyle(color: Colors.white54))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('LEAVE',
                style: TextStyle(
                    color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final myId = supabase.auth.currentUser?.id;
      if (myId == null) return;
      try {
        await _sendSystemMessage(
            '@${widget.userPreferences.username} left the group');
        await supabase
            .from('chat_participants')
            .delete()
            .match({'chat_id': widget.chatId, 'user_id': myId});
        if (mounted) Navigator.pop(context); // Exit the chat room
      } catch (e) {
        debugPrint("Leave group error: $e");
      }
    }
  }

  // --- NEW: DELETE GROUP METHOD ---
  Future<void> _confirmDeleteGroup() async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Delete Group?',
            style: TextStyle(color: Colors.redAccent)),
        content: const Text(
          'Are you sure you want to completely delete this group? All messages and media will be permanently removed for everyone.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('CANCEL',
                  style: TextStyle(color: Colors.white54))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('DELETE',
                style: TextStyle(
                    color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        // Because of "ON DELETE CASCADE" in the DB, deleting the chat deletes its messages and participants automatically!
        await supabase.from('chats').delete().eq('id', widget.chatId);
        if (mounted) {
          Navigator.pop(context); // Go back to the chat list screen
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Group deleted successfully.')));
        }
      } catch (e) {
        debugPrint("Delete group error: $e");
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Failed to delete group.')));
      }
    }
  }

  Future<void> _updateMemberRole(String userId, String newRole) async {
    try {
      await supabase.from('chat_participants').update({'role': newRole}).match({
        'chat_id': widget.chatId,
        'user_id': userId,
      });

      final member = _memberProfiles.firstWhere(
          (p) => p['id'].toString() == userId,
          orElse: () => {'username': 'User'});
      await _sendSystemMessage(newRole == 'admin'
          ? '@${member['username']} is now an admin'
          : '@${member['username']} is no longer an admin');

      await _loadChatMeta(); // Refresh UI
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('User is now a $newRole.')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to update role: $e')));
    }
  }

  Future<void> _removeMember(String userId, String username) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title:
            const Text('Remove User?', style: TextStyle(color: Colors.white)),
        content: Text(
            'Are you sure you want to remove @$username from the group?',
            style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('Remove', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await supabase
            .from('chat_participants')
            .delete()
            .match({'chat_id': widget.chatId, 'user_id': userId});
        await _sendSystemMessage('Admin removed @$username');
        await _loadChatMeta();
        if (mounted)
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('@$username removed')));
      } catch (e) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Failed to remove user')));
      }
    }
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
                    onTap: () => _showMemberOptions(
                        creatorProfile), // <-- Tappable creator
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

                const SizedBox(height: 16),

                // --- 3-COLUMN GRID VIEW FOR MEMBERS ---
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 10,
                    mainAxisSpacing: 16,
                    childAspectRatio: 0.80,
                  ),
                  itemCount: filteredMembers.length,
                  itemBuilder: (context, index) {
                    final member = filteredMembers[index];
                    final userId = member['id'].toString();
                    final isCreator = userId == _creatorId;

                    // --- FIX: Relies strictly on `role == 'admin'` ---
                    final isAdmin = _participants.any((p) =>
                        p['user_id']?.toString() == userId &&
                        p['role'] == 'admin');

                    return GestureDetector(
                      onTap: () => _showMemberOptions(member),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircleAvatar(
                            radius: 32,
                            backgroundColor: Colors.grey[800],
                            backgroundImage: member['avatar_url'] != null
                                ? NetworkImage(member['avatar_url'])
                                : null,
                            child: member['avatar_url'] == null
                                ? Text(
                                    (member['username'] ?? 'U')[0]
                                        .toUpperCase(),
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 20))
                                : null,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '@${member['username'] ?? 'User'}',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (isCreator)
                            const Text('Creator',
                                style: TextStyle(
                                    color: Colors.amberAccent,
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold))
                          else if (isAdmin)
                            const Text('Admin',
                                style: TextStyle(
                                    color: Color(0xFF4CAF50),
                                    fontSize: 10,
                                    fontWeight: FontWeight.bold))
                          else
                            Text(
                              member['school_name'] ?? '',
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 10),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
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

  Widget _buildBubble(
      List<Map<String, dynamic>> messages, int index, double maxWidth) {
    final message = messages[index];
    final messageId = message['id'].toString();

    final myId = supabase.auth.currentUser?.id;
    final isMe = message['sender_id']?.toString() == myId;
    final content = (message['content'] ?? '').toString();
    final timeStr = _formatTime(message['created_at']?.toString());
    final isRead = message['is_read'] == true;
    final mediaType = message['media_type']?.toString() ?? 'text';
    final isAudio = mediaType == 'audio';

    // --- SYSTEM MESSAGE RENDERER ---
    if (mediaType == 'system') {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            content,
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                fontStyle: FontStyle.italic),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    final senderId = message['sender_id']?.toString() ?? '';
    final senderProfile = _memberProfiles.firstWhere(
      (p) => p['id'].toString() == senderId,
      orElse: () => {'username': 'User', 'avatar_url': null},
    );

    final senderName = senderProfile['username']?.toString() ?? 'User';
    final avatarUrl = senderProfile['avatar_url']?.toString();
    final bool isStillInGroup = _isUserStillInGroup(senderId);

    final bubbleColor =
        isMe ? const Color(0xFF4CAF50) : const Color(0xFF202C33);
    final Color nameColor =
        isStillInGroup ? _getUserColor(senderId) : Colors.grey;

    bool showAvatar = false;
    if (!isMe) {
      if (index == messages.length - 1) {
        showAvatar = true;
      } else {
        final prevMessage = messages[index + 1];
        if (prevMessage['sender_id']?.toString() != senderId ||
            prevMessage['media_type'] == 'system') {
          showAvatar = true;
        }
      }
    }

    final String? mediaUrlStr = message['media_url']?.toString();
    final bool hasMedia = mediaUrlStr != null && mediaUrlStr.isNotEmpty;
    final List<String> mediaUrls = hasMedia ? mediaUrlStr.split(',') : [];
    final bool isFile = mediaType == 'file';

    final bool hasCaption = content.isNotEmpty &&
        content != '📸 Photo' &&
        content != '🎥 Video' &&
        content != '🎤 Voice Note' &&
        content.trim() != '';
    final bool isHighlighted = _highlightedMessageId == messageId;

    // 🔥 FIX: RepaintBoundary completely removed here for keyboard performance
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 2),
      decoration: BoxDecoration(
        color: isHighlighted
            ? const Color(0xFF4CAF50).withOpacity(0.3)
            : Colors.transparent,
      ),
      child: Dismissible(
        key: Key('dismiss_$messageId'),
        direction: DismissDirection.startToEnd,
        confirmDismiss: (direction) {
          _onSwipeToReply(message);
          return Future.value(false);
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
                          backgroundColor: isStillInGroup
                              ? Colors.grey[800]
                              : Colors.grey[900],
                          child: (avatarUrl == null || avatarUrl.isEmpty)
                              ? const Icon(Icons.person,
                                  size: 18, color: Colors.white54)
                              : null,
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: GestureDetector(
                  onLongPress: () => _showMessageOptions(message, isMe),
                  child: Container(
                    key: ValueKey(messageId),
                    margin:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
                    // 🔥 FIX: We now use the passed-in maxWidth parameter
                    constraints: BoxConstraints(maxWidth: maxWidth),
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
                          if (message['reply_to_id'] != null ||
                              (message['reply_content']?.startsWith('Story_') ??
                                  false))
                            _buildReplyInsideBubble(message),
                          if (widget.isGroup && !isMe && showAvatar)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                              child: Text(
                                  isStillInGroup ? '@$senderName' : senderName,
                                  style: TextStyle(
                                      color: nameColor,
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      fontStyle: isStillInGroup
                                          ? FontStyle.normal
                                          : FontStyle.italic)),
                            ),
                          if (isFile)
                            GestureDetector(
                              onTap: () async {
                                if (mediaUrls.isNotEmpty) {
                                  final uri = Uri.parse(mediaUrls.first);
                                  if (await canLaunchUrl(uri)) {
                                    await launchUrl(uri,
                                        mode: LaunchMode.externalApplication);
                                  } else {
                                    if (mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(const SnackBar(
                                              content:
                                                  Text('Could not open file')));
                                    }
                                  }
                                }
                              },
                              child: Container(
                                margin: const EdgeInsets.symmetric(
                                    vertical: 4, horizontal: 8),
                                constraints: BoxConstraints(maxWidth: maxWidth),
                                decoration: BoxDecoration(
                                    color: Colors.black26,
                                    borderRadius: BorderRadius.circular(8)),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.insert_drive_file,
                                        color: Colors.blueAccent, size: 30),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        content.isNotEmpty
                                            ? content
                                            : 'Document',
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
                            ),
                          if (isAudio && mediaUrls.isNotEmpty)
                            AudioPlayerBubble(
                              url: mediaUrls.first,
                              isMe: isMe,
                              themeColor: const Color(0xFF4CAF50),
                              timeStr: timeStr,
                              isRead: isRead,
                            ),
                          if (hasMedia && !isFile && !isAudio)
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
                              child: _buildMediaWithOverlay(mediaUrls,
                                  mediaType, timeStr, isMe, isRead, message),
                            ),
                          if (!isFile &&
                              !isAudio &&
                              (hasCaption ||
                                  (!hasMedia && content.isNotEmpty)) &&
                              content != '🎤 Voice Note')
                            _buildTextAndTimestamp(
                                content, timeStr, isMe, isRead),
                        ],
                      ),
                    ),
                  ),
                ),
              )
            ],
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

    String displayReplyText = replyContent;
    if (isStoryReply && replyContent.startsWith('Story_')) {
      final parts = replyContent.split('_');
      if (parts.length > 2) {
        displayReplyText = parts.sublist(2).join('_');
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
            if (isStoryReply && storyImageUrl != null)
              ClipRRect(
                borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(8),
                    bottomRight: Radius.circular(8)),
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
    final String? thumbUrl = message['thumbnail_url']?.toString();
    final int? sizeInBytes = message['file_size_bytes'];
    final String sizeLabel = sizeInBytes != null
        ? "${(sizeInBytes / 1024 / 1024).toStringAsFixed(1)} MB"
        : "";

    final bool isVideo = mediaType == 'video';

    Widget mediaWidget;

    // 🔥 THE FIX: Generates video thumbnails automatically!
    if (isVideo) {
      if (thumbUrl != null && thumbUrl.isNotEmpty) {
        mediaWidget = CachedNetworkImage(
            imageUrl: thumbUrl,
            fit: BoxFit.cover,
            errorWidget: (c, u, e) => _buildErrorPlaceholder(true));
      } else if (kIsWeb) {
        // 🔥 WEB FIX: Shows a cool video container instead of an error!
        mediaWidget = Container(
          color: Colors.black87,
          child: const Center(
            child:
                Icon(Icons.play_circle_fill, size: 50, color: Colors.white70),
          ),
        );
      } else if (_chatVideoThumbCache.containsKey(url)) {
        mediaWidget =
            Image.memory(_chatVideoThumbCache[url]!, fit: BoxFit.cover);
      } else {
        mediaWidget = FutureBuilder<Uint8List?>(
            future: VideoThumbnail.thumbnailData(
                video: url,
                imageFormat: ImageFormat.JPEG,
                maxWidth: 250,
                quality: 50),
            builder: (context, snapshot) {
              if (snapshot.hasData && snapshot.data != null) {
                _chatVideoThumbCache[url] = snapshot.data!;
                return Image.memory(snapshot.data!, fit: BoxFit.cover);
              }
              return _buildErrorPlaceholder(true);
            });
      }
    } else {
      mediaWidget = CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.cover,
          errorWidget: (c, u, e) => _buildErrorPlaceholder(false));
    }

    return GestureDetector(
      onTap: () => _openFullScreen(allUrls, mediaType, index),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            constraints: BoxConstraints(maxHeight: height ?? 180),
            width: double.infinity,
            decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius: BorderRadius.circular(8)),
            child: mediaWidget,
          ),
          if (isVideo)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.play_arrow, color: Colors.white, size: 18),
                  if (sizeLabel.isNotEmpty)
                    Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Text(sizeLabel,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12))),
                ],
              ),
            ),
        ],
      ),
    );
  }

  // Small helper to keep the UI clean when images fail
  Widget _buildErrorPlaceholder(bool isVideo) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            isVideo
                ? Icons.videocam_off_outlined
                : Icons.image_not_supported_outlined,
            color: Colors.white24,
            size: 40,
          ),
          const SizedBox(height: 4),
          Text(
            isVideo ? "Video Preview" : "Image error",
            style: const TextStyle(color: Colors.white24, fontSize: 10),
          )
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
      String content, String timeStr, bool isMe, bool isRead) {
    return ExpandableMessageText(
      text: content,
      timeStr: timeStr,
      isMe: isMe,
      isRead: isRead,
      parentContext: context,
      regexCache: _regexCache, // <-- Pass the cache in!
      videoCache:
          _chatVideoThumbCache, // <-- Pass video cache for garbage control!
      username: widget.userPreferences.username ?? '',
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
          // FIX: Ensure the 4th item also uses the thumbnail logic
          final isVideo = mediaType == 'video';
          final String? thumbUrl = message['thumbnail_url']?.toString();
          final String effectiveUrl = isVideo ? (thumbUrl ?? '') : urls[index];

          return GestureDetector(
            onTap: () => _openFullScreen(urls, mediaType, index),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (effectiveUrl.isNotEmpty)
                  CachedNetworkImage(
                    imageUrl: effectiveUrl,
                    fit: BoxFit.cover,
                    placeholder: (context, url) =>
                        Container(color: Colors.grey[900]),
                    errorWidget: (ctx, url, err) =>
                        _buildErrorPlaceholder(isVideo),
                  )
                else
                  _buildErrorPlaceholder(isVideo),
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
      iconTheme: const IconThemeData(
          color: Colors.white), // <--- FIX: White back button
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

  // NEW: Checks if user scrolled up
  void _scrollListener() {
    if (!_scrollController.hasClients) return; // <-- Prevents layout crashes
    if (_scrollController.offset >= 300 && !_showScrollToBottom) {
      setState(() => _showScrollToBottom = true);
    } else if (_scrollController.offset < 300 && _showScrollToBottom) {
      setState(() => _showScrollToBottom = false);
    }
  }

  // NEW: Jumps back to the present chat

  Future<void> _setupMessageStream() async {
    // ⚡ 1. BASTARD SPEED: Instant local load
    final localMessages = await ChatLocalDB.instance
        .getMessagesForChat(widget.chatId, limit: 100);
    if (localMessages.isNotEmpty && mounted) {
      setState(() => _messages = localMessages);
    }

    // 🌐 2. FAST HTTP FETCH: Catch up on missed messages instantly
    try {
      final serverMessages = await supabase
          .from('messages')
          .select()
          .eq('chat_id', widget.chatId)
          .order('created_at', ascending: false)
          .limit(100);

      if (mounted) setState(() => _messages = serverMessages);
      await ChatLocalDB.instance.cacheMessages(widget.chatId, serverMessages);
    } catch (e) {
      debugPrint("HTTP fetch error: $e");
    }

    // 🚀 3. WHATSAPP-SPEED WEBSOCKETS: Listen for instant live updates
    _realtimeChannel = supabase
        .channel('public:messages:${widget.chatId}')
        .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'messages',
            filter: PostgresChangeFilter(
                type: PostgresChangeFilterType.eq,
                column: 'chat_id',
                value: widget.chatId),
            callback: (payload) {
              if (!mounted) return;

              if (payload.eventType == PostgresChangeEvent.insert) {
                final newMsg = payload.newRecord;
                setState(() {
                  // 🔥 FIX 4: OPTIMISTIC UI DUPLICATE KILLER
                  final myId = supabase.auth.currentUser?.id;
                  final isMe = newMsg['sender_id'] == myId;

                  int existingIdx = -1;
                  if (isMe) {
                    // Look for the "fake" message we inserted when we tapped send
                    existingIdx = _messages.indexWhere((m) =>
                        m['sender_id'] == myId &&
                        m['content'] == newMsg['content'] &&
                        (m['id'].toString() == newMsg['id'].toString() ||
                            m['id'].toString().length > 10));
                  } else {
                    existingIdx = _messages.indexWhere(
                        (m) => m['id'].toString() == newMsg['id'].toString());
                  }

                  if (existingIdx != -1) {
                    // Swap the fake message for the real one
                    _messages[existingIdx] = newMsg;
                  } else {
                    // It's a completely new message from someone else
                    _messages.insert(0, newMsg);
                  }
                });
                ChatLocalDB.instance.cacheMessages(widget.chatId, [newMsg]);
              } else if (payload.eventType == PostgresChangeEvent.update) {
                final updatedMsg = payload.newRecord;
                setState(() {
                  final idx = _messages.indexWhere(
                      (m) => m['id'].toString() == updatedMsg['id'].toString());
                  if (idx != -1) _messages[idx] = updatedMsg;
                });
                ChatLocalDB.instance.cacheMessages(widget.chatId, [updatedMsg]);
              } else if (payload.eventType == PostgresChangeEvent.delete) {
                final deletedId = payload.oldRecord['id'].toString();
                setState(() {
                  _messages.removeWhere((m) => m['id'].toString() == deletedId);
                });
              }
            })
        .subscribe();
  }

  @override
  void dispose() {
    if (activeChatId == widget.chatId) {
      activeChatId = null;
    }
    _realtimeChannel?.unsubscribe();
    _scrollController.removeListener(_scrollListener);
    _memberSearchController.dispose(); // <-- Unique to ChatRoomScreen
    _typingTimer?.cancel();
    _remoteTypingTimer?.cancel();

    // 🔥 THE FIX: Tell the database we stopped typing when we leave the chat!
    final myId = supabase.auth.currentUser?.id;
    if (myId != null && _isTyping) {
      supabase.from('chat_participants').update({
        'is_typing': false,
      }).match({'chat_id': widget.chatId, 'user_id': myId});
    }

    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _audioRecorder.dispose();
    _recordTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final double maxBubbleWidth = MediaQuery.sizeOf(context).width * 0.75;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _buildAppBar(),
      // 🔥 FIX: Removed SafeArea from body. Scaffold automatically avoids the keyboard.
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              // 🔥 FIX: Tapping the chat background instantly closes the keyboard smoothly
              onTap: () => FocusScope.of(context).unfocus(),
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
                          // 🔥 FIX: TURNED OFF REPAINT BOUNDARIES to free up massive GPU memory
                          addRepaintBoundaries: false,
                          addAutomaticKeepAlives: false,
                          // 🔥 FIX: Let Flutter handle dismissing naturally when you swipe down
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
          ),
          // 🔥 FIX: We only put the SafeArea around the input bar to protect it from the iPhone Home bar!
          _buildInputBar(),
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyMessage != null) _buildReplyPreview(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Hide the '+' button while recording to save space
              if (!_isRecording)
                IconButton(
                  icon: const Icon(Icons.add, color: Color(0xFF4CAF50)),
                  onPressed: _showPlusOptions,
                ),

              Expanded(
                child: _isRecording
                    ? Container(
                        height: 48,
                        margin: const EdgeInsets.only(bottom: 2),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1C1C1E),
                          borderRadius: BorderRadius.circular(24),
                        ),
                        child: Row(
                          children: [
                            // 🔴 CANCEL BUTTON
                            GestureDetector(
                              onTap: () {
                                _recordTimer?.cancel();
                                _audioRecorder.stop();
                                setState(() => _isRecording = false);
                                HapticFeedback.vibrate();
                              },
                              child: const Icon(Icons.delete,
                                  color: Colors.redAccent, size: 26),
                            ),
                            const SizedBox(width: 12),
                            Text("Recording: $_recordDuration",
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold)),
                            const Spacer(),
                            const Text("Tap to send ->",
                                style: TextStyle(
                                    color: Colors.white38, fontSize: 12)),
                          ],
                        ),
                      )
                    : TextField(
                        controller: _messageController,
                        focusNode: _focusNode,
                        style: const TextStyle(color: Colors.white),
                        maxLines: 5,
                        minLines: 1,
                        textInputAction: TextInputAction.newline,
                        keyboardType: TextInputType.multiline,
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

              // THE MAGIC BUTTON (Swaps between Send and Mic)
              if (_isRecording)
                // 🟢 EXPLICIT SEND BUTTON FOR VOICE NOTES
                GestureDetector(
                  onTap: () {
                    HapticFeedback.lightImpact();
                    _stopAndSendRecording();
                  },
                  child: Container(
                    margin: const EdgeInsets.only(left: 8, bottom: 4),
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(
                      color: Color(0xFF4CAF50),
                      shape: BoxShape.circle,
                    ),
                    child:
                        const Icon(Icons.send, color: Colors.black, size: 24),
                  ),
                )
              else
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _messageController,
                  builder: (context, value, child) {
                    final hasText = value.text.trim().isNotEmpty;

                    if (hasText) {
                      // SHOW SEND TEXT BUTTON
                      return IconButton(
                        icon: const Icon(Icons.send, color: Color(0xFF4CAF50)),
                        onPressed: () => _sendMessage(),
                      );
                    } else {
                      // 🎤 TAP TO RECORD BUTTON (Web Safe)
                      return GestureDetector(
                        onTap: () {
                          HapticFeedback.heavyImpact();
                          _startRecording();
                        },
                        child: Container(
                          margin: const EdgeInsets.only(left: 8, bottom: 4),
                          padding: const EdgeInsets.all(10),
                          decoration: const BoxDecoration(
                            color: Color(0xFF4CAF50),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.mic,
                              color: Colors.black, size: 24),
                        ),
                      );
                    }
                  },
                ),
            ],
          ),
        ],
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
// EXPANDABLE TEXT WIDGET (With Bastard Speed Caching & Garbage Control)
// =========================================================================
class ExpandableMessageText extends StatefulWidget {
  final String text;
  final String timeStr;
  final bool isMe;
  final bool isRead;
  final BuildContext parentContext;
  final Map<String, List<InlineSpan>> regexCache;
  final Map<String, Uint8List> videoCache;
  final String username;

  const ExpandableMessageText({
    super.key,
    required this.text,
    required this.timeStr,
    required this.isMe,
    required this.isRead,
    required this.parentContext,
    required this.regexCache,
    required this.videoCache,
    required this.username,
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

    // --- ⚡ BASTARD SPEED CACHE LOGIC ---
    final cacheKey = "${widget.isMe}_$displayText";
    List<InlineSpan> spans;

    if (widget.regexCache.containsKey(cacheKey)) {
      spans = widget.regexCache[cacheKey]!;
    } else {
      spans = [];
      final regex = RegExp(r'(https?:\/\/[^\s]+)|(@[a-zA-Z0-9_]+)');
      final matches = regex.allMatches(displayText);

      int lastMatchEnd = 0;
      for (final match in matches) {
        if (match.start > lastMatchEnd) {
          spans.add(
              TextSpan(text: displayText.substring(lastMatchEnd, match.start)));
        }
        final matchText = match.group(0)!;
        if (matchText.startsWith('@')) {
          final isMyMention =
              matchText.toLowerCase() == '@${widget.username.toLowerCase()}';
          spans.add(TextSpan(
            text: matchText,
            style: TextStyle(
              color: isMyMention
                  ? Colors.redAccent
                  : (widget.isMe ? Colors.black87 : Colors.amberAccent),
              fontWeight: FontWeight.bold,
            ),
          ));
        } else {
          spans.add(TextSpan(
              text: matchText,
              style: TextStyle(
                color: widget.isMe ? Colors.black87 : const Color(0xFF53BDEB),
                decoration: TextDecoration.underline,
              ),
              recognizer: TapGestureRecognizer()
                ..onTap = () async {
                  final uri = Uri.parse(matchText);
                  if (matchText.contains('allowanceapp.org/gist/')) {
                    final gistId = uri.pathSegments.last;
                    Navigator.pushNamed(widget.parentContext, '/gist',
                        arguments: {'id': gistId});
                  } else if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                }));
        }
        lastMatchEnd = match.end;
      }
      if (lastMatchEnd < displayText.length) {
        spans.add(TextSpan(text: displayText.substring(lastMatchEnd)));
      }

      widget.regexCache[cacheKey] = spans;

      // 🧹 GARBAGE CONTROL: Prevents RAM explosion
      if (widget.regexCache.length > 200) widget.regexCache.clear();
      if (widget.videoCache.length > 30) widget.videoCache.clear();
    }

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
              // 🔥 NO MORE LINKIFY. IT JUST RENDERS THE CACHE INSTANTLY.
              RichText(
                text: TextSpan(
                  style: TextStyle(
                    color: widget.isMe ? Colors.black : Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                  children: spans,
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

// =========================================================================
// LAZY-LOADED WHATSAPP-STYLE AUDIO PLAYER (Zero Lag)
// =========================================================================
class AudioPlayerBubble extends StatefulWidget {
  final String url;
  final bool isMe;
  final Color themeColor;
  final String timeStr;
  final bool isRead;

  const AudioPlayerBubble({
    super.key,
    required this.url,
    required this.isMe,
    required this.themeColor,
    required this.timeStr,
    required this.isRead,
  });

  @override
  State<AudioPlayerBubble> createState() => _AudioPlayerBubbleState();
}

class _AudioPlayerBubbleState extends State<AudioPlayerBubble> {
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isPlaying = false;
  bool _isLoaded = false;
  bool _isLoading = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void dispose() {
    _audioPlayer.dispose();
    super.dispose();
  }

  // 🔥 THE FIX: Only connect to the audio file if the user actually taps Play!
  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _audioPlayer.pause();
      return;
    }

    if (!_isLoaded) {
      setState(() => _isLoading = true);
      try {
        await _audioPlayer.setUrl(widget.url);
        _audioPlayer.playerStateStream.listen((state) {
          if (mounted) {
            setState(() {
              _isPlaying = state.playing;
              if (state.processingState == ProcessingState.completed) {
                _isPlaying = false;
                _audioPlayer.seek(Duration.zero);
                _audioPlayer.pause();
              }
            });
          }
        });
        _audioPlayer.durationStream.listen((d) {
          if (mounted && d != null) setState(() => _duration = d);
        });
        _audioPlayer.positionStream.listen((p) {
          if (mounted) setState(() => _position = p);
        });
        _isLoaded = true;
      } catch (e) {
        debugPrint("Audio load error: $e");
      }
      if (mounted) setState(() => _isLoading = false);
    }

    await _audioPlayer.play();
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 250,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: _isLoading ? null : _togglePlay,
                child: _isLoading
                    ? SizedBox(
                        width: 38,
                        height: 38,
                        child: Padding(
                          padding: const EdgeInsets.all(8.0),
                          child: CircularProgressIndicator(
                              color: widget.isMe
                                  ? Colors.black
                                  : widget.themeColor,
                              strokeWidth: 2),
                        ))
                    : Icon(
                        _isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                        color: widget.isMe ? Colors.black87 : widget.themeColor,
                        size: 38,
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 6),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 10),
                    activeTrackColor:
                        widget.isMe ? Colors.black87 : widget.themeColor,
                    inactiveTrackColor:
                        widget.isMe ? Colors.black26 : Colors.white24,
                    thumbColor: widget.isMe ? Colors.black : widget.themeColor,
                  ),
                  child: Slider(
                    min: 0,
                    max: _duration.inMilliseconds > 0
                        ? _duration.inMilliseconds.toDouble()
                        : 1.0,
                    value: _position.inMilliseconds.toDouble().clamp(
                        0.0,
                        _duration.inMilliseconds > 0
                            ? _duration.inMilliseconds.toDouble()
                            : 1.0),
                    onChanged: (val) {
                      if (_isLoaded)
                        _audioPlayer.seek(Duration(milliseconds: val.toInt()));
                    },
                  ),
                ),
              ),
              CircleAvatar(
                radius: 16,
                backgroundColor:
                    widget.isMe ? Colors.black12 : Colors.grey[800],
                child: Icon(Icons.mic,
                    size: 16,
                    color: widget.isMe ? Colors.black54 : Colors.white54),
              )
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 48),
                child: Text(
                  _isLoaded
                      ? _formatDuration(
                          _position.inSeconds > 0 ? _position : _duration)
                      : "Voice Note",
                  style: TextStyle(
                    color: widget.isMe ? Colors.black54 : Colors.white60,
                    fontSize: 11,
                  ),
                ),
              ),
              Row(
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
              )
            ],
          )
        ],
      ),
    );
  }
}
