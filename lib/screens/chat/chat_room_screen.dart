// lib/screens/chat/chat_room_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/chat/create_group_screen.dart';
import 'package:allowance/screens/home/story_viewer_screen.dart';
import 'package:allowance/screens/home/video_trimmer_screen.dart';
import 'package:allowance/shared/services/chat_sync_service.dart';
import 'package:allowance/widgets/universal_profile_card.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
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
import 'package:table_calendar/table_calendar.dart';
import 'package:uuid/uuid.dart';

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

class _ChatRoomScreenState extends State<ChatRoomScreen>
    with WidgetsBindingObserver {
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
  StreamSubscription? _msgSub;
  StreamSubscription? _typingStatusSub;
  Timer? _remoteTypingTimer;

  Map<String, dynamic>? _chatMeta;
  List<Map<String, dynamic>> _participants = [];
  List<Map<String, dynamic>> _memberProfiles = [];
  String? _creatorId;
  bool _isGroupCreator = false;
  Map<String, dynamic>? _replyMessage;
  bool _showScrollToBottom = false;
  int _firstUnreadIndex = -1;
  bool _unreadCalculated = false;
  int _unseenEventCount = 0;

  // For colored usernames
  final Map<String, Color> _userColors = {};
  final Map<String, List<InlineSpan>> _regexCache = {};
  String _memberSearchQuery = '';
  String? _highlightedMessageId;
  // Add next to _unreadCalculated:
  List<Map<String, dynamic>>? _cachedCombinedMessages;
  String _lastComputeSignature = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    activeChatId = widget.chatId;

    _chatMeta = {
      'group_name': widget.chatTitle,
      'group_avatar': null,
      'group_description': 'Loading group info...',
    };

    _scrollController.addListener(_scrollListener);
    _setupMessageStream();
    _loadChatMeta();
    _setupTypingListener();
    _markMessagesAsRead();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _setupMessageStream();
      _setupTypingListener();
      _loadChatMeta();
      _markMessagesAsRead();
    }
  }

  Future<void> _loadChatMeta() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedParticipants =
          prefs.getString('cached_parts_${supabase.auth.currentUser!.id}');
      final cachedProfiles = prefs.getString(
          'cached_profiles_${widget.chatId}'); // 🔥 NEW: Cache lookup

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

      // 🔥 FIX: Instantly load usernames from cache to prevent the `@User` flash!
      if (cachedProfiles != null && mounted) {
        setState(() => _memberProfiles =
            List<Map<String, dynamic>>.from(jsonDecode(cachedProfiles)));
      }

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

        // 🔥 FIX: Save to cache for next time
        prefs.setString(
            'cached_profiles_${widget.chatId}', jsonEncode(profiles));
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

  Future<void> _checkUnseenEvents() async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;
    try {
      final eventsResp = await supabase
          .from('chat_events')
          .select('id')
          .eq('chat_id', widget.chatId);
      final eventIds = (eventsResp as List).map((e) => e['id'] as int).toList();
      if (eventIds.isEmpty) return;

      final viewsResp = await supabase
          .from('chat_event_views')
          .select('event_id')
          .eq('user_id', myId)
          .inFilter('event_id', eventIds);
      final viewedIds =
          (viewsResp as List).map((v) => v['event_id'] as int).toSet();

      if (mounted) {
        setState(() {
          _unseenEventCount =
              eventIds.where((id) => !viewedIds.contains(id)).length;
        });
      }
    } catch (e) {
      debugPrint("Event check error: $e");
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
    _typingStatusSub?.cancel();
    _typingStatusSub = supabase
        .from('chat_participants')
        .stream(primaryKey: ['chat_id', 'user_id'])
        .eq('chat_id', widget.chatId)
        .listen((data) {
          if (!mounted) return;
          final myId = supabase.auth.currentUser?.id;
          final remoteTyping = data.any((p) =>
              p['user_id']?.toString() != myId && p['is_typing'] == true);

          setState(() => _remoteUserIsTyping = remoteTyping);

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

  // --- FIXED: VOICE NOTES USE OPTIMISTIC UI TO SEND INSTANTLY ---
  Future<void> _uploadAndSendAudio(String filePath) async {
    final replyId = _replyMessage?['id'];
    String replySummary = '🎤 Voice Note';
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

    setState(() => _replyMessage = null);

    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;

    // 🔥 INSTANTLY PASS TO BACKGROUND SYNC ENGINE (No Await!)
    ChatSyncService.instance.enqueueMessage({
      'chat_id': widget.chatId,
      'sender_id': myId,
      'content': '🎤 Voice Note',
      'media_type': 'audio',
      if (replyId != null) 'reply_to_id': replyId,
      if (replyId != null) 'reply_content': replySummary,
    }, localPaths: [
      filePath
    ]);
  }

  Future<void> _sendMessage({String? mediaUrl, String? type}) async {
    final text = _messageController.text.trim();
    final myId = supabase.auth.currentUser?.id;

    if (myId == null || (text.isEmpty && mediaUrl == null)) return;

    // 🔥 CAPTURE REPLY STATE
    final replyId = _replyMessage?['id'];
    final replySummary = _getReplySummary();

    _messageController.clear();
    _focusNode.requestFocus();
    setState(() => _replyMessage = null);

    ChatSyncService.instance.enqueueMessage({
      'chat_id': widget.chatId,
      'sender_id': myId,
      'content': text.isNotEmpty
          ? text
          : (type == 'image'
              ? '📸 Photo'
              : (type == 'video' ? '🎥 Video' : '')),
      'media_type': type ?? 'text',
      if (replyId != null) 'reply_to_id': replyId,
      if (replyId != null) 'reply_content': replySummary,
    });
  }

  Future<void> _pickAndUploadSticker() async {
    try {
      final picker = ImagePicker();
      final pickedFile =
          await picker.pickImage(source: ImageSource.gallery, imageQuality: 50);
      if (pickedFile == null) return;

      XFile? finalFile = pickedFile;

      if (!kIsWeb) {
        final croppedFile = await ImageCropper().cropImage(
          sourcePath: pickedFile.path,
          uiSettings: [
            AndroidUiSettings(
                toolbarTitle: 'Crop Sticker',
                toolbarColor: Colors.black,
                toolbarWidgetColor: Colors.white,
                initAspectRatio: CropAspectRatioPreset.square,
                lockAspectRatio: false),
            IOSUiSettings(title: 'Crop Sticker'),
          ],
        );
        if (croppedFile != null)
          finalFile = XFile(croppedFile.path);
        else
          return;
      }

      final myId = supabase.auth.currentUser?.id;
      if (myId == null) return;

      // CAPTURE REPLY STATE
      final replyId = _replyMessage?['id'];
      final replySummary =
          _replyMessage != null ? _getReplySummary() : 'Sticker';
      setState(() => _replyMessage = null);

      ChatSyncService.instance.enqueueMessage({
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': 'Sticker/GIF',
        'media_type': 'sticker',
        if (replyId != null) 'reply_to_id': replyId,
        if (replyId != null) 'reply_content': replySummary,
      }, localPaths: [
        finalFile.path
      ]);
    } catch (e) {
      debugPrint("Sticker error: $e");
    }
  }

  void _sendExistingSticker(String url) {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;

    // CAPTURE REPLY STATE
    final replyId = _replyMessage?['id'];
    final replySummary = _replyMessage != null ? _getReplySummary() : 'Sticker';
    setState(() => _replyMessage = null);

    ChatSyncService.instance.enqueueMessage({
      'chat_id': widget.chatId,
      'sender_id': myId,
      'content': 'Sticker/GIF',
      'media_type': 'sticker',
      'media_url': url,
      if (replyId != null) 'reply_to_id': replyId,
      if (replyId != null) 'reply_content': replySummary,
    });
  }

  // Update this method to handle the jump logic correctly

  // --- NEW: HELPER TO EXTRACT REPLY TEXT/MEDIA TYPE ---
  String _getReplySummary() {
    if (_replyMessage == null) return '';
    if (_replyMessage!['reply_content_override'] != null) {
      return _replyMessage!['reply_content_override'].toString();
    }
    final content = _replyMessage!['content']?.toString() ?? '';
    final mType = _replyMessage!['media_type']?.toString();
    if (content.isNotEmpty &&
        content != '📸 Photo' &&
        content != '🎥 Video' &&
        content != '🎤 Voice Note' &&
        content != 'Sticker/GIF') {
      return content;
    }
    if (mType == 'video') return '🎥 Video';
    if (mType == 'audio') return '🎤 Voice Note';
    if (mType == 'sticker') return '🎭 Sticker';
    if (mType != null && mType.startsWith('view_once')) {
      return mType.contains('video')
          ? '🎥 View once video'
          : '📷 View once photo';
    }
    return '📸 Photo';
  }

  // --- UPDATED: PREVENTS AUDIO FROM CRASHING THE IMAGE LOADER ---
  Widget _buildReplyPreview() {
    final senderId = _replyMessage!['sender_id']?.toString() ?? '';
    final isMe = senderId == supabase.auth.currentUser?.id;
    final content = _replyMessage!['content']?.toString() ?? '';
    final mediaUrl = _replyMessage!['media_url']?.toString();
    final mediaType = _replyMessage!['media_type']?.toString() ??
        'text'; // 🔥 Check media type
    final isAudio = mediaType == 'audio';

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
                        fontSize: 12),
                  ),
                  Text(
                    (mediaUrl != null && content.isEmpty)
                        ? 'Media'
                        : _getReplySummary(), // 🔥 Use helper
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (mediaUrl != null &&
                !isAudio) // 🔥 FIX: DO NOT TRY TO LOAD AUDIO AS AN IMAGE!
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: CachedNetworkImage(
                    // 🔥 FIX: Safe network image
                    imageUrl: mediaUrl.split(',').first,
                    width: 40, height: 40, fit: BoxFit.cover,
                    errorWidget: (c, u, e) =>
                        const Icon(Icons.broken_image, color: Colors.white54),
                  ),
                ),
              ),
            if (isAudio) // Show mic icon for audio replies
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.mic, color: Colors.white54, size: 28),
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

            // 🔥 OPEN STICKERS MENU
            if (allowPhotos)
              _menuTile(Icons.emoji_emotions, 'Stickers', () {
                Navigator.pop(ctx);
                _showStickerMenu();
              }),

            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

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

  Future<void> _pickAndUploadMedia(ImageSource source, String type) async {
    try {
      final picker = ImagePicker();
      XFile? pickedFile;

      if (type == 'image') {
        pickedFile = await picker.pickImage(source: source, imageQuality: 50);
      } else {
        pickedFile = await picker.pickVideo(source: source);
      }

      if (pickedFile == null) return;

      final captionController = TextEditingController();
      XFile currentFile = pickedFile;
      bool isViewOnce = false; // 🔥 NEW: View Once State

      final shouldSend = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(builder: (context, setDialogState) {
          return Dialog(
            backgroundColor: Colors.grey[900],
            insetPadding:
                const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(type == 'video' ? 'Send Video' : 'Send Photo',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold)),
                        Row(
                          children: [
                            // 🔥 NEW: View Once Toggle Button
                            IconButton(
                              icon: Icon(
                                  isViewOnce
                                      ? Icons.looks_one
                                      : Icons.looks_one_outlined,
                                  color: isViewOnce
                                      ? const Color(0xFF4CAF50)
                                      : Colors.white54),
                              onPressed: () => setDialogState(
                                  () => isViewOnce = !isViewOnce),
                            ),
                            IconButton(
                              icon: Icon(
                                  type == 'video'
                                      ? Icons.content_cut
                                      : Icons.crop,
                                  color: Colors.white),
                              onPressed: () async {
                                if (type == 'image') {
                                  try {
                                    final croppedFile =
                                        await ImageCropper().cropImage(
                                      sourcePath: currentFile.path,
                                      uiSettings: [
                                        AndroidUiSettings(
                                            toolbarTitle: 'Crop Image',
                                            toolbarColor: Colors.black,
                                            toolbarWidgetColor: Colors.white,
                                            initAspectRatio:
                                                CropAspectRatioPreset.original,
                                            lockAspectRatio: false),
                                        IOSUiSettings(title: 'Crop Image'),
                                        WebUiSettings(
                                            context: context,
                                            presentStyle: WebPresentStyle.page),
                                      ],
                                    );
                                    if (croppedFile != null)
                                      setDialogState(() => currentFile =
                                          XFile(croppedFile.path));
                                  } catch (e) {
                                    debugPrint("Crop error: $e");
                                  }
                                } else {
                                  if (kIsWeb) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(
                                            content: Text(
                                                'Video trimming on Web is coming soon!')));
                                    return;
                                  }
                                  final String? trimmedPath =
                                      await Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                              builder: (context) =>
                                                  VideoTrimmerScreen(
                                                      file: File(
                                                          currentFile.path))));
                                  if (trimmedPath != null)
                                    setDialogState(
                                        () => currentFile = XFile(trimmedPath));
                                }
                              },
                            ),
                          ],
                        )
                      ],
                    ),
                    const SizedBox(height: 12),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        height: 260,
                        width: double.infinity,
                        color: Colors.black,
                        child: type == 'video'
                            ? const Center(
                                child: Icon(Icons.play_circle,
                                    size: 80, color: Colors.white70))
                            : (kIsWeb
                                ? Image.network(currentFile.path,
                                    fit: BoxFit.contain)
                                : Image.file(File(currentFile.path),
                                    fit: BoxFit.contain)),
                      ),
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
                          contentPadding: EdgeInsets.all(12)),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel',
                                style: TextStyle(color: Colors.white70))),
                        const SizedBox(width: 24),
                        TextButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Send',
                                style: TextStyle(
                                    color: Color(0xFF4CAF50),
                                    fontWeight: FontWeight.bold))),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
      );

      if (shouldSend != true) return;

      final myId = supabase.auth.currentUser?.id;
      if (myId == null) return;

      final finalContent = captionController.text.trim().isNotEmpty
          ? captionController.text.trim()
          : (type == 'image' ? '📸 Photo' : '🎥 Video');
      final finalType = isViewOnce ? 'view_once_$type' : type;

      String? localThumbPath;
      if (type == 'video' && !kIsWeb) {
        localThumbPath = await VideoThumbnail.thumbnailFile(
            video: currentFile.path,
            thumbnailPath: (await getTemporaryDirectory()).path,
            imageFormat: ImageFormat.JPEG,
            quality: 50);
      }

      final replyId = _replyMessage?['id'];
      final replySummary = _getReplySummary();
      setState(() => _replyMessage = null);

      ChatSyncService.instance.enqueueMessage({
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': finalContent,
        'media_type': finalType,
        'local_thumb_path': localThumbPath,
        if (replyId != null) 'reply_to_id': replyId,
        if (replyId != null) 'reply_content': replySummary,
      }, localPaths: [
        currentFile.path
      ]);
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

  // --- FIXED: ALWAYS SHOWS TIME (e.g., 4:30 PM) ---
  String _formatTime(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return "";
    try {
      DateTime date = DateTime.parse(timestamp).toLocal();
      return DateFormat('h:mm a').format(date); // 🔥 ALWAYS returns the time
    } catch (e) {
      return "";
    }
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

  // --- NEW: EXTENDED EMOJI GRID ---
  void _showExtendedEmojiGrid(Map<String, dynamic> message) {
    final extendedEmojis = [
      '❤️',
      '😂',
      '😮',
      '😢',
      '🙏',
      '👏',
      '🔥',
      '💯',
      '😍',
      '😒',
      '😎',
      '😡',
      '👍',
      '👎',
      '🎉',
      '💩',
      '💀',
      '👀',
      '🥺',
      '🤯',
      '🥰',
      '🤔',
      '🥶',
      '🤬',
      '😈',
      '👻',
      '👽',
      '🥳',
      '🤮',
      '🤡',
      '🤌',
      '💪',
      '🤝',
      '🙌'
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(16.0),
        child: GridView.builder(
          shrinkWrap: true,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 6, crossAxisSpacing: 10, mainAxisSpacing: 10),
          itemCount: extendedEmojis.length,
          itemBuilder: (context, index) {
            final emoji = extendedEmojis[index];
            return GestureDetector(
              onTap: () async {
                Navigator.pop(ctx);
                final newReaction =
                    message['reactions'] == emoji ? null : emoji;
                try {
                  await supabase.from('messages').update(
                      {'reactions': newReaction}).eq('id', message['id']);
                } catch (e) {
                  debugPrint('Reaction error: $e');
                }
              },
              child: Center(
                  child: Text(emoji, style: const TextStyle(fontSize: 32))),
            );
          },
        ),
      ),
    );
  }

  Future<bool> _isStickerSaved(String url) async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return false;
    try {
      final res = await supabase
          .from('saved_stickers')
          .select('id')
          .eq('user_id', myId)
          .eq('url', url)
          .maybeSingle();
      return res != null;
    } catch (e) {
      debugPrint('Sticker check error: $e');
      return false;
    }
  }

  // --- FIXED: EDITING WITH OFFLINE SUPPORT & SERIOUSNESS MENU ---
  void _showMessageOptions(Map<String, dynamic> message, bool isMe) {
    final createdAt = DateTime.parse(message['created_at']).toLocal();
    final canEdit = DateTime.now().difference(createdAt).inMinutes <= 5;
    final isText = message['media_url'] == null &&
        (message['media_type'] == 'text' || message['media_type'] == null);
    final hasContent = message['content'] != null &&
        message['content'].toString().trim().isNotEmpty;
    final isSticker = message['media_type'] == 'sticker' ||
        (message['media_type'] == 'image' &&
            message['content'] == 'Sticker/GIF');
    final stickerUrl = isSticker ? message['media_url']?.toString() : null;

    final currentReaction = message['reactions'];
    final defaultEmojis = ['❤️', '😂', '😮', '😢', '🙏'];

    void updateReaction(String emoji) async {
      Navigator.pop(context);
      final newReaction = currentReaction == emoji ? null : emoji;
      try {
        await supabase
            .from('messages')
            .update({'reactions': newReaction}).eq('id', message['id']);
      } catch (e) {
        debugPrint('Reaction error: $e');
      }
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    ...defaultEmojis.map((emoji) => GestureDetector(
                          onTap: () => updateReaction(emoji),
                          child: Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                                color: currentReaction == emoji
                                    ? Colors.white24
                                    : Colors.transparent,
                                shape: BoxShape.circle),
                            child: Text(emoji,
                                style: const TextStyle(fontSize: 28)),
                          ),
                        )),
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(ctx);
                        _showExtendedEmojiGrid(message);
                      },
                      child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: const BoxDecoration(
                              color: Colors.white10, shape: BoxShape.circle),
                          child: const Icon(Icons.add, color: Colors.white)),
                    )
                  ],
                ),
              ),
              const Divider(color: Colors.white24),

              // Reply
              ListTile(
                leading: const Icon(Icons.reply, color: Colors.blueAccent),
                title: const Text('Reply',
                    style: TextStyle(color: Colors.blueAccent)),
                onTap: () {
                  Navigator.pop(ctx);
                  _onSwipeToReply(message);
                },
              ),

              // Forward
              ListTile(
                  leading: const Icon(Icons.forward, color: Colors.blueAccent),
                  title: const Text('Forward',
                      style: TextStyle(color: Colors.blueAccent)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showForwardSheet(message);
                  }),

              // Mood — always available on your own messages
              if (isMe)
                ListTile(
                    leading: const Icon(Icons.speed, color: Colors.orange),
                    title: const Text('Set Message Mood/Priority',
                        style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _showSeriousnessSlider(message);
                    }),

              // Smart Save / Remove Sticker
              if (stickerUrl != null)
                FutureBuilder<bool>(
                  future: _isStickerSaved(stickerUrl),
                  builder: (context, snapshot) {
                    final isSaved = snapshot.data ?? false;
                    return ListTile(
                      leading: Icon(
                        isSaved ? Icons.bookmark_remove : Icons.bookmark_add,
                        color: isSaved
                            ? Colors.orangeAccent
                            : const Color(0xFF4CAF50),
                      ),
                      title: Text(
                        isSaved ? 'Remove Sticker' : 'Save Sticker',
                        style: TextStyle(
                            color: isSaved
                                ? Colors.orangeAccent
                                : const Color(0xFF4CAF50)),
                      ),
                      onTap: () async {
                        Navigator.pop(ctx);
                        final myId = supabase.auth.currentUser?.id;
                        if (myId == null) return;
                        try {
                          if (isSaved) {
                            await supabase
                                .from('saved_stickers')
                                .delete()
                                .eq('user_id', myId)
                                .eq('url', stickerUrl);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      'Sticker removed from your collection'),
                                  backgroundColor: Colors.black87,
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                          } else {
                            await supabase.from('saved_stickers').insert({
                              'user_id': myId,
                              'url': stickerUrl,
                              'created_at': DateTime.now().toIso8601String(),
                            });
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Sticker saved!'),
                                  backgroundColor: Color(0xFF4CAF50),
                                  duration: Duration(seconds: 2),
                                ),
                              );
                            }
                          }
                        } catch (e) {
                          debugPrint('Sticker save/remove error: $e');
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Failed to update sticker'),
                                backgroundColor: Colors.redAccent,
                              ),
                            );
                          }
                        }
                      },
                    );
                  },
                ),

              if (hasContent && !isSticker)
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
                    if (message['is_pending'] == true ||
                        message['is_failed'] == true) {
                      if (message['local_id'] != null) {
                        ChatSyncService.instance
                            .cancelMessage(message['local_id']);
                      }
                    } else {
                      _deleteMessage(message['id']);
                    }
                  },
                ),
              const SizedBox(height: 20),
            ],
          ),
        ),
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
              hintStyle: TextStyle(color: Colors.white54)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.white54))),
          TextButton(
            onPressed: () async {
              final newText = editController.text.trim();
              if (newText.isNotEmpty && newText != message['content']) {
                if (mounted) Navigator.pop(ctx);

                // 🔥 FIX: Proper Optimistic UI Update that works even if offline
                setState(() {
                  final idx =
                      _messages.indexWhere((m) => m['id'] == message['id']);
                  if (idx != -1) {
                    _messages[idx] = Map<String, dynamic>.from(_messages[idx])
                      ..['content'] = newText
                      ..['is_edited'] = true
                      ..['is_pending'] = true;
                  }
                });

                try {
                  await supabase
                      .from('messages')
                      .update({'content': newText, 'is_edited': true}).eq(
                          'id', message['id']);
                  if (mounted) {
                    setState(() {
                      final idx =
                          _messages.indexWhere((m) => m['id'] == message['id']);
                      if (idx != -1) _messages[idx]['is_pending'] = false;
                    });
                  }
                } catch (e) {
                  if (mounted) {
                    setState(() {
                      final idx =
                          _messages.indexWhere((m) => m['id'] == message['id']);
                      if (idx != -1) {
                        _messages[idx]['is_pending'] = false;
                        _messages[idx]['is_failed'] = true;
                      }
                    });
                  }
                }
              }
            },
            child: const Text('Save',
                style: TextStyle(
                    color: Color(0xFF4CAF50), fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // --- NEW: THE IMMOVABLE SERIOUSNESS SLIDER ---
  void _showSeriousnessSlider(Map<String, dynamic> message) {
    int currentLevel = message['seriousness'] ?? 0;
    final emojis = ['😃', '😐', '😰', '😡'];
    final labels = ['Normal', 'Serious', 'Anxious', 'Worried'];
    final colors = [
      const Color(0xFF4CAF50),
      Colors.amber[700]!,
      Colors.orange,
      Colors.redAccent
    ];

    showModalBottomSheet(
        context: context,
        backgroundColor: Colors.grey[900],
        isDismissible: false, // 🔥 IMMOVABLE BAR
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (ctx) => StatefulBuilder(builder: (context, setModalState) {
              return Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('${labels[currentLevel]} ${emojis[currentLevel]}',
                        style: TextStyle(
                            color: colors[currentLevel],
                            fontSize: 22,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        activeTrackColor: colors[currentLevel],
                        thumbColor: colors[currentLevel],
                        inactiveTrackColor: Colors.white12,
                        valueIndicatorColor: colors[currentLevel],
                      ),
                      child: Slider(
                        value: currentLevel.toDouble(),
                        min: 0,
                        max: 3,
                        divisions: 3,
                        label: emojis[currentLevel],
                        onChanged: (val) {
                          setModalState(() => currentLevel = val.toInt());
                        },
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Cancel',
                                  style: TextStyle(color: Colors.white54))),
                          ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                  backgroundColor: colors[currentLevel]),
                              onPressed: () async {
                                // 🔥 INSTANT OPTIMISTIC UI
                                setState(() =>
                                    message['seriousness'] = currentLevel);
                                Navigator.pop(ctx);
                                try {
                                  await supabase
                                      .from('messages')
                                      .update({'seriousness': currentLevel}).eq(
                                          'id', message['id']);
                                } catch (e) {}
                              },
                              child: const Text('Set Mood',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold)))
                        ])
                  ]));
            }));
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

  // --- NEW STICKER METHODS ---
  void _showStickerMenu() {
    if (!mounted) return;

    showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF1E1E1E),
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (ctx) => StatefulBuilder(builder: (context, setSheetState) {
              return SafeArea(
                  child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Stickers',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold)),
                            GestureDetector(
                              onTap: () => Navigator.pop(ctx),
                              child: const Icon(Icons.close,
                                  color: Colors.white54, size: 28),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        ConstrainedBox(
                          constraints: BoxConstraints(
                              maxHeight:
                                  MediaQuery.of(context).size.height * 0.4),
                          child: FutureBuilder(
                              future: supabase
                                  .from('saved_stickers')
                                  .select('id, url')
                                  .eq('user_id', supabase.auth.currentUser!.id)
                                  .order('created_at', ascending: false),
                              builder:
                                  (context, AsyncSnapshot<dynamic> snapshot) {
                                if (snapshot.connectionState ==
                                    ConnectionState.waiting)
                                  return const Center(
                                      child: CircularProgressIndicator(
                                          color: Color(0xFF4CAF50)));

                                final savedStickers =
                                    List<Map<String, dynamic>>.from(
                                        snapshot.data ?? []);

                                return GridView.builder(
                                    shrinkWrap: true,
                                    gridDelegate:
                                        const SliverGridDelegateWithFixedCrossAxisCount(
                                            crossAxisCount: 4,
                                            crossAxisSpacing: 10,
                                            mainAxisSpacing: 10),
                                    itemCount: savedStickers.length + 1,
                                    itemBuilder: (context, index) {
                                      if (index == 0) {
                                        return GestureDetector(
                                          onTap: () async {
                                            Navigator.pop(ctx);
                                            await _pickAndUploadSticker();
                                          },
                                          child: Container(
                                            decoration: BoxDecoration(
                                                color: Colors.grey[800],
                                                borderRadius:
                                                    BorderRadius.circular(12)),
                                            child: const Icon(Icons.add,
                                                color: Colors.white, size: 36),
                                          ),
                                        );
                                      }

                                      final sticker = savedStickers[index - 1];
                                      final url = sticker['url'].toString();
                                      final stickerId = sticker['id'];

                                      return GestureDetector(
                                        onTap: () {
                                          // NO POP — sheet stays open
                                          _sendExistingSticker(url);
                                          HapticFeedback.lightImpact();
                                        },
                                        onLongPress: () async {
                                          HapticFeedback.lightImpact();
                                          await supabase
                                              .from('saved_stickers')
                                              .delete()
                                              .eq('id', stickerId);
                                          setSheetState(() {});
                                        },
                                        child: ClipRRect(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          child: CachedNetworkImage(
                                            imageUrl: url,
                                            fit: BoxFit.cover,
                                            placeholder: (context, url) =>
                                                const Center(
                                                    child:
                                                        CircularProgressIndicator(
                                                            color: Color(
                                                                0xFF4CAF50))),
                                            errorWidget: (context, url,
                                                    error) =>
                                                const Icon(Icons.broken_image,
                                                    color: Colors.white54),
                                          ),
                                        ),
                                      );
                                    });
                              }),
                        )
                      ])));
            }));
  }

  // --- NEW: FORWARD MESSAGE SHEET ---
  void _showForwardSheet(Map<String, dynamic> message) async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;

    // Fetch friends
    final res = await supabase
        .from('followers')
        .select('following_id')
        .eq('follower_id', myId);
    final followingIds = res.map((e) => e['following_id']).toList();
    List<dynamic> friends = [];
    if (followingIds.isNotEmpty) {
      friends = await supabase
          .from('profiles')
          .select('id, username, avatar_url')
          .inFilter('id', followingIds);
    }

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        Set<String> selectedFriends = {};
        bool isSending = false;

        return StatefulBuilder(
          builder: (context, setModalState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.7,
              minChildSize: 0.5,
              maxChildSize: 0.9,
              expand: false,
              builder: (_, scrollController) => Column(
                children: [
                  const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('Forward to...',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold))),
                  const Divider(color: Colors.white10),
                  Expanded(
                    child: friends.isEmpty
                        ? const Center(
                            child: Text("Follow people to forward messages",
                                style: TextStyle(color: Colors.white54)))
                        : ListView.builder(
                            controller: scrollController,
                            itemCount: friends.length,
                            itemBuilder: (context, index) {
                              final friend = friends[index];
                              final isSelected =
                                  selectedFriends.contains(friend['id']);
                              return ListTile(
                                leading: CircleAvatar(
                                    backgroundImage:
                                        friend['avatar_url'] != null
                                            ? NetworkImage(friend['avatar_url'])
                                            : null,
                                    child: friend['avatar_url'] == null
                                        ? const Icon(Icons.person,
                                            color: Colors.white54)
                                        : null),
                                title: Text(friend['username'] ?? 'User',
                                    style:
                                        const TextStyle(color: Colors.white)),
                                trailing: Checkbox(
                                    value: isSelected,
                                    activeColor: const Color(0xFF4CAF50),
                                    onChanged: (v) => setModalState(() {
                                          v == true
                                              ? selectedFriends
                                                  .add(friend['id'])
                                              : selectedFriends
                                                  .remove(friend['id']);
                                        })),
                                onTap: () => setModalState(() {
                                  isSelected
                                      ? selectedFriends.remove(friend['id'])
                                      : selectedFriends.add(friend['id']);
                                }),
                              );
                            },
                          ),
                  ),
                  if (selectedFriends.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF4CAF50),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12))),
                          onPressed: isSending
                              ? null
                              : () async {
                                  setModalState(() => isSending = true);
                                  for (String friendId in selectedFriends) {
                                    final response = await supabase.rpc(
                                        'get_or_create_personal_chat',
                                        params: {
                                          'user_a': myId,
                                          'user_b': friendId
                                        });
                                    final chatId = response.toString();

                                    // Forward via ChatSyncService
                                    ChatSyncService.instance.enqueueMessage({
                                      'chat_id': chatId,
                                      'sender_id': myId,
                                      'content': message['content'] ?? '',
                                      'media_type':
                                          message['media_type'] ?? 'text',
                                      'media_url': message['media_url'],
                                      'thumbnail_url': message['thumbnail_url'],
                                      'file_size_bytes':
                                          message['file_size_bytes'],
                                    });
                                  }
                                  if (mounted) {
                                    Navigator.pop(ctx);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                            content: Text(
                                                'Forwarded to ${selectedFriends.length} chat(s)!'),
                                            backgroundColor: Colors.green));
                                  }
                                },
                          child: isSending
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                      color: Colors.black, strokeWidth: 2))
                              : Text('Send',
                                  style: const TextStyle(
                                      color: Colors.black,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16)),
                        ),
                      ),
                    )
                ],
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildBubble(
      List<Map<String, dynamic>> messages, int index, double maxWidth) {
    final message = messages[index];
    final messageId =
        (message['id'] ?? message['local_id'] ?? index).toString();
    final localId = message['local_id'];

    final myId = supabase.auth.currentUser?.id;
    final isMe = message['sender_id']?.toString() == myId;
    final content = (message['content'] ?? '').toString();
    final timeStr = _formatTime(message['created_at']?.toString());
    final isRead = message['is_read'] == true;
    final isPending = message['is_pending'] == true;
    final isFailed = message['is_failed'] == true;
    final isEdited = message['is_edited'] == true;
    final int seriousness = message['seriousness'] as int? ?? 0;

    final mediaType = message['media_type']?.toString() ?? 'text';
    final isFile = mediaType == 'file';
    final isOrder = mediaType == 'order';
    final isAudio = mediaType == 'audio';
    final isViewOnce = mediaType.startsWith('view_once_');
    final isSticker = mediaType == 'sticker' ||
        (mediaType == 'image' && content == 'Sticker/GIF');
    final isImageOrVideo =
        mediaType == 'image' || mediaType == 'video' || isSticker;

    if (mediaType == 'system') {
      return Center(
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(
              color: Colors.white12, borderRadius: BorderRadius.circular(16)),
          child: Text(content,
              style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  fontStyle: FontStyle.italic),
              textAlign: TextAlign.center),
        ),
      );
    }

    // =========================================================================
    // EVENT BANNER (Clean, no "STARTING NOW" text)
    // =========================================================================
    if (mediaType == 'event') {
      final String? evtMediaUrl = message['media_url']?.toString();
      final bool evtHasMedia =
          evtMediaUrl != null && evtMediaUrl.trim().isNotEmpty;

      return GestureDetector(
        onLongPress: () => _showMessageOptions(message, isMe),
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: 20, horizontal: 12),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: evtHasMedia
                  ? null
                  : const LinearGradient(
                      colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 24,
                  spreadRadius: 2,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Stack(
              children: [
                if (evtHasMedia)
                  Positioned.fill(
                    child: CachedNetworkImage(
                      imageUrl: evtMediaUrl!.split(',').first,
                      fit: BoxFit.cover,
                      placeholder: (context, url) =>
                          Container(color: const Color(0xFF0F172A)),
                      errorWidget: (context, url, error) =>
                          Container(color: const Color(0xFF0F172A)),
                    ),
                  ),
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.black.withOpacity(0.1),
                          Colors.black.withOpacity(0.5),
                          Colors.black.withOpacity(evtHasMedia ? 0.88 : 0.95),
                        ],
                        stops: const [0.0, 0.35, 1.0],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF4CAF50),
                          const Color(0xFF4CAF50).withOpacity(0.0),
                        ],
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: const Color(0xFF4CAF50).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: const Color(0xFF4CAF50).withOpacity(0.25),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.event_available_rounded,
                              color: const Color(0xFF4CAF50),
                              size: 13,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'EVENT',
                              style: TextStyle(
                                color: const Color(0xFF4CAF50),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        content,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                          letterSpacing: -0.5,
                        ),
                      ),
                      if (message['description']?.toString().isNotEmpty ==
                          true) ...[
                        const SizedBox(height: 8),
                        Text(
                          message['description'].toString(),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.75),
                            fontSize: 14,
                            height: 1.4,
                            fontWeight: FontWeight.w400,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 20),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.35),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.08),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.access_time_rounded,
                              color: const Color(0xFF4CAF50),
                              size: 15,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              timeStr,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (message['location']?.toString().isNotEmpty ==
                                true) ...[
                              const SizedBox(width: 12),
                              Container(
                                width: 4,
                                height: 4,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.4),
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Icon(
                                Icons.location_on_outlined,
                                color: Colors.white.withOpacity(0.6),
                                size: 14,
                              ),
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  message['location'].toString(),
                                  style: TextStyle(
                                    color: Colors.white.withOpacity(0.7),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final senderId = message['sender_id']?.toString() ?? '';
    final senderProfile = _memberProfiles.firstWhere(
        (p) => p['id'].toString() == senderId,
        orElse: () => {'username': 'User', 'avatar_url': null});

    final senderName = senderProfile['username']?.toString() ?? 'User';
    final avatarUrl = senderProfile['avatar_url']?.toString();
    final bool isStillInGroup = _isUserStillInGroup(senderId);

    final List<Color> sColors = [
      const Color(0xFF4CAF50),
      Colors.amber[700]!,
      Colors.orange,
      Colors.redAccent
    ];
    final bubbleColor = isMe ? sColors[seriousness] : const Color(0xFF202C33);
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
    final List<String> localPaths =
        List<String>.from(message['local_paths'] ?? []);

    final bool hasMediaUrl =
        mediaUrlStr != null && mediaUrlStr.trim().isNotEmpty;
    final bool hasLocalPaths = localPaths.isNotEmpty;
    final List<String> mediaUrls = (isPending && hasLocalPaths)
        ? localPaths
        : (hasMediaUrl ? mediaUrlStr.split(',') : []);

    final bool isOpened = content == 'Opened';

    final bool isReceivingMedia = !isMe &&
        (isImageOrVideo || isViewOnce) &&
        !hasMediaUrl &&
        !hasLocalPaths &&
        !isOpened;

    final bool showMediaSection =
        isImageOrVideo && (hasMediaUrl || hasLocalPaths);

    final bool hasCaption = content.isNotEmpty &&
        content != '📸 Photo' &&
        content != '🎥 Video' &&
        content != '🎤 Voice Note' &&
        content != 'Sticker/GIF' &&
        content != 'Opened' &&
        content.trim() != '';
    final bool isHighlighted = _highlightedMessageId == messageId;

    // --- VIEW ONCE UI (NOW SHOWS REPLY PREVIEW) ---
    // --- VIEW ONCE UI (swipeable to reply, shows reply preview) ---
    if (isViewOnce && (hasMediaUrl || hasLocalPaths || isOpened)) {
      return Dismissible(
        key: ValueKey('viewonce_$messageId'),
        direction: DismissDirection.startToEnd,
        confirmDismiss: (_) {
          _onSwipeToReply(message);
          return Future.value(false);
        },
        background: Container(
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 20),
            child: const Icon(Icons.reply, color: Color(0xFF4CAF50))),
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: GestureDetector(
            onTap: () async {
              if (isMe || isOpened || mediaUrls.isEmpty) return;
              final actualType = mediaType.replaceAll('view_once_', '');
              final viewOnceItems = mediaUrls
                  .map((url) => {'url': url, 'type': actualType})
                  .toList();
              await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => FullScreenMediaPlayer(
                          mediaItems: viewOnceItems, initialIndex: 0)));
              setState(() {
                message['content'] = 'Opened';
                message['media_url'] = null;
              });
              await supabase.from('messages').update(
                  {'content': 'Opened', 'media_url': null}).eq('id', messageId);
            },
            onLongPress: () => _showMessageOptions(message, isMe),
            behavior: HitTestBehavior.opaque,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                  color: bubbleColor,
                  borderRadius: BorderRadius.circular(20).copyWith(
                      topRight: isMe ? Radius.zero : const Radius.circular(20),
                      topLeft: (!isMe && showAvatar)
                          ? Radius.zero
                          : const Radius.circular(20))),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message['reply_to_id'] != null ||
                      (message['reply_content']?.startsWith('Story_') ??
                          false) ||
                      (message['reply_content']?.startsWith('Event_') ?? false))
                    _buildReplyInsideBubble(message),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                          isOpened ? Icons.looks_one_outlined : Icons.looks_one,
                          color: isOpened ? Colors.white38 : Colors.blueAccent,
                          size: 24),
                      const SizedBox(width: 8),
                      Text(
                          isOpened
                              ? 'Opened'
                              : (mediaType.contains('video')
                                  ? 'Video'
                                  : 'Photo'),
                          style: TextStyle(
                              color: isOpened
                                  ? Colors.white54
                                  : (isMe ? Colors.black87 : Colors.white),
                              fontSize: 16,
                              fontStyle: isOpened
                                  ? FontStyle.italic
                                  : FontStyle.normal)),
                      const SizedBox(width: 16),
                      _buildMediaTime(timeStr, isMe, isRead,
                          isPending: isPending,
                          isFailed: isFailed,
                          localId: localId),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // --- STICKER UI ---
    if (isSticker && showMediaSection) {
      final effectiveUrl = mediaUrls.first;
      Widget stickerWidget = (isPending && hasLocalPaths)
          ? (kIsWeb
              ? Image.network(effectiveUrl, width: 150, fit: BoxFit.contain)
              : Image.file(File(effectiveUrl), width: 150, fit: BoxFit.contain))
          : CachedNetworkImage(
              imageUrl: effectiveUrl, width: 150, fit: BoxFit.contain);

      final bool hasReply = message['reply_to_id'] != null ||
          (message['reply_content']?.toString().isNotEmpty ?? false);

      return RepaintBoundary(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
              color: isHighlighted
                  ? const Color(0xFF4CAF50).withOpacity(0.3)
                  : Colors.transparent),
          child: Dismissible(
            key: ValueKey('sticker_$messageId'),
            direction: DismissDirection.startToEnd,
            confirmDismiss: (_) {
              _onSwipeToReply(message);
              return Future.value(false);
            },
            background: Container(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 20),
                child: const Icon(Icons.reply, color: Color(0xFF4CAF50))),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
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
                      behavior: HitTestBehavior.opaque,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: isMe
                            ? CrossAxisAlignment.end
                            : CrossAxisAlignment.start,
                        children: [
                          if (hasReply) _buildReplyInsideBubble(message),
                          if (widget.isGroup && !isMe && showAvatar)
                            Padding(
                                padding:
                                    const EdgeInsets.only(bottom: 4, left: 4),
                                child: Text(
                                    isStillInGroup
                                        ? '@$senderName'
                                        : senderName,
                                    style: TextStyle(
                                        color: nameColor,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold,
                                        fontStyle: isStillInGroup
                                            ? FontStyle.normal
                                            : FontStyle.italic))),
                          Stack(
                            clipBehavior: Clip.none,
                            children: [
                              ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: stickerWidget),
                              if (isPending && localId != null)
                                Positioned.fill(
                                  child: Container(
                                    decoration: BoxDecoration(
                                        color: Colors.black.withOpacity(0.4),
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                    child: Center(
                                      child: isFailed
                                          ? IconButton(
                                              icon: const Icon(Icons.refresh,
                                                  color: Colors.redAccent,
                                                  size: 40),
                                              onPressed: () => ChatSyncService
                                                  .instance
                                                  .retryMessage(localId))
                                          : const CircularProgressIndicator(
                                              color: Color(0xFF4CAF50)),
                                    ),
                                  ),
                                ),
                              Positioned(
                                  bottom: 4,
                                  right: 4,
                                  child: _buildMediaTime(timeStr, isMe, isRead,
                                      isPending: isPending,
                                      isFailed: isFailed,
                                      localId: localId)),
                              if (message['reactions'] != null &&
                                  message['reactions'].toString().isNotEmpty)
                                Positioned(
                                    bottom: -10,
                                    right: isMe ? 0 : null,
                                    left: isMe ? null : 0,
                                    child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 4, vertical: 1),
                                        decoration: BoxDecoration(
                                            color: const Color(0xFF121212),
                                            borderRadius:
                                                BorderRadius.circular(10),
                                            border: Border.all(
                                                color: Colors.white24,
                                                width: 1)),
                                        child: Text(message['reactions'],
                                            style: const TextStyle(
                                                fontSize: 12)))),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // --- NORMAL CHAT BUBBLE ---
    return RepaintBoundary(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
            color: isHighlighted
                ? const Color(0xFF4CAF50).withOpacity(0.3)
                : Colors.transparent),
        child: Dismissible(
          key: ValueKey('msg_$messageId'),
          direction: DismissDirection.startToEnd,
          confirmDismiss: (_) {
            _onSwipeToReply(message);
            return Future.value(false);
          },
          background: Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 20),
              child: const Icon(Icons.reply, color: Color(0xFF4CAF50))),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
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
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      GestureDetector(
                        onLongPress: () => _showMessageOptions(message, isMe),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          key: ValueKey('bubble_$messageId'),
                          margin: const EdgeInsets.only(
                              bottom: 8, left: 8, right: 8),
                          constraints: BoxConstraints(maxWidth: maxWidth),
                          decoration: BoxDecoration(
                            color: bubbleColor,
                            borderRadius: BorderRadius.circular(20).copyWith(
                              topRight: isMe
                                  ? Radius.zero
                                  : const Radius.circular(20),
                              topLeft: (!isMe && showAvatar)
                                  ? Radius.zero
                                  : const Radius.circular(20),
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20).copyWith(
                              topRight: isMe
                                  ? Radius.zero
                                  : const Radius.circular(20),
                              topLeft: (!isMe && showAvatar)
                                  ? Radius.zero
                                  : const Radius.circular(20),
                            ),
                            child: IntrinsicWidth(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (message['reply_to_id'] != null ||
                                      (message['reply_content']
                                              ?.toString()
                                              .isNotEmpty ??
                                          false))
                                    _buildReplyInsideBubble(message),
                                  if (widget.isGroup && !isMe && showAvatar)
                                    Padding(
                                        padding: const EdgeInsets.fromLTRB(
                                            12, 8, 12, 0),
                                        child: Text(
                                            isStillInGroup
                                                ? '@$senderName'
                                                : senderName,
                                            style: TextStyle(
                                                color: nameColor,
                                                fontSize: 11,
                                                fontWeight: FontWeight.bold,
                                                fontStyle: isStillInGroup
                                                    ? FontStyle.normal
                                                    : FontStyle.italic))),
                                  if (isAudio && (hasMediaUrl || hasLocalPaths))
                                    AudioPlayerBubble(
                                        url: mediaUrls.first,
                                        isMe: isMe,
                                        themeColor: const Color(0xFF121212),
                                        timeStr: timeStr,
                                        isRead: isRead),
                                  if (isReceivingMedia)
                                    Container(
                                        padding: const EdgeInsets.all(12),
                                        color: Colors.black26,
                                        child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              const SizedBox(
                                                  width: 16,
                                                  height: 16,
                                                  child:
                                                      CircularProgressIndicator(
                                                          strokeWidth: 2,
                                                          color: Color(
                                                              0xFF4CAF50))),
                                              const SizedBox(width: 12),
                                              Text("Receiving $mediaType...",
                                                  style: const TextStyle(
                                                      color: Colors.white70,
                                                      fontStyle:
                                                          FontStyle.italic))
                                            ])),
                                  if (showMediaSection)
                                    Container(
                                        decoration: BoxDecoration(
                                            border: hasCaption
                                                ? Border(
                                                    bottom: BorderSide(
                                                        color: isMe
                                                            ? const Color(
                                                                0xFF388E3C)
                                                            : const Color(
                                                                0xFF182025),
                                                        width: 1.5))
                                                : null),
                                        child: _buildMediaWithOverlay(
                                            mediaUrls,
                                            mediaType,
                                            timeStr,
                                            isMe,
                                            isRead,
                                            message)),
                                  if (isFile)
                                    GestureDetector(
                                      onTap: () async {
                                        final uri = Uri.parse(hasLocalPaths
                                            ? localPaths.first
                                            : mediaUrls.first);
                                        if (await canLaunchUrl(uri)) {
                                          await launchUrl(uri,
                                              mode: LaunchMode
                                                  .externalApplication);
                                        } else if (mounted) {
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(const SnackBar(
                                                  content: Text(
                                                      'Cannot open file')));
                                        }
                                      },
                                      child: Container(
                                          constraints: const BoxConstraints(
                                              maxWidth: 240),
                                          margin: const EdgeInsets.all(4),
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                              color: Colors.black26,
                                              borderRadius:
                                                  BorderRadius.circular(8)),
                                          child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                    Icons.insert_drive_file,
                                                    color: Colors.blueAccent,
                                                    size: 30),
                                                const SizedBox(width: 8),
                                                Flexible(
                                                    child: Text(
                                                        content.isNotEmpty
                                                            ? content
                                                            : 'Document',
                                                        style: const TextStyle(
                                                            color: Colors
                                                                .blueAccent,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                            decoration:
                                                                TextDecoration
                                                                    .underline),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis))
                                              ])),
                                    ),
                                  if (!isOrder &&
                                      !isFile &&
                                      !isAudio &&
                                      !isReceivingMedia)
                                    if (hasCaption ||
                                        (!showMediaSection &&
                                            content.isNotEmpty &&
                                            content != '🎤 Voice Note'))
                                      ExpandableMessageText(
                                          text: content,
                                          timeStr: timeStr,
                                          isMe: isMe,
                                          isRead: isRead,
                                          parentContext: context,
                                          regexCache: _regexCache,
                                          videoCache: _chatVideoThumbCache,
                                          username:
                                              widget.userPreferences.username ??
                                                  '',
                                          isPending: isPending,
                                          isFailed: isFailed,
                                          localId: localId,
                                          isEdited: isEdited,
                                          seriousness: seriousness),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (message['reactions'] != null &&
                          message['reactions'].toString().isNotEmpty)
                        Positioned(
                            bottom: -4,
                            right: isMe ? 20 : null,
                            left: isMe ? null : 20,
                            child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                    color: const Color(0xFF121212),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                        color: Colors.white24, width: 1)),
                                child: Text(message['reactions'],
                                    style: const TextStyle(fontSize: 12)))),
                    ],
                  ),
                )
              ],
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
    final bool isEventReply = replyContent.startsWith('Event_');
    final String? storyImageUrl = message['thumbnail_url'];

    String displayReplyText = replyContent;
    if (isStoryReply && replyContent.startsWith('Story_')) {
      final parts = replyContent.split('_');
      displayReplyText =
          parts.length > 2 ? parts.sublist(2).join('_') : "Story";
    } else if (isEventReply) {
      final parts = replyContent.split('_');
      displayReplyText =
          parts.length > 2 ? parts.sublist(2).join('_') : "Event";
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
                      isStoryReply
                          ? "Replying to Story"
                          : (isEventReply
                              ? "Replying to Event"
                              : "Replying to"),
                      style: TextStyle(
                          color: _userColors['reply'] ?? Colors.greenAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    Text(displayReplyText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12)),
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
      return;
    }

    if (replyContent.startsWith('Event_')) {
      final parts = replyContent.split('_');
      final title = parts.length > 2 ? parts.sublist(2).join('_') : 'an event';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('This was a reply to the event "$title".'),
          backgroundColor: Colors.black87,
          duration: const Duration(seconds: 2)));
      return;
    }

    if (message['reply_to_id'] != null) {
      final targetId = message['reply_to_id'].toString();
      setState(() => _highlightedMessageId = targetId);
      Future.delayed(const Duration(milliseconds: 1500), () {
        if (mounted) setState(() => _highlightedMessageId = null);
      });

      final targetIndex =
          _messages.indexWhere((m) => m['id'].toString() == targetId);
      if (targetIndex != -1) {
        final estimatedOffset = targetIndex * 80.0;
        _scrollController.animateTo(estimatedOffset,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeInOut);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Message is too far back to scroll to.'),
            backgroundColor: Colors.black87,
            duration: Duration(seconds: 2)));
      }
    }
  }

// --- SUB-WIDGET: COMPACT MEDIA ---
  Widget _buildSingleMediaItem(String url, String mediaType,
      List<String> allUrls, int index, Map<String, dynamic> message,
      {double? height}) {
    final String? thumbUrl = message['thumbnail_url']?.toString();
    final bool isVideo = mediaType == 'video';
    final bool isPending = message['is_pending'] == true;
    final bool isFailed = message['is_failed'] == true;
    final String? localId = message['local_id'];

    final List<String> localPaths =
        List<String>.from(message['local_paths'] ?? []);

    Widget mediaWidget;

    // --- 1. PENDING MEDIA (PREVIEWING LOCAL FILE OR WEB BLOB) ---
    if (isPending && localPaths.isNotEmpty) {
      if (isVideo) {
        if (kIsWeb) {
          // 🔥 THE FIX: Extract first frame natively for Web uploads
          mediaWidget = _VideoFramePreview(url: url);
        } else {
          if (_chatVideoThumbCache.containsKey(url)) {
            mediaWidget = Image.memory(_chatVideoThumbCache[url]!,
                fit: BoxFit.cover,
                width: double.infinity,
                height: height ?? 200);
          } else {
            mediaWidget = FutureBuilder<Uint8List?>(
              future: VideoThumbnail.thumbnailData(
                      video: url,
                      imageFormat: ImageFormat.JPEG,
                      maxWidth: 400,
                      quality: 50)
                  .catchError((_) => null),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done &&
                    snapshot.data != null) {
                  _chatVideoThumbCache[url] = snapshot.data!;
                  return Image.memory(snapshot.data!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: height ?? 200);
                }
                return Container(
                    width: double.infinity,
                    height: height ?? 200,
                    color: Colors.black45,
                    child: const Center(
                        child: Icon(Icons.videocam,
                            color: Colors.white54, size: 40)));
              },
            );
          }
        }
      } else {
        // IMAGE PREVIEW
        if (kIsWeb) {
          mediaWidget = Image.network(url,
              fit: BoxFit.cover,
              width: double.infinity,
              height: height ?? 200,
              errorBuilder: (_, __, ___) => _buildErrorPlaceholder(false));
        } else {
          mediaWidget = Image.file(File(url),
              fit: BoxFit.cover,
              width: double.infinity,
              height: height ?? 200,
              errorBuilder: (_, __, ___) => _buildErrorPlaceholder(false));
        }
      }
    }
    // --- 2. NETWORK MEDIA (ALREADY UPLOADED TO SUPABASE) ---
    else {
      if (isVideo) {
        if (thumbUrl != null && thumbUrl.isNotEmpty) {
          mediaWidget = CachedNetworkImage(
              imageUrl: thumbUrl,
              fit: BoxFit.cover,
              width: double.infinity,
              height: height ?? 200,
              errorWidget: (c, u, e) => _buildErrorPlaceholder(true));
        } else {
          if (kIsWeb) {
            // 🔥 THE FIX: Extract first frame natively for Web Network videos
            mediaWidget = _VideoFramePreview(url: url);
          } else {
            if (_chatVideoThumbCache.containsKey(url)) {
              mediaWidget = Image.memory(_chatVideoThumbCache[url]!,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: height ?? 200);
            } else {
              mediaWidget = FutureBuilder<Uint8List?>(
                  future: VideoThumbnail.thumbnailData(
                          video: url,
                          imageFormat: ImageFormat.JPEG,
                          maxWidth: 400,
                          quality: 50)
                      .catchError((_) => null),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.done &&
                        snapshot.data != null) {
                      _chatVideoThumbCache[url] = snapshot.data!;
                      return Image.memory(snapshot.data!,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: height ?? 200);
                    }
                    return Container(
                        color: Colors.black45,
                        width: double.infinity,
                        height: height ?? 200,
                        child: Center(
                            child: snapshot.connectionState ==
                                    ConnectionState.waiting
                                ? const CircularProgressIndicator(
                                    color: Color(0xFF4CAF50))
                                : const Icon(Icons.videocam,
                                    color: Colors.white54, size: 40)));
                  });
            }
          }
        }
      } else {
        mediaWidget = CachedNetworkImage(
            imageUrl: url,
            fit: BoxFit.cover,
            width: double.infinity,
            height: height ?? 200,
            errorWidget: (c, u, e) => _buildErrorPlaceholder(false));
      }
    }

    return GestureDetector(
      onTap: () {
        if (!isPending) _openFullScreen(url);
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
              constraints: BoxConstraints(maxHeight: height ?? 200),
              width: double.infinity,
              decoration: BoxDecoration(
                  color: Colors.grey[900],
                  borderRadius: BorderRadius.circular(8)),
              child: mediaWidget),
          if (isVideo && !isPending)
            Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20)),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.play_arrow, color: Colors.white, size: 18)
                ])),
          if (isPending && localId != null)
            Positioned.fill(
              child: Container(
                color: Colors.black.withOpacity(0.4),
                child: Center(
                  child: isFailed
                      ? IconButton(
                          icon: const Icon(Icons.refresh,
                              color: Colors.redAccent, size: 40),
                          onPressed: () =>
                              ChatSyncService.instance.retryMessage(localId))
                      : ValueListenableBuilder<Map<String, double?>>(
                          valueListenable:
                              ChatSyncService.instance.uploadProgress,
                          builder: (context, progressMap, _) {
                            final double progress =
                                progressMap[localId] ?? 0.01;
                            final int percent =
                                (progress * 100).toInt().clamp(0, 100);

                            return Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    SizedBox(
                                        width: 40,
                                        height: 40,
                                        child: CircularProgressIndicator(
                                            value: progress,
                                            color: const Color(0xFF4CAF50),
                                            backgroundColor: Colors.white24,
                                            strokeWidth: 3)),
                                    IconButton(
                                        icon: const Icon(Icons.close,
                                            color: Colors.white, size: 18),
                                        onPressed: () => ChatSyncService
                                            .instance
                                            .cancelMessage(localId)),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius: BorderRadius.circular(8)),
                                    child: Text('$percent%',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold)))
                              ],
                            );
                          },
                        ),
                ),
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

  // --- SUB-WIDGET: COMPACT MEDIA ---
  Widget _buildCompactMedia(
      List<String> urls, String mediaType, Map<String, dynamic> message) {
    return urls.length == 1
        ? _buildSingleMediaItem(urls[0], mediaType, urls, 0, message)
        : _buildMediaCollage(urls, mediaType, message);
  }

  Widget _buildMediaWithOverlay(List<String> urls, String type, String time,
      bool isMe, bool isRead, Map<String, dynamic> message) {
    return Stack(
      alignment: Alignment.bottomRight,
      children: [
        _buildCompactMedia(urls, type, message),
        _buildMediaTime(time, isMe, isRead,
            isPending: message['is_pending'] == true,
            isFailed: message['is_failed'] == true,
            localId: message['local_id']),
      ],
    );
  }

// --- SUB-WIDGET: TEXT & TIME (For standard bubbles) ---

// Helper for time on top of images
  Widget _buildMediaTime(String time, bool isMe, bool isRead,
      {bool isPending = false, bool isFailed = false, String? localId}) {
    return Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
              color: Colors.black45, borderRadius: BorderRadius.circular(10)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(isFailed ? "Failed" : time,
                  style: TextStyle(
                      color: isFailed ? Colors.redAccent : Colors.white,
                      fontSize: 9)),
              if (isMe) ...[
                const SizedBox(width: 3),
                if (isFailed)
                  GestureDetector(
                    onTap: () =>
                        ChatSyncService.instance.retryMessage(localId!),
                    child: const Icon(Icons.refresh,
                        size: 14, color: Colors.redAccent),
                  )
                else if (isPending)
                  const Icon(Icons.access_time, size: 12, color: Colors.white70)
                else
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
            onTap: () => _openFullScreen(urls[index]),
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

  List<Map<String, dynamic>> _computeCombinedMessages(
      List<Map<String, dynamic>> pendingList, String? myId) {
    final myPending =
        pendingList.where((m) => m['chat_id'] == widget.chatId).toList();

    int hash = myPending.length.hashCode ^ _messages.length.hashCode;
    for (final p in myPending) {
      hash ^= (p['local_id'] ?? '').hashCode;
      hash ^= (p['is_failed'] == true ? 1 : 0).hashCode;
      hash ^= (p['is_pending'] == true ? 2 : 0).hashCode;
    }
    for (final m in _messages) {
      hash ^= (m['id'] ?? '').hashCode;
      hash ^= (m['is_edited'] == true ? 1 : 0).hashCode;
    }
    final signature = hash.toString();

    if (_cachedCombinedMessages != null && signature == _lastComputeSignature) {
      return _cachedCombinedMessages!;
    }

    // 🔥 Exact match by local_id — no more time-window guessing
    final confirmedLocalIds = _messages
        .map((m) => m['local_id']?.toString())
        .where((id) => id != null && id.isNotEmpty)
        .toSet();

    final visiblePending = myPending.where((p) {
      if (p['is_failed'] == true) return true;
      return !confirmedLocalIds.contains(p['local_id']?.toString());
    }).toList();

    final combined = [...visiblePending, ..._messages];
    combined.sort((a, b) {
      final dateA = DateTime.parse(a['created_at']).toLocal();
      final dateB = DateTime.parse(b['created_at']).toLocal();
      return dateB.compareTo(dateA);
    });

    _cachedCombinedMessages = combined;
    _lastComputeSignature = signature;
    return combined;
  }

  // --- NEW: FETCHES ALL MEDIA FROM ENTIRE CHAT HISTORY ---
  List<Map<String, dynamic>> _getAllMediaItems() {
    final pendingList = ChatSyncService.instance.pendingMessages.value
        .where((m) => m['chat_id'] == widget.chatId)
        .toList();

    final myId = supabase.auth.currentUser?.id;
    final serverMessages = _messages.where((m) {
      if (m['sender_id'] != myId) return true;
      return !pendingList.any((p) =>
          p['local_id'] == m['local_id'] ||
          (p['content'] == m['content'] && p['media_type'] == m['media_type']));
    }).toList();

    final combined = [...pendingList, ...serverMessages];

    // Sort oldest first so swiping right goes to NEWER media
    combined.sort((a, b) {
      final dateA = DateTime.parse(a['created_at']).toLocal();
      final dateB = DateTime.parse(b['created_at']).toLocal();
      return dateA.compareTo(dateB);
    });

    List<Map<String, dynamic>> mediaItems = [];
    for (var m in combined) {
      final type = m['media_type']?.toString() ?? 'text';
      if (type != 'image' && type != 'video') continue;

      final isPending = m['is_pending'] == true;
      final localPaths = List<String>.from(m['local_paths'] ?? []);
      final mediaUrlStr = m['media_url']?.toString();

      final urls = (isPending && localPaths.isNotEmpty)
          ? localPaths
          : (mediaUrlStr != null && mediaUrlStr.isNotEmpty
              ? mediaUrlStr.split(',')
              : <String>[]);

      for (var url in urls) {
        mediaItems.add({'url': url, 'type': type});
      }
    }
    return mediaItems;
  }

  // --- UPDATED: OPENS FULLSCREEN WITH ALL MEDIA ---
  void _openFullScreen(String tappedUrl) {
    final allMedia = _getAllMediaItems();
    int initialIndex = allMedia.indexWhere((m) => m['url'] == tappedUrl);
    if (initialIndex == -1) initialIndex = 0; // Fallback

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => FullScreenMediaPlayer(
          mediaItems: allMedia,
          initialIndex: initialIndex,
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    final avatarUrl = _chatMeta?['group_avatar']?.toString();
    final title = (_chatMeta?['group_name'] ?? widget.chatTitle).toString();

    final myId = supabase.auth.currentUser?.id;
    final amICreator = myId == _creatorId;
    final amIAdmin = _participants
        .any((p) => p['user_id']?.toString() == myId && p['role'] == 'admin');
    final bool isAdminPrivilege = amICreator || amIAdmin;

    return AppBar(
      backgroundColor: Colors.grey[900],
      titleSpacing: 0,
      elevation: 0,
      iconTheme: const IconThemeData(color: Colors.white),
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
        if (widget.isGroup)
          Stack(
            alignment: Alignment.topRight,
            children: [
              IconButton(
                icon: const Icon(Icons.calendar_month, color: Colors.white),
                onPressed: () async {
                  await showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (context) => GroupCalendarSheet(
                      chatId: widget.chatId,
                      isAdmin: isAdminPrivilege,
                    ),
                  );
                  _checkUnseenEvents();
                },
              ),
              if (_unseenEventCount > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                        color: Colors.redAccent, shape: BoxShape.circle),
                    child: Text('$_unseenEventCount',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold)),
                  ),
                )
            ],
          ),
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
    final localMessages = await ChatLocalDB.instance
        .getMessagesForChat(widget.chatId, limit: 100);
    if (localMessages.isNotEmpty && mounted) {
      setState(() {
        _messages = localMessages;
        if (!_unreadCalculated) {
          _firstUnreadIndex = _messages.lastIndexWhere((m) =>
              m['is_read'] == false &&
              m['sender_id'] != supabase.auth.currentUser?.id);
          _unreadCalculated = true;
        }
      });
    }

    _msgSub?.cancel();
    _msgSub = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('chat_id', widget.chatId)
        .order('created_at', ascending: false)
        .limit(100)
        .listen((data) async {
          if (!mounted) return;
          setState(() {
            _messages = List<Map<String, dynamic>>.from(data);
            if (!_unreadCalculated && _messages.isNotEmpty) {
              _firstUnreadIndex = _messages.lastIndexWhere((m) =>
                  m['is_read'] == false &&
                  m['sender_id'] != supabase.auth.currentUser?.id);
              _unreadCalculated = true;
            }
          });
          await ChatLocalDB.instance.cacheMessages(widget.chatId, data);
        });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (activeChatId == widget.chatId) {
      activeChatId = null;
    }
    _msgSub?.cancel();
    _typingStatusSub?.cancel();
    _scrollController.removeListener(_scrollListener);
    _memberSearchController.dispose();
    _typingTimer?.cancel();
    _remoteTypingTimer?.cancel();

    final myId = supabase.auth.currentUser?.id;
    if (myId != null && _isTyping) {
      supabase.from('chat_participants').update({'is_typing': false}).match(
          {'chat_id': widget.chatId, 'user_id': myId});
    }

    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _audioRecorder.dispose();
    _recordTimer?.cancel();
    super.dispose();
  }

  // --- UPDATED: MOBILE KEYBOARD PERFORMANCE FIX & UNREAD MESSAGES SEPARATOR ---
  @override
  Widget build(BuildContext context) {
    final double maxBubbleWidth = MediaQuery.sizeOf(context).width * 0.75;
    final myId = supabase.auth.currentUser?.id;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset: true,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => FocusScope.of(context).unfocus(),
              child: Stack(
                children: [
                  ValueListenableBuilder<List<Map<String, dynamic>>>(
                    valueListenable: ChatSyncService.instance.pendingMessages,
                    builder: (context, pendingList, _) {
                      final combinedMessages =
                          _computeCombinedMessages(pendingList, myId);

                      if (combinedMessages.isEmpty) {
                        return const Center(
                            child: Text("Send a message to start chatting!",
                                style: TextStyle(color: Colors.white54)));
                      }

                      if (!_unreadCalculated && combinedMessages.isNotEmpty) {
                        _firstUnreadIndex = combinedMessages.lastIndexWhere(
                            (m) =>
                                m['is_read'] == false &&
                                m['sender_id'] != myId);
                        _unreadCalculated = true;
                      }

                      return ListView.builder(
                        controller: _scrollController,
                        reverse: true,
                        addAutomaticKeepAlives: false,
                        addRepaintBoundaries:
                            false, // 🔥 Web: prevents box.dart crash
                        cacheExtent: 150,
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: const EdgeInsets.all(12),
                        itemCount: combinedMessages.length,
                        itemBuilder: (context, index) {
                          final msg = combinedMessages[index];
                          final date =
                              DateTime.parse(msg['created_at']).toLocal();
                          bool showDateHeader = false;

                          if (index == combinedMessages.length - 1) {
                            showDateHeader = true;
                          } else {
                            final prevDate = DateTime.parse(
                                    combinedMessages[index + 1]['created_at'])
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
                                                fontSize: 12)))),
                              if (index == _firstUnreadIndex &&
                                  _firstUnreadIndex != -1)
                                Container(
                                  margin:
                                      const EdgeInsets.symmetric(vertical: 16),
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 4),
                                  decoration: BoxDecoration(
                                      color: const Color(0xFF1E1E1E),
                                      borderRadius: BorderRadius.circular(12)),
                                  child: const Text("UNREAD MESSAGES",
                                      style: TextStyle(
                                          color: Colors.amber,
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold)),
                                ),
                              _buildBubble(
                                  combinedMessages, index, maxBubbleWidth),
                            ],
                          );
                        },
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
          RepaintBoundary(child: _buildInputBar()),
        ],
      ),
    );
  }

  // 4. INPUT BAR (With Gboard GIF/Sticker Injection)
  Widget _buildInputBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
          color: Colors.black,
          border: Border(top: BorderSide(color: Colors.grey[900]!))),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_replyMessage != null) _buildReplyPreview(),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (!_isRecording)
                IconButton(
                    icon: const Icon(Icons.add, color: Color(0xFF4CAF50)),
                    onPressed: _showPlusOptions),
              Expanded(
                child: _isRecording
                    ? Container(
                        height: 48,
                        margin: const EdgeInsets.only(bottom: 2),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                            color: const Color(0xFF1C1C1E),
                            borderRadius: BorderRadius.circular(24)),
                        child: Row(children: [
                          GestureDetector(
                              onTap: () {
                                _recordTimer?.cancel();
                                _audioRecorder.stop();
                                setState(() => _isRecording = false);
                                HapticFeedback.vibrate();
                              },
                              child: const Icon(Icons.delete,
                                  color: Colors.redAccent, size: 26)),
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
                        ]),
                      )
                    : TextField(
                        controller: _messageController,
                        focusNode: _focusNode,
                        style: const TextStyle(color: Colors.white),
                        maxLines: 5,
                        minLines: 1,
                        textInputAction: TextInputAction.newline,
                        keyboardType: TextInputType.multiline,
                        contentInsertionConfiguration:
                            ContentInsertionConfiguration(
                          onContentInserted:
                              (KeyboardInsertedContent content) async {
                            if (content.data != null) {
                              final myId = supabase.auth.currentUser?.id;
                              if (myId == null) return;
                              final fileName =
                                  'gif_${DateTime.now().millisecondsSinceEpoch}.png';
                              final storagePath =
                                  'chat_media/${widget.chatId}/$fileName';
                              await supabase.storage
                                  .from('chat_media')
                                  .uploadBinary(storagePath, content.data!);
                              final publicUrl = supabase.storage
                                  .from('chat_media')
                                  .getPublicUrl(storagePath);

                              // 🔥 CAPTURE REPLY STATE FOR GBOARD STICKERS
                              final replyId = _replyMessage?['id'];
                              final replySummary = _getReplySummary();
                              setState(() => _replyMessage = null);

                              ChatSyncService.instance.enqueueMessage({
                                'chat_id': widget.chatId,
                                'sender_id': myId,
                                'content': 'Sticker/GIF',
                                'media_type': 'sticker',
                                'media_url': publicUrl,
                                if (replyId != null) 'reply_to_id': replyId,
                                if (replyId != null)
                                  'reply_content': replySummary,
                              });
                            }
                          },
                        ),
                        onChanged: _handleTyping,
                        decoration: InputDecoration(
                          hintText: 'Message...',
                          hintStyle: const TextStyle(color: Colors.white54),
                          filled: true,
                          fillColor: const Color(0xFF1C1C1E),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                        ),
                      ),
              ),
              if (_isRecording)
                GestureDetector(
                    onTap: () {
                      HapticFeedback.lightImpact();
                      _stopAndSendRecording();
                    },
                    child: Container(
                        margin: const EdgeInsets.only(left: 8, bottom: 4),
                        padding: const EdgeInsets.all(10),
                        decoration: const BoxDecoration(
                            color: Color(0xFF4CAF50), shape: BoxShape.circle),
                        child: const Icon(Icons.send,
                            color: Colors.black, size: 24)))
              else
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _messageController,
                  builder: (context, value, child) {
                    final hasText = value.text.trim().isNotEmpty;
                    if (hasText) {
                      return IconButton(
                          icon:
                              const Icon(Icons.send, color: Color(0xFF4CAF50)),
                          onPressed: () => _sendMessage());
                    } else {
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
                                  shape: BoxShape.circle),
                              child: const Icon(Icons.mic,
                                  color: Colors.black, size: 24)));
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

// =========================================================================
// UNIVERSAL FULLSCREEN MEDIA PLAYER (WHATSAPP-STYLE SWIPING)
// =========================================================================
class FullScreenMediaPlayer extends StatefulWidget {
  final List<Map<String, dynamic>>
      mediaItems; // [{'url': String, 'type': String}]
  final int initialIndex;

  const FullScreenMediaPlayer({
    super.key,
    required this.mediaItems,
    this.initialIndex = 0,
  });

  @override
  State<FullScreenMediaPlayer> createState() => _FullScreenMediaPlayerState();
}

class _FullScreenMediaPlayerState extends State<FullScreenMediaPlayer> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
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
          title: Text('${_currentIndex + 1} of ${widget.mediaItems.length}',
              style: const TextStyle(fontSize: 16)),
        ),
        extendBodyBehindAppBar: true,
        body: PageView.builder(
          controller: _pageController,
          itemCount: widget.mediaItems.length,
          onPageChanged: (idx) => setState(() => _currentIndex = idx),
          itemBuilder: (context, index) {
            final item = widget.mediaItems[index];
            final url = item['url'] as String;
            final type = item['type'] as String;
            final isActive = index == _currentIndex;

            if (type == 'video') {
              return _VideoPageItem(url: url, isActive: isActive);
            } else {
              return InteractiveViewer(
                child: kIsWeb && !url.startsWith('http')
                    ? Image.network(url, fit: BoxFit.contain) // Web Blob
                    : (url.startsWith('http')
                        ? CachedNetworkImage(
                            imageUrl: url,
                            fit: BoxFit.contain,
                            errorWidget: (_, __, ___) => const Center(
                                child: Text('Failed to load image',
                                    style: TextStyle(color: Colors.white))))
                        : Image.file(File(url),
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Center(
                                child: Text('Failed to load image',
                                    style: TextStyle(color: Colors.white))))),
              );
            }
          },
        ),
      ),
    );
  }
}

// =========================================================================
// LAZY-LOADED VIDEO PAGE WIDGET
// =========================================================================
class _VideoPageItem extends StatefulWidget {
  final String url;
  final bool isActive;

  const _VideoPageItem({required this.url, required this.isActive});

  @override
  State<_VideoPageItem> createState() => _VideoPageItemState();
}

class _VideoPageItemState extends State<_VideoPageItem> {
  VideoPlayerController? _controller;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    if (widget.isActive) _initVideo();
  }

  @override
  void didUpdateWidget(covariant _VideoPageItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      if (_controller == null)
        _initVideo();
      else
        _controller!.play();
    } else if (!widget.isActive && oldWidget.isActive) {
      _controller?.pause();
      _controller?.dispose();
      _controller = null;
      _isInitialized = false;
    }
  }

  void _initVideo() {
    if (kIsWeb || widget.url.startsWith('http')) {
      _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    } else {
      _controller = VideoPlayerController.file(File(widget.url));
    }

    _controller!.initialize().then((_) {
      if (mounted) {
        setState(() => _isInitialized = true);
        if (widget.isActive) {
          _controller!.setLooping(true); // 🔥 LOOPS INFINITELY
          _controller!.play();
        }
      }
    }).catchError((e) {
      debugPrint("Video init error: $e");
    });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized || _controller == null) {
      return const Center(
          child: CircularProgressIndicator(color: Color(0xFF4CAF50)));
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        setState(() {
          _controller!.value.isPlaying
              ? _controller!.pause()
              : _controller!.play();
        });
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: _controller!.value.aspectRatio,
            child: IgnorePointer(
                child: VideoPlayer(_controller!)), // 🔥 Safe for Web Taps
          ),
          if (!_controller!.value.isPlaying)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.6), shape: BoxShape.circle),
              child: const Icon(Icons.play_arrow_rounded,
                  color: Colors.white, size: 64),
            ),
          Positioned(
            bottom: 20,
            left: 16,
            right: 16,
            child: VideoProgressIndicator(
              _controller!,
              allowScrubbing: true,
              padding: const EdgeInsets.symmetric(vertical: 8),
              colors: const VideoProgressColors(
                  playedColor: Color(0xFF4CAF50),
                  bufferedColor: Colors.white24,
                  backgroundColor: Colors.white10),
            ),
          ),
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
// EXPANDABLE TEXT WIDGET (With Background Sync States, Edits & Seriousness)
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
  final bool isPending;
  final bool isFailed;
  final String? localId;
  final bool isEdited;
  final int seriousness;

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
    this.isPending = false,
    this.isFailed = false,
    this.localId,
    this.isEdited = false,
    this.seriousness = 0,
  });

  @override
  State<ExpandableMessageText> createState() => _ExpandableMessageTextState();
}

class _ExpandableMessageTextState extends State<ExpandableMessageText> {
  bool _isExpanded = false;
  final List<Color> sColors = [
    const Color(0xFF4CAF50),
    Colors.amber[700]!,
    Colors.orange,
    Colors.redAccent
  ];

  @override
  Widget build(BuildContext context) {
    const int limit = 400;
    final bool isLong = widget.text.length > limit;
    final String displayText = (isLong && !_isExpanded)
        ? '${widget.text.substring(0, limit)}...'
        : widget.text;

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
                fontWeight: FontWeight.bold),
          ));
        } else {
          spans.add(TextSpan(
              text: matchText,
              style: TextStyle(
                  color: widget.isMe ? Colors.black87 : const Color(0xFF53BDEB),
                  decoration: TextDecoration.underline),
              recognizer: TapGestureRecognizer()
                ..onTap = () async {
                  final uri = Uri.parse(matchText);
                  if (matchText.contains('allowanceapp.org/gist/')) {
                    Navigator.pushNamed(widget.parentContext, '/gist',
                        arguments: {'id': uri.pathSegments.last});
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
      if (widget.regexCache.length > 200) widget.regexCache.clear();
      if (widget.videoCache.length > 30) widget.videoCache.clear();
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Wrap(
        alignment: WrapAlignment
            .start, // 🔥 FIX: Forces text to align normally to the left!
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 8,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              RichText(
                  text: TextSpan(
                      style: TextStyle(
                          color: widget.isMe ? Colors.black : Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500),
                      children: spans)),
              if (isLong && !_isExpanded)
                GestureDetector(
                    onTap: () => setState(() => _isExpanded = true),
                    child: Padding(
                        padding: const EdgeInsets.only(top: 8.0, bottom: 2.0),
                        child: Text('Read more',
                            style: TextStyle(
                                color: widget.isMe
                                    ? Colors.black54
                                    : const Color(0xFF4CAF50),
                                fontWeight: FontWeight.bold,
                                fontSize: 14)))),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.seriousness > 0)
                Container(
                    margin: const EdgeInsets.only(right: 4, bottom: 2),
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                        color: [
                          const Color(0xFF4CAF50),
                          Colors.amber[700]!,
                          Colors.orange,
                          Colors.redAccent
                        ][widget.seriousness],
                        shape: BoxShape.circle)),
              if (widget.isEdited)
                const Text('Edited ',
                    style: TextStyle(
                        color: Colors.white54,
                        fontSize: 9,
                        fontStyle: FontStyle.italic)),
              Text(widget.isFailed ? "Failed" : widget.timeStr,
                  style: TextStyle(
                      color: widget.isFailed
                          ? Colors.redAccent
                          : (widget.isMe ? Colors.black54 : Colors.white60),
                      fontSize: 10,
                      fontWeight: FontWeight.w500)),
              if (widget.isMe) ...[
                const SizedBox(width: 4),
                if (widget.isFailed)
                  GestureDetector(
                      onTap: () => ChatSyncService.instance
                          .retryMessage(widget.localId!),
                      child: const Icon(Icons.refresh,
                          size: 14, color: Colors.redAccent))
                else if (widget.isPending)
                  const Icon(Icons.access_time,
                      size: 12,
                      color: Colors
                          .black54) // 🔥 Shows the clock until DB confirms!
                else
                  Icon(widget.isRead ? Icons.done_all : Icons.done,
                      size: 14,
                      color: widget.isRead ? Colors.blue : Colors.black54),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

// =========================================================================
// PERSISTENT AUDIO PLAYER SERVICE (Survives ListView rebuilds)
// =========================================================================
class AudioPlayerService {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;
  AudioPlayerService._internal();

  final AudioPlayer _player = AudioPlayer();
  String? _currentUrl;
  bool _isPlaying = false;
  bool _isLoaded = false;
  bool _isLoading = false;
  bool _isDownloaded = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  final _playingController = StreamController<bool>.broadcast();
  final _loadingController = StreamController<bool>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _downloadedController = StreamController<bool>.broadcast();
  final _urlController = StreamController<String?>.broadcast();

  Stream<bool> get playingStream => _playingController.stream;
  Stream<bool> get loadingStream => _loadingController.stream;
  Stream<Duration> get durationStream => _durationController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<bool> get downloadedStream => _downloadedController.stream;
  Stream<String?> get urlStream => _urlController.stream;

  String? get currentUrl => _currentUrl;
  bool get isPlaying => _isPlaying;
  bool get isLoaded => _isLoaded;
  bool get isLoading => _isLoading;
  bool get isDownloaded => _isDownloaded;
  Duration get duration => _duration;
  Duration get position => _position;

  Future<void> init() async {
    _player.playerStateStream.listen((state) {
      _isPlaying = state.playing;
      _playingController.add(_isPlaying);
      if (state.processingState == ProcessingState.completed) {
        _isPlaying = false;
        _playingController.add(false);
        _player.seek(Duration.zero);
        _player.pause();
      }
    });

    _player.durationStream.listen((d) {
      if (d != null) {
        _duration = d;
        _durationController.add(d);
      }
    });

    _player.positionStream.listen((p) {
      _position = p;
      _positionController.add(p);
    });
  }

  Future<void> checkDownloaded(String url) async {
    if (kIsWeb || !url.startsWith('http')) {
      _isDownloaded = true;
      _downloadedController.add(true);
      return;
    }
    final file = await DefaultCacheManager().getFileFromCache(url);
    _isDownloaded = file != null;
    _downloadedController.add(_isDownloaded);
  }

  Future<void> togglePlay(String url) async {
    if (_currentUrl == url && _isPlaying) {
      await _player.pause();
      return;
    }
    if (_currentUrl == url && !_isPlaying && _isLoaded) {
      await _player.play();
      return;
    }
    if (_currentUrl != url) {
      _isLoaded = false;
      _isLoading = true;
      _loadingController.add(true);
      _currentUrl = url;
      _urlController.add(url);
      try {
        await _player.setUrl(url);
        _isLoaded = true;
        await _player.play();
      } catch (e) {
        debugPrint("Audio load error: $e");
      }
      _isLoading = false;
      _loadingController.add(false);
    }
  }

  Future<void> download(String url) async {
    _isLoading = true;
    _loadingController.add(true);
    await DefaultCacheManager().downloadFile(url);
    _isDownloaded = true;
    _downloadedController.add(true);
    _isLoading = false;
    _loadingController.add(false);
  }

  Future<void> seek(Duration position) async {
    await _player.seek(position);
  }

  void dispose() {
    _player.dispose();
    _playingController.close();
    _loadingController.close();
    _durationController.close();
    _positionController.close();
    _downloadedController.close();
    _urlController.close();
  }
}

// =========================================================================
// LAZY-LOADED WHATSAPP-STYLE AUDIO PLAYER (With Download System)
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
  final AudioPlayerService _service = AudioPlayerService();
  bool _isPlaying = false;
  bool _isLoaded = false;
  bool _isLoading = false;
  bool _isDownloaded = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _service.init();
    _service.checkDownloaded(widget.url);

    _service.playingStream.listen((playing) {
      if (mounted && _service.currentUrl == widget.url) {
        setState(() => _isPlaying = playing);
      }
    });
    _service.loadingStream.listen((loading) {
      if (mounted && _service.currentUrl == widget.url) {
        setState(() => _isLoading = loading);
      }
    });
    _service.durationStream.listen((d) {
      if (mounted && _service.currentUrl == widget.url) {
        setState(() {
          _duration = d;
          _isLoaded = true;
        });
      }
    });
    _service.positionStream.listen((p) {
      if (mounted && _service.currentUrl == widget.url) {
        setState(() => _position = p);
      }
    });
    _service.downloadedStream.listen((downloaded) {
      if (mounted) setState(() => _isDownloaded = downloaded);
    });
    _service.urlStream.listen((url) {
      if (mounted && url != widget.url) {
        setState(() => _isPlaying = false);
      }
    });
  }

  Future<void> _togglePlay() async {
    if (!_isDownloaded && widget.url.startsWith('http')) {
      await _service.download(widget.url);
      return;
    }
    await _service.togglePlay(widget.url);
  }

  String _formatDuration(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  @override
  Widget build(BuildContext context) {
    final bool isActive = _service.currentUrl == widget.url;
    final bool showPlaying = isActive ? _isPlaying : false;

    return Container(
      constraints: const BoxConstraints(minWidth: 230),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: _togglePlay,
                child: _isLoading && isActive
                    ? SizedBox(
                        width: 38,
                        height: 38,
                        child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: CircularProgressIndicator(
                                color: widget.isMe
                                    ? Colors.black
                                    : widget.themeColor,
                                strokeWidth: 2)))
                    : Icon(
                        !_isDownloaded
                            ? Icons.download_for_offline
                            : (showPlaying
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill),
                        color: widget.isMe ? Colors.black87 : widget.themeColor,
                        size: 38),
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
                      if (_isLoaded && isActive) {
                        _service.seek(Duration(milliseconds: val.toInt()));
                      }
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
                    isActive && _isLoaded
                        ? _formatDuration(
                            _position.inSeconds > 0 ? _position : _duration)
                        : "Voice Note",
                    style: TextStyle(
                        color: widget.isMe ? Colors.black54 : Colors.white60,
                        fontSize: 11)),
              ),
              Row(
                children: [
                  Text(widget.timeStr,
                      style: TextStyle(
                          color: widget.isMe ? Colors.black54 : Colors.white60,
                          fontSize: 10,
                          fontWeight: FontWeight.w500)),
                  if (widget.isMe) ...[
                    const SizedBox(width: 4),
                    Icon(widget.isRead ? Icons.done_all : Icons.done,
                        size: 14,
                        color: widget.isRead ? Colors.blue : Colors.black54),
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

// =========================================================================
// WEB NATIVE VIDEO THUMBNAIL EXTRACTOR
// =========================================================================
class _VideoFramePreview extends StatefulWidget {
  final String url;
  const _VideoFramePreview({required this.url});

  @override
  State<_VideoFramePreview> createState() => _VideoFramePreviewState();
}

class _VideoFramePreviewState extends State<_VideoFramePreview> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) setState(() {});
      }).catchError((_) {
        // Handle dead links silently
      });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller != null && _controller!.value.isInitialized) {
      return SizedBox(
        width: double.infinity,
        height: 200,
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _controller!.value.size.width,
              height: _controller!.value.size.height,
              child: IgnorePointer(child: VideoPlayer(_controller!)),
            ),
          ),
        ),
      );
    }

    // Loading State
    return Container(
      width: double.infinity,
      height: 200,
      color: Colors.black87,
      child: const Center(
        child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
      ),
    );
  }
}

class GroupCalendarSheet extends StatefulWidget {
  final String chatId;
  final bool isAdmin;

  const GroupCalendarSheet({
    super.key,
    required this.chatId,
    required this.isAdmin,
  });

  @override
  State<GroupCalendarSheet> createState() => _GroupCalendarSheetState();
}

class _GroupCalendarSheetState extends State<GroupCalendarSheet> {
  final _supabase = Supabase.instance.client;
  DateTime _focusedDay = DateTime.now();
  DateTime? _selectedDay;
  Map<DateTime, List<Map<String, dynamic>>> _events = {};
  Set<int> _unseenEventIds = {};
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _selectedDay = DateTime.now();
    _fetchEvents();
  }

  Future<void> _fetchEvents() async {
    setState(() => _isLoading = true);
    final myId = _supabase.auth.currentUser!.id;
    try {
      final data = await _supabase
          .from('chat_events')
          .select()
          .eq('chat_id', widget.chatId);
      final viewsResp = await _supabase
          .from('chat_event_views')
          .select('event_id')
          .eq('user_id', myId);
      final viewedIds =
          (viewsResp as List).map((v) => v['event_id'] as int).toSet();

      final Map<DateTime, List<Map<String, dynamic>>> mappedEvents = {};
      final Set<int> unseen = {};

      for (var event in data) {
        final int eId = event['id'];
        if (!viewedIds.contains(eId)) unseen.add(eId);

        final repeat = event['repeat_type'] as String? ?? 'none';
        final startTime = DateTime.parse(event['start_time']).toLocal();
        final endTime = event['end_repeat'] != null
            ? DateTime.parse(event['end_repeat']).toLocal()
            : null;

        if (repeat == 'none') {
          final key = DateTime(startTime.year, startTime.month, startTime.day);
          if (mappedEvents[key] == null) mappedEvents[key] = [];
          mappedEvents[key]!.add(event);
        } else {
          for (int i = 0; i < 90; i++) {
            DateTime occDate;
            if (repeat == 'daily') {
              occDate = startTime.add(Duration(days: i));
            } else if (repeat == 'weekly') {
              occDate = startTime.add(Duration(days: i * 7));
            } else {
              continue;
            }
            if (endTime != null && occDate.isAfter(endTime)) break;
            final key = DateTime(occDate.year, occDate.month, occDate.day);
            if (mappedEvents[key] == null) mappedEvents[key] = [];
            mappedEvents[key]!.add(event);
          }
        }
      }

      if (mounted) {
        setState(() {
          _events = mappedEvents;
          _unseenEventIds = unseen;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // --- NEW: MARKS EVENTS AS SEEN AND TURNS THE DOT GREEN ---
  void _markDayAsSeen(DateTime day) async {
    final eventsForDay = _getEventsForDay(day);
    final unseenEvents =
        eventsForDay.where((e) => _unseenEventIds.contains(e['id'])).toList();

    if (unseenEvents.isNotEmpty) {
      final myId = _supabase.auth.currentUser!.id;
      final inserts = unseenEvents
          .map((e) => {'event_id': e['id'], 'user_id': myId})
          .toList();

      // Update UI immediately (dot turns green)
      setState(() {
        for (var e in unseenEvents) {
          _unseenEventIds.remove(e['id']);
        }
      });

      // Update DB silently
      try {
        await _supabase.from('chat_event_views').insert(inserts);
      } catch (e) {
        debugPrint("Failed to mark as seen: $e");
      }
    }
  }

  void _deleteEvent(int eventId) async {
    try {
      await _supabase.from('chat_events').delete().eq('id', eventId);
      _fetchEvents();
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Event Deleted')));
    } catch (e) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to delete event')));
    }
  }

  List<Map<String, dynamic>> _getEventsForDay(DateTime day) {
    return _events[DateTime(day.year, day.month, day.day)] ?? [];
  }

  void _onDaySelected(DateTime selectedDay, DateTime focusedDay) {
    setState(() {
      _selectedDay = selectedDay;
      _focusedDay = focusedDay;
    });

    // Mark viewed when a user taps a date
    _markDayAsSeen(selectedDay);
  }

  @override
  Widget build(BuildContext context) {
    final selectedEvents =
        _selectedDay != null ? _getEventsForDay(_selectedDay!) : [];
    final myId = _supabase.auth.currentUser!.id;

    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, scrollController) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF121212),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
                width: 40,
                height: 5,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(10))),
            const SizedBox(height: 16),
            const Text("Group Calendar",
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),
            const Divider(color: Colors.white10, height: 30),
            Expanded(
              child: CustomScrollView(
                controller: scrollController,
                slivers: [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16.0, vertical: 8),
                      child: Container(
                        decoration: BoxDecoration(
                            color: const Color(0xFF1E1E1E),
                            borderRadius: BorderRadius.circular(16)),
                        child: TableCalendar(
                          firstDay: DateTime.utc(2023, 1, 1),
                          lastDay: DateTime.utc(2030, 12, 31),
                          focusedDay: _focusedDay,
                          selectedDayPredicate: (day) =>
                              isSameDay(_selectedDay, day),
                          onDaySelected: _onDaySelected,
                          eventLoader: _getEventsForDay,
                          calendarFormat: CalendarFormat.month,
                          headerStyle: const HeaderStyle(
                            formatButtonVisible: false,
                            titleCentered: true,
                            titleTextStyle: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold),
                            leftChevronIcon:
                                Icon(Icons.chevron_left, color: Colors.white),
                            rightChevronIcon:
                                Icon(Icons.chevron_right, color: Colors.white),
                          ),
                          calendarBuilders: CalendarBuilders(
                            markerBuilder: (context, date, events) {
                              if (events.isEmpty)
                                return const SizedBox.shrink();

                              bool hasUnseen = false;
                              for (var event in events) {
                                if (event is Map<String, dynamic> &&
                                    _unseenEventIds.contains(event['id'])) {
                                  hasUnseen = true;
                                  break;
                                }
                              }

                              return Positioned(
                                bottom: 8,
                                child: Container(
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: hasUnseen
                                        ? Colors.redAccent
                                        : const Color(0xFF4CAF50),
                                  ),
                                ),
                              );
                            },
                          ),
                          calendarStyle: CalendarStyle(
                            defaultTextStyle:
                                const TextStyle(color: Colors.white),
                            weekendTextStyle:
                                const TextStyle(color: Colors.white70),
                            outsideTextStyle:
                                const TextStyle(color: Colors.white24),
                            selectedDecoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.2),
                                shape: BoxShape.circle),
                            selectedTextStyle: const TextStyle(
                                color: Color(0xFF4CAF50),
                                fontWeight: FontWeight.bold),
                            todayDecoration: BoxDecoration(
                                color: const Color(0xFF4CAF50).withOpacity(0.3),
                                shape: BoxShape.circle),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_isLoading)
                    const SliverFillRemaining(
                        child: Center(
                            child: CircularProgressIndicator(
                                color: Color(0xFF4CAF50))))
                  else if (selectedEvents.isEmpty)
                    const SliverFillRemaining(
                        child: Center(
                            child: Text("No events for this day",
                                style: TextStyle(color: Colors.white54))))
                  else
                    SliverPadding(
                      padding: const EdgeInsets.all(16),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final event = selectedEvents[index];
                            final timeStr = DateFormat.jm().format(
                                DateTime.parse(event['start_time']).toLocal());
                            final bool isCreator = event['creator_id'] == myId;
                            final DateTime createdAt =
                                DateTime.parse(event['created_at']).toLocal();
                            final bool canEdit = isCreator &&
                                DateTime.now()
                                        .difference(createdAt)
                                        .inMinutes <=
                                    60;
                            final bool canDelete = isCreator || widget.isAdmin;

                            return Card(
                              clipBehavior: Clip.antiAlias,
                              color: const Color(0xFF1E1E1E),
                              margin: const EdgeInsets.only(bottom: 16),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                  side: const BorderSide(
                                      color: Colors.white10, width: 1)),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (event['image_url'] != null)
                                    Image.network(event['image_url'],
                                        height: 160,
                                        width: double.infinity,
                                        fit: BoxFit.cover),
                                  ListTile(
                                    contentPadding: const EdgeInsets.all(16),
                                    title: Text(event['title'],
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 18,
                                            fontWeight: FontWeight.bold)),
                                    subtitle: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const SizedBox(height: 8),
                                        if (event['description'] != null &&
                                            event['description']
                                                .toString()
                                                .isNotEmpty)
                                          Padding(
                                              padding: const EdgeInsets.only(
                                                  bottom: 8.0),
                                              child: Text(event['description'],
                                                  style: const TextStyle(
                                                      color: Colors.white70))),
                                        Row(
                                          children: [
                                            const Icon(Icons.access_time,
                                                color: Color(0xFF4CAF50),
                                                size: 16),
                                            const SizedBox(width: 4),
                                            Text(
                                                "$timeStr • ${event['repeat_type'] == 'none' ? 'One-time' : 'Repeats ${event['repeat_type']}'}",
                                                style: const TextStyle(
                                                    color: Colors.white54,
                                                    fontWeight:
                                                        FontWeight.bold)),
                                          ],
                                        ),
                                      ],
                                    ),
                                    trailing: PopupMenuButton<String>(
                                      icon: const Icon(Icons.more_vert,
                                          color: Colors.white70),
                                      color: const Color(0xFF121212),
                                      onSelected: (val) {
                                        if (val == 'edit')
                                          _showAddEditEventModal(event: event);
                                        if (val == 'delete')
                                          _deleteEvent(event['id']);
                                      },
                                      itemBuilder: (ctx) => [
                                        if (canEdit || widget.isAdmin)
                                          const PopupMenuItem(
                                              value: 'edit',
                                              child: Text('Edit Event',
                                                  style: TextStyle(
                                                      color:
                                                          Colors.blueAccent))),
                                        if (canDelete)
                                          const PopupMenuItem(
                                              value: 'delete',
                                              child: Text('Delete Event',
                                                  style: TextStyle(
                                                      color:
                                                          Colors.redAccent))),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                          childCount: selectedEvents.length,
                        ),
                      ),
                    )
                ],
              ),
            ),
            if (widget.isAdmin || true)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                    color: Color(0xFF121212),
                    border: Border(top: BorderSide(color: Colors.white10))),
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4CAF50),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.add, color: Colors.black),
                    label: const Text('ADD EVENT',
                        style: TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 16)),
                    onPressed: () => _showAddEditEventModal(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _showAddEditEventModal({Map<String, dynamic>? event}) async {
    final bool isEditing = event != null;
    final formKey = GlobalKey<FormState>();
    final titleController =
        TextEditingController(text: isEditing ? event['title'] : '');
    final descriptionController =
        TextEditingController(text: isEditing ? event['description'] : '');
    XFile? pickedImage;
    String? existingImageUrl = isEditing ? event['image_url'] : null;

    TimeOfDay startTime = TimeOfDay.fromDateTime(isEditing
        ? DateTime.parse(event['start_time']).toLocal()
        : (_selectedDay ?? DateTime.now()));
    TimeOfDay endTime = TimeOfDay.fromDateTime(isEditing
        ? DateTime.parse(event['end_time']).toLocal()
        : (_selectedDay ?? DateTime.now()).add(const Duration(hours: 1)));
    String repeatValue = isEditing ? event['repeat_type'] : 'none';

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (modalContext, setModalState) => DraggableScrollableSheet(
          initialChildSize: 0.9,
          builder: (_, scrollController) => Container(
            decoration: const BoxDecoration(
                color: Color(0xFF121212),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
            padding: EdgeInsets.fromLTRB(
                24, 24, 24, MediaQuery.of(modalContext).viewInsets.bottom + 24),
            child: Form(
              key: formKey,
              child: ListView(
                controller: scrollController,
                children: [
                  Text(isEditing ? 'Edit Event' : 'Add Group Event',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 24),
                  GestureDetector(
                    onTap: () async {
                      final file = await ImagePicker()
                          .pickImage(source: ImageSource.gallery);
                      if (file != null)
                        setModalState(() {
                          pickedImage = file;
                          existingImageUrl = null;
                        });
                    },
                    child: Container(
                      height: 150,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(16),
                        image: pickedImage != null
                            ? DecorationImage(
                                image: FileImage(File(pickedImage!.path)),
                                fit: BoxFit.cover)
                            : (existingImageUrl != null
                                ? DecorationImage(
                                    image: NetworkImage(existingImageUrl!),
                                    fit: BoxFit.cover)
                                : null),
                      ),
                      child: (pickedImage == null && existingImageUrl == null)
                          ? const Center(
                              child: Icon(Icons.add_a_photo,
                                  color: Colors.white38, size: 40))
                          : null,
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                      controller: titleController,
                      style: const TextStyle(color: Colors.white),
                      decoration: _inputDecoration('Event Title'),
                      validator: (v) => v!.isEmpty ? 'Required' : null),
                  const SizedBox(height: 16),
                  TextFormField(
                      controller: descriptionController,
                      style: const TextStyle(color: Colors.white),
                      decoration: _inputDecoration('Description')),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                          child: _buildTimePicker(
                              modalContext,
                              'Starts',
                              startTime,
                              (t) => setModalState(() => startTime = t))),
                      const SizedBox(width: 16),
                      Expanded(
                          child: _buildTimePicker(modalContext, 'Ends', endTime,
                              (t) => setModalState(() => endTime = t))),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    value: repeatValue,
                    dropdownColor: const Color(0xFF1E1E1E),
                    style: const TextStyle(color: Colors.white),
                    decoration: _inputDecoration('Repeat'),
                    items: const [
                      DropdownMenuItem(
                          value: 'none', child: Text('Does not repeat')),
                      DropdownMenuItem(
                          value: 'daily', child: Text('Every day')),
                      DropdownMenuItem(
                          value: 'weekly', child: Text('Every week')),
                    ],
                    onChanged: (val) =>
                        setModalState(() => repeatValue = val ?? 'none'),
                  ),
                  const SizedBox(height: 32),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4CAF50),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12))),
                    onPressed: () async {
                      if (formKey.currentState!.validate()) {
                        final day = isEditing
                            ? DateTime.parse(event['start_time']).toLocal()
                            : (_selectedDay ?? DateTime.now());
                        final startDateTime = DateTime(day.year, day.month,
                            day.day, startTime.hour, startTime.minute);
                        var endDateTime = DateTime(day.year, day.month, day.day,
                            endTime.hour, endTime.minute);
                        if (endDateTime.isBefore(startDateTime))
                          endDateTime =
                              endDateTime.add(const Duration(days: 1));

                        String? finalImageUrl = existingImageUrl;
                        if (pickedImage != null) {
                          final bytes = await pickedImage!.readAsBytes();
                          final path = 'event_images/${const Uuid().v4()}.jpg';
                          await _supabase.storage
                              .from('chat_media')
                              .uploadBinary(path, bytes);
                          finalImageUrl = _supabase.storage
                              .from('chat_media')
                              .getPublicUrl(path);
                        }

                        if (isEditing) {
                          await _supabase.from('chat_events').update({
                            'title': titleController.text,
                            'description': descriptionController.text,
                            'start_time':
                                startDateTime.toUtc().toIso8601String(),
                            'end_time': endDateTime.toUtc().toIso8601String(),
                            'repeat_type': repeatValue,
                            'image_url': finalImageUrl,
                          }).eq('id', event['id']);
                        } else {
                          await _supabase.from('chat_events').insert({
                            'chat_id': widget.chatId,
                            'creator_id': _supabase.auth.currentUser!.id,
                            'title': titleController.text,
                            'description': descriptionController.text,
                            'start_time':
                                startDateTime.toUtc().toIso8601String(),
                            'end_time': endDateTime.toUtc().toIso8601String(),
                            'repeat_type': repeatValue,
                            'image_url': finalImageUrl,
                          });
                        }

                        if (mounted) {
                          Navigator.pop(ctx);
                          _fetchEvents();
                        }
                      }
                    },
                    child: Text(isEditing ? 'Save Changes' : 'Create Event',
                        style: const TextStyle(
                            color: Colors.black,
                            fontWeight: FontWeight.bold,
                            fontSize: 16)),
                  )
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTimePicker(BuildContext ctx, String label, TimeOfDay time,
      Function(TimeOfDay) onChanged) {
    return InkWell(
      onTap: () async {
        final picked = await showTimePicker(context: ctx, initialTime: time);
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
          decoration: _inputDecoration(label),
          child: Text(time.format(ctx),
              style: const TextStyle(color: Colors.white, fontSize: 16))),
    );
  }

  InputDecoration _inputDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54),
      filled: true,
      fillColor: const Color(0xFF1E1E1E),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
    );
  }
}
