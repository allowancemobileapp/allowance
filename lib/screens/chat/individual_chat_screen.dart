// lib/screens/chat/individual_chat_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/home/story_viewer_screen.dart';
import 'package:allowance/screens/home/video_trimmer_screen.dart';
import 'package:allowance/shared/services/chat_sync_service.dart';
import 'package:allowance/shared/services/fcm_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../../widgets/universal_profile_card.dart';
import '../../shared/services/chat_local_db.dart';
import 'package:record/record.dart';
import 'package:just_audio/just_audio.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:uuid/uuid.dart';
import '../../widgets/docked_sheet.dart';

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

class _IndividualChatScreenState extends State<IndividualChatScreen>
    with WidgetsBindingObserver {
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
  AppLifecycleState? _lastLifecycleState; // <-- ADD THIS
  Timer? _resumeDebounceTimer; // <-- ADD THIS

  // For file/media logic
  final Map<String, Color> _userColors = {};
  final AudioRecorder _audioRecorder = AudioRecorder();
  final Map<String, Future<Uint8List?>> _pendingThumbFutures = {};
  int _activeThumbGenerations = 0;
  static const int _maxConcurrentThumbGenerations = 2;
  bool _isRecording = false;
  String _recordDuration = "00:00";
  Timer? _recordTimer;
  Timer? _realtimeSelfHealTimer;
  int _recordSeconds = 0;
  String? _highlightedMessageId;
  Map<String, dynamic>? _pendingOrder;
  List<Map<String, dynamic>> _messages = [];
  StreamSubscription? _msgSub;
  StreamSubscription? _typingStatusSub;
  int _firstUnreadIndex = -1;
  bool _unreadCalculated = false;
  // Add next to _unreadCalculated:
  List<Map<String, dynamic>>? _cachedCombinedMessages;
  String _lastComputeSignature = '';
  List<Map<String, dynamic>> _pinnedMessages = [];
  StreamSubscription? _pinnedSub;
  String _lastPinnedSignature = '';

  // 🔥 FIX: Added the missing Video Cache and removed the duplicate colors map
  final Map<String, Uint8List> _chatVideoThumbCache = {};
  final Map<String, List<InlineSpan>> _regexCache = {};

  // (Deleted the unused _messageStream entirely)

  bool _isDisposed = false; // Add this field at the top of your State class

  @override
  void initState() {
    WidgetsBinding.instance.addObserver(this);
    super.initState();
    activeChatId = widget.chatId;

    // 🔥 NEW: Detect Enter key to send messages ONLY on Desktop Web!
    _focusNode.onKeyEvent = (node, event) {
      final isDesktopWeb = kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.macOS ||
              defaultTargetPlatform == TargetPlatform.windows ||
              defaultTargetPlatform == TargetPlatform.linux);

      if (isDesktopWeb) {
        // Look for the "Enter" key being pressed down
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.enter) {
          if (HardwareKeyboard.instance.isShiftPressed) {
            return KeyEventResult.ignored; // Shift+Enter allows new lines
          } else {
            _sendMessage(); // Just Enter sends the message
            return KeyEventResult
                .handled; // Stops the newline from being typed!
          }
        }
      }
      return KeyEventResult.ignored;
    };

    _scrollController.addListener(_scrollListener);

    final po = widget.recipientProfile['pending_order'];
    if (po != null) {
      try {
        _pendingOrder = po is String ? jsonDecode(po) : po;
      } catch (e) {
        debugPrint('Error parsing order: $e');
      }
    }

    SharedPreferences.getInstance().then((prefs) {
      final cachedFolls =
          prefs.getString('cached_folls_${supabase.auth.currentUser!.id}');
      if (cachedFolls != null) {
        final followingList = List<String>.from(jsonDecode(cachedFolls));
        if (followingList.contains(widget.recipientProfile['id'].toString()) &&
            mounted) {
          setState(() => _isFollowing = true);
        }
      }
    });

    _setupMessageStream();
    _startRealtimeSelfHeal();
    _setupPinnedMessagesStream();
    _setupTypingListener();
    _checkFollowStatus();
    _markMessagesAsRead();
  }

  Future<Uint8List?> _getVideoThumbnail(String videoUrl) {
    return _pendingThumbFutures.putIfAbsent(videoUrl, () async {
      while (_activeThumbGenerations >= _maxConcurrentThumbGenerations) {
        await Future.delayed(const Duration(milliseconds: 200));
        if (_isDisposed) return null;
      }
      _activeThumbGenerations++;
      try {
        // 🔥 Same fix as the audio player's .timeout() — a stalled network
        // read here was likely what's holding decoder/socket resources open.
        return await VideoThumbnail.thumbnailData(
          video: videoUrl,
          imageFormat: ImageFormat.JPEG,
          maxWidth: 400,
          quality: 50,
        ).timeout(const Duration(seconds: 10), onTimeout: () => null);
      } catch (_) {
        return null;
      } finally {
        _activeThumbGenerations--;
      }
    });
  }

  Future<void> _setupPinnedMessagesStream() async {
    final cached =
        await ChatLocalDB.instance.getPinnedMessagesForChat(widget.chatId);
    if (cached.isNotEmpty && mounted && !_isDisposed) {
      setState(() => _pinnedMessages = cached);
    }

    try {
      final resp = await supabase
          .from('messages')
          .select()
          .eq('chat_id', widget.chatId)
          .eq('media_type', 'event')
          .order('created_at', ascending: false);
      if (mounted && !_isDisposed) {
        final rows = List<Map<String, dynamic>>.from(resp);
        setState(() => _pinnedMessages = rows);
        await ChatLocalDB.instance.cacheMessages(widget.chatId, rows);
      }
    } catch (e) {
      debugPrint("Pinned messages fetch error: $e");
    }

    _pinnedSub?.cancel();
    _pinnedSub = supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('chat_id', widget.chatId)
        .order('created_at', ascending: false)
        .limit(300)
        .listen((data) async {
          if (!mounted || _isDisposed) return;
          final pinned = data
              .where((m) => m['media_type']?.toString() == 'event')
              .toList();

          final signature = pinned.map((m) => m['id'].toString()).join(',');
          if (signature == _lastPinnedSignature) return;
          _lastPinnedSignature = signature;

          setState(
              () => _pinnedMessages = List<Map<String, dynamic>>.from(pinned));
          await ChatLocalDB.instance.cacheMessages(widget.chatId, pinned);
        });
  }

  // 🔥 NEW: belt-and-suspenders. RealtimeGuardian keeps the socket's auth
  // fresh, but this periodically tears down and rejoins the channel
  // outright regardless of *why* it might've gone quiet (dead radio, OS
  // killed the background socket, etc.) — self-heals within ~25s instead
  // of needing you to leave and reopen the chat. Cheap in the common case:
  // _computeCombinedMessages already memoizes on a content signature, so
  // if nothing actually changed this mostly no-ops.
  void _startRealtimeSelfHeal() {
    _realtimeSelfHealTimer?.cancel();
    _realtimeSelfHealTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (!mounted || _isDisposed) return;
      _setupMessageStream();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final previousState = _lastLifecycleState;
    _lastLifecycleState = state;

    final wasActuallyBackgrounded = previousState == AppLifecycleState.paused ||
        previousState == AppLifecycleState.detached;

    if (state == AppLifecycleState.resumed &&
        wasActuallyBackgrounded &&
        mounted &&
        !_isDisposed) {
      _resumeDebounceTimer?.cancel();
      _resumeDebounceTimer = Timer(const Duration(milliseconds: 500), () {
        if (!mounted || _isDisposed) return;
        _setupMessageStream();
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted && !_isDisposed) _setupPinnedMessagesStream();
        });
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted && !_isDisposed) _setupTypingListener();
        });
        Future.delayed(const Duration(milliseconds: 450), () {
          if (mounted && !_isDisposed) _markMessagesAsRead();
        });
      });
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

  Widget _buildOrderCard(
      String jsonStr, String timeStr, bool isMe, bool isRead) {
    try {
      // 🔥 FIX: Cleaned up the JSON decode to remove the warning
      final data = jsonDecode(jsonStr);
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
    final localMessages =
        await ChatLocalDB.instance.getMessagesForChat(widget.chatId, limit: 50);
    if (localMessages.isNotEmpty && mounted && !_isDisposed) {
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
        .limit(50)
        .listen((data) async {
          // 🔥 FIX: Guard against disposed screen
          if (!mounted || _isDisposed) return;

          await Future.delayed(const Duration(milliseconds: 50));
          if (!mounted || _isDisposed) return;

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

  Future<void> _markMessagesAsRead() async {
    final currentUser = supabase.auth.currentUser;
    if (currentUser == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final readReceiptsEnabled = prefs.getBool('read_receipts') ?? true;
      if (!readReceiptsEnabled) return; // 🔥 Block read receipt if toggled off!

      await supabase.from('messages').update({'is_read': true}).match(
          {'chat_id': widget.chatId}).neq('sender_id', currentUser.id);
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
          // 🔥 FIX: Guard against disposed screen
          if (!mounted || _isDisposed) return;

          final myId = supabase.auth.currentUser?.id;
          final remoteTyping = data.any((p) =>
              p['user_id']?.toString() != myId && p['is_typing'] == true);

          // 🔥 FIX: Extra mounted check before setState
          if (mounted && !_isDisposed) {
            setState(() => _remoteUserIsTyping = remoteTyping);
          }

          if (remoteTyping) {
            _remoteTypingTimer?.cancel();
            _remoteTypingTimer = Timer(const Duration(seconds: 5), () {
              if (mounted && !_isDisposed) {
                setState(() => _remoteUserIsTyping = false);
              }
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
    if (myId == null || _isTyping == status || _isDisposed) return;

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

  // --- FIXED: ALWAYS SHOWS TIME (e.g., 4:30 PM) ---
  String _formatTime(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return "";
    try {
      DateTime date = DateTime.parse(timestamp).toLocal();
      return DateFormat('h:mm a')
          .format(date); // 🔥 ALWAYS returns the time (e.g., 4:30 PM)
    } catch (e) {
      return "";
    }
  }

  // =========================================================================
  // VOICE NOTE LOGIC (WEB & MOBILE SAFE)
  // =========================================================================
  Future<void> _startRecording() async {
    try {
      if (await _audioRecorder.hasPermission()) {
        String? filePath;

        if (!kIsWeb) {
          final dir = await getApplicationDocumentsDirectory();
          filePath =
              '${dir.path}/audio_${DateTime.now().millisecondsSinceEpoch}.m4a';
        }

        await _audioRecorder.start(
            const RecordConfig(encoder: AudioEncoder.aacLc),
            path: filePath ?? '');

        // 🔥 FIX: Guard setState
        if (mounted && !_isDisposed) {
          setState(() {
            _isRecording = true;
            _recordSeconds = 0;
            _recordDuration = "00:00";
          });
        }

        _recordTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
          if (!mounted || _isDisposed) {
            t.cancel();
            return;
          }
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
    if (!mounted || _isDisposed) return;

    setState(() => _isRecording = false);

    final path = await _audioRecorder.stop();
    if (path != null && _recordSeconds >= 1) {
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

    if (myId == null ||
        (text.isEmpty && mediaUrl == null && _pendingOrder == null)) return;

    // 🔥 CAPTURE REPLY STATE
    final replyId = _replyMessage?['id'];
    final replySummary = _getReplySummary();
    final currentOrder = _pendingOrder;

    _messageController.clear();

    setState(() {
      _replyMessage = null;
      _pendingOrder = null;
    });

    if (currentOrder != null) {
      ChatSyncService.instance.enqueueMessage({
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': jsonEncode(currentOrder),
        'media_type': 'order',
      });
    }

    if (text.isNotEmpty || mediaUrl != null) {
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
  }

  // --- ADD THIS MISSING SCROLL LISTENER ---
  void _scrollListener() {
    if (!_scrollController.hasClients) return;
    if (!mounted || _isDisposed) return;

    final offset = _scrollController.offset;
    final shouldShow = offset >= 300;

    if (shouldShow != _showScrollToBottom) {
      setState(() => _showScrollToBottom = shouldShow);
    }
  }

  @override
  void dispose() {
    _isDisposed = true;

    // 🔥 UPDATED: was the local _dismissDockedSheet() — now every docked
    // sheet in the app is tracked by the one shared DockedSheet class.
    DockedSheet.dismiss();

    WidgetsBinding.instance.removeObserver(this);

    _msgSub?.cancel();
    _msgSub = null;
    _typingStatusSub?.cancel();
    _typingStatusSub = null;

    _typingTimer?.cancel();
    _typingTimer = null;
    _remoteTypingTimer?.cancel();
    _remoteTypingTimer = null;
    _recordTimer?.cancel();
    _recordTimer = null;
    _resumeDebounceTimer?.cancel();
    _resumeDebounceTimer = null;
    _pinnedSub?.cancel();
    _pinnedSub = null;
    _realtimeSelfHealTimer?.cancel();

    _scrollController.removeListener(_scrollListener);

    if (_isRecording) {
      _audioRecorder.stop().catchError((_) => null);
      _isRecording = false;
    }

    _messageController.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _audioRecorder.dispose();

    final myId = supabase.auth.currentUser?.id;
    if (myId != null) {
      supabase.from('chat_participants').update({
        'is_typing': false,
      }).match({'chat_id': widget.chatId, 'user_id': myId}).catchError((_) {});
    }

    if (activeChatId == widget.chatId) {
      activeChatId = null;
    }

    super.dispose();
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

  // --- NEW: HELPER TO EXTRACT REPLY TEXT/MEDIA TYPE ---
  String _getReplySummary() {
    if (_replyMessage == null) return '';
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

  List<Map<String, dynamic>> _computeCombinedMessages(
      List<Map<String, dynamic>> pendingList, String? myId) {
    final myPending =
        pendingList.where((m) => m['chat_id'] == widget.chatId).toList();

    final Map<String, Map<String, dynamic>> byId = {};
    for (final m in _messages) {
      final key = (m['id'] ?? m['local_id'] ?? '').toString();
      if (key.isNotEmpty) byId[key] = m;
    }
    for (final m in _pinnedMessages) {
      final key = (m['id'] ?? m['local_id'] ?? '').toString();
      if (key.isNotEmpty && !byId.containsKey(key)) byId[key] = m;
    }
    final mergedMessages = byId.values.toList();

    final sig = StringBuffer()
      ..write(myPending.length)
      ..write('|');
    for (final p in myPending) {
      sig
        ..write(p['local_id'])
        ..write(':')
        ..write(p['is_failed'])
        ..write(':')
        ..write(p['is_pending'])
        ..write(';');
    }
    sig
      ..write('#')
      ..write(mergedMessages.length)
      ..write('|');
    for (final m in mergedMessages) {
      sig
        ..write(m['id'])
        ..write(':')
        ..write(m['local_id'])
        ..write(':')
        ..write(m['is_edited'])
        ..write(':')
        ..write(m['seriousness'])
        ..write(':')
        ..write(m['reactions'])
        ..write(':')
        ..write(m['is_read'])
        ..write(';');
    }
    final signature = sig.toString();

    if (_cachedCombinedMessages != null && signature == _lastComputeSignature) {
      return _cachedCombinedMessages!;
    }

    final confirmedLocalIds = mergedMessages
        .map((m) => m['local_id']?.toString())
        .where((id) => id != null && id.isNotEmpty)
        .toSet();

    final visiblePending = myPending.where((p) {
      if (p['is_failed'] == true) return true;
      return !confirmedLocalIds.contains(p['local_id']?.toString());
    }).toList();

    final combined = [...visiblePending, ...mergedMessages];
    combined.sort((a, b) {
      try {
        final aStr = a['created_at']?.toString();
        final bStr = b['created_at']?.toString();
        final dateA = (aStr != null && aStr.isNotEmpty)
            ? DateTime.parse(aStr).toLocal()
            : DateTime.fromMillisecondsSinceEpoch(0);
        final dateB = (bStr != null && bStr.isNotEmpty)
            ? DateTime.parse(bStr).toLocal()
            : DateTime.fromMillisecondsSinceEpoch(0);
        return dateB.compareTo(dateA);
      } catch (e) {
        return 0;
      }
    });

    _cachedCombinedMessages = combined;
    _lastComputeSignature = signature;
    return combined;
  }

  // --- UPDATED: WEB KEYBOARD FIX & UNREAD MESSAGES SEPARATOR ---
  @override
  Widget build(BuildContext context) {
    final double maxBubbleWidth = MediaQuery.sizeOf(context).width * 0.75;
    final myId = supabase.auth.currentUser?.id;

    return Scaffold(
      backgroundColor: Colors.black,
      resizeToAvoidBottomInset:
          true, // 🔥 FIX: Let the OS handle the keyboard inset natively
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(
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
                      try {
                        _firstUnreadIndex =
                            combinedMessages.lastIndexWhere((m) {
                          final senderId = m['sender_id']?.toString();
                          final isRead = m['is_read'] == true;
                          return !isRead &&
                              senderId != null &&
                              senderId != myId;
                        });
                      } catch (e) {
                        _firstUnreadIndex = -1;
                      }
                      _unreadCalculated = true;
                    }

                    return ListView.builder(
                      controller: _scrollController,
                      reverse: true,
                      cacheExtent: 400,
                      keyboardDismissBehavior:
                          ScrollViewKeyboardDismissBehavior.manual,
                      padding: const EdgeInsets.all(12),
                      itemCount: combinedMessages.length,
                      itemBuilder: (context, index) {
                        try {
                          final msg = combinedMessages[index];
                          final messageId =
                              (msg['id'] ?? msg['local_id'] ?? 'idx_$index')
                                  .toString();

                          DateTime date;
                          try {
                            final createdAt = msg['created_at']?.toString();
                            date = (createdAt != null && createdAt.isNotEmpty)
                                ? DateTime.parse(createdAt).toLocal()
                                : DateTime.now();
                          } catch (e) {
                            date = DateTime.now();
                          }

                          bool showDateHeader = false;
                          if (index == combinedMessages.length - 1) {
                            showDateHeader = true;
                          } else {
                            try {
                              final prevMsg = combinedMessages[index + 1];
                              final prevCreatedAt =
                                  prevMsg['created_at']?.toString();
                              if (prevCreatedAt != null &&
                                  prevCreatedAt.isNotEmpty) {
                                final prevDate =
                                    DateTime.parse(prevCreatedAt).toLocal();
                                if (date.day != prevDate.day ||
                                    date.year != prevDate.year) {
                                  showDateHeader = true;
                                }
                              }
                            } catch (e) {
                              showDateHeader = false;
                            }
                          }

                          return RepaintBoundary(
                            key: ValueKey('msg_row_$messageId'),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
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
                                    margin: const EdgeInsets.symmetric(
                                        vertical: 16),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 4),
                                    decoration: BoxDecoration(
                                        color: const Color(0xFF1E1E1E),
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                    child: const Text("UNREAD MESSAGES",
                                        style: TextStyle(
                                            color: Colors.amber,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold)),
                                  ),
                                _buildBubble(
                                    combinedMessages, index, maxBubbleWidth),
                              ],
                            ),
                          );
                        } catch (e) {
                          debugPrint(
                              '💀 Message render error at index $index: $e');
                          return const SizedBox.shrink();
                        }
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
          SafeArea(
            top: false,
            child: RepaintBoundary(child: _buildInputBar()),
          ),
        ],
      ),
    );
  }

  // 4. INPUT BAR (With Gboard GIF/Sticker Injection)
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
          if (_pendingOrder != null) _buildOrderPreview(),
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
                        keyboardType: TextInputType.multiline,
                        scrollPadding: EdgeInsets.zero,
                        enableInteractiveSelection: true,
                        textInputAction: TextInputAction.newline,
                        onChanged: _handleTyping,
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
                      return GestureDetector(
                        onTap: () => _sendMessage(),
                        child: Container(
                          margin: const EdgeInsets.only(left: 8, bottom: 4),
                          padding: const EdgeInsets.all(10),
                          child: const Icon(Icons.send,
                              color: Color(0xFF4CAF50), size: 24),
                        ),
                      );
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
        // 🔥 NEW: Our Calendar button for individual chats
        if (!isGroup)
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
                    builder: (context) => OurCalendarSheet(
                      chatId: widget.chatId,
                    ),
                  );
                },
              ),
            ],
          ),
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
                                  await Supabase.instance.client
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

  Future<void> _pickAndUploadSticker() async {
    try {
      final picker = ImagePicker();
      final pickedFile =
          await picker.pickImage(source: ImageSource.gallery, imageQuality: 50);
      if (pickedFile == null) return;

      XFile? finalFile = pickedFile;

      // Web bypasses cropper to prevent UI freeze
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
        if (croppedFile != null) {
          finalFile = XFile(croppedFile.path);
        } else {
          return;
        }
      }

      final myId = supabase.auth.currentUser?.id;
      if (myId == null) return;

      // 🔥 CAPTURE REPLY STATE
      final replyId = _replyMessage?['id'];
      final replySummary =
          _replyMessage != null ? _getReplySummary() : 'Sticker';
      setState(() => _replyMessage = null);

      // Sent to ChatSyncService safely!
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

    // 🔥 CAPTURE REPLY STATE
    final replyId = _replyMessage?['id'];
    final replySummary = _replyMessage != null ? _getReplySummary() : 'Sticker';

    setState(() => _replyMessage = null); // Clear UI

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

  // --- FIXED: CHAT ROOM BUBBLE WITH REACTIONS & AVATARS ---
  // --- FIXED: CHAT ROOM BUBBLE WITH REACTIONS & AVATARS ---
  Widget _buildBubble(
      List<Map<String, dynamic>> messages, int index, double maxWidth) {
    final message = messages[index];
    final messageId = (message['id'] ?? message['local_id']).toString();
    final localId = message['local_id'];

    final myId = supabase.auth.currentUser?.id;
    final isMe = message['sender_id']?.toString() == myId;
    final content = (message['content'] ?? '').toString();
    final timeStr =
        _formatTime(message['created_at']?.toString() ?? message['created_at']);
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

    final String? mediaUrlStr = message['media_url']?.toString();
    final List<String> localPaths =
        List<String>.from(message['local_paths'] ?? []);

    final bool hasMediaUrl =
        mediaUrlStr != null && mediaUrlStr.trim().isNotEmpty;
    final bool hasLocalPaths = localPaths.isNotEmpty;
    final List<String> mediaUrls = (isPending && hasLocalPaths)
        ? localPaths
        : (hasMediaUrl ? mediaUrlStr.split(',') : []);

    // 🔥 FIX: Track if the View Once media was opened
    final bool isOpened = content == 'Opened';

    // 🔥 FIX: Prevent the "Receiving..." loader if it was already opened
    final bool isReceivingMedia = !isMe &&
        (isImageOrVideo || isViewOnce) &&
        !hasMediaUrl &&
        !hasLocalPaths &&
        !isOpened;

    final bool showMediaSection =
        isImageOrVideo && (hasMediaUrl || hasLocalPaths);
    final bool isHighlighted = _highlightedMessageId == messageId;

    final List<Color> sColors = [
      const Color(0xFF4CAF50),
      Colors.amber[700]!,
      Colors.orange,
      Colors.redAccent
    ];
    final bubbleColor = isMe ? sColors[seriousness] : Colors.grey[800]!;

    final bool hasCaption = content.isNotEmpty &&
        content != '📸 Photo' &&
        content != '🎥 Video' &&
        content != '🎤 Voice Note' &&
        content != 'Sticker/GIF' &&
        content != 'Opened' &&
        content.trim() != '';

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
                      imageUrl: evtMediaUrl.split(',').first,
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

    // --- VIEW ONCE UI ---
    if (isViewOnce && (hasMediaUrl || hasLocalPaths || isOpened)) {
      return Align(
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

            // Instantly update UI and delete from DB!
            setState(() {
              message['content'] = 'Opened';
              message['media_url'] = null;
            });
            await supabase.from('messages').update(
                {'content': 'Opened', 'media_url': null}).eq('id', messageId);
          },
          onLongPress: () => _showMessageOptions(message, isMe),
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
                color: bubbleColor,
                borderRadius: BorderRadius.circular(20).copyWith(
                    topRight: isMe ? Radius.zero : const Radius.circular(20),
                    topLeft: !isMe ? Radius.zero : const Radius.circular(20))),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(isOpened ? Icons.looks_one_outlined : Icons.looks_one,
                    color: isOpened ? Colors.white38 : Colors.blueAccent,
                    size: 24),
                const SizedBox(width: 8),
                Text(
                    isOpened
                        ? 'Opened'
                        : (mediaType.contains('video') ? 'Video' : 'Photo'),
                    style: TextStyle(
                        color: isOpened
                            ? Colors.white54
                            : (isMe ? Colors.black87 : Colors.white),
                        fontSize: 16,
                        fontStyle:
                            isOpened ? FontStyle.italic : FontStyle.normal)),
                const SizedBox(width: 16),
                _buildMediaTime(timeStr, isMe, isRead,
                    isPending: isPending, isFailed: isFailed, localId: localId),
              ],
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

      // 🔥 FIX: Detect if this sticker is replying to something
      final bool hasReply = message['reply_to_id'] != null ||
          (message['reply_content']?.toString().startsWith('Story_') ?? false);

      return RepaintBoundary(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          decoration: BoxDecoration(
              color: isHighlighted
                  ? const Color(0xFF4CAF50).withOpacity(0.3)
                  : Colors.transparent),
          child: Dismissible(
            key: Key('dismiss_$messageId'),
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
          key: Key('dismiss_$messageId'),
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
                Flexible(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      GestureDetector(
                        onLongPress: () => _showMessageOptions(message, isMe),
                        behavior: HitTestBehavior.opaque,
                        child: Container(
                          key: ValueKey(messageId),
                          margin: const EdgeInsets.only(
                              bottom: 8, left: 8, right: 8),
                          constraints: BoxConstraints(maxWidth: maxWidth),
                          decoration: BoxDecoration(
                            color: bubbleColor,
                            borderRadius: BorderRadius.circular(20).copyWith(
                              topRight: isMe
                                  ? Radius.zero
                                  : const Radius.circular(20),
                              topLeft: !isMe
                                  ? Radius.zero
                                  : const Radius.circular(20),
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20).copyWith(
                              topRight: isMe
                                  ? Radius.zero
                                  : const Radius.circular(20),
                              topLeft: !isMe
                                  ? Radius.zero
                                  : const Radius.circular(20),
                            ),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: maxWidth,
                                minWidth: 0,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (isOrder)
                                    _buildOrderCard(
                                        content, timeStr, isMe, isRead),
                                  if (message['reply_to_id'] != null ||
                                      (message['reply_content']
                                              ?.startsWith('Story_') ??
                                          false))
                                    _buildReplyInsideBubble(message),
                                  if (isAudio && (hasMediaUrl || hasLocalPaths))
                                    AudioPlayerBubble(
                                        url: mediaUrls.first,
                                        isMe: isMe,
                                        themeColor: const Color(0xFF121212),
                                        timeStr: timeStr,
                                        isRead: isRead,
                                        audioName: content.isNotEmpty &&
                                                content != '🎤 Voice Note'
                                            ? content
                                            : 'Voice Note'), // 🔥 FIX: Passes actual audio name
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
                                                Expanded(
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

      // 🔥 FIX: Added 'chats:chat_id(group_name, group_avatar, is_public)' so group details load correctly!
      final response = await supabase
          .from('stories')
          .select(
              '*, profiles:user_id(username, avatar_url, school_name, subscription_tier), chats:chat_id(group_name, group_avatar, is_public)')
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

    // Sort oldest first so swiping right goes to NEWER media (WhatsApp style)
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

  // --- NEW MODULAR MEDIA BUILDERS ---
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
    final String effectiveUrl =
        (isPending && localPaths.isNotEmpty) ? localPaths.first : url;

    Widget mediaWidget;

    if (isPending && localPaths.isNotEmpty) {
      if (isVideo) {
        if (kIsWeb) {
          mediaWidget = _VideoFramePreview(url: effectiveUrl);
        } else {
          if (_chatVideoThumbCache.containsKey(effectiveUrl)) {
            mediaWidget = Image.memory(_chatVideoThumbCache[effectiveUrl]!,
                fit: BoxFit.cover,
                width: double.infinity,
                height: height ?? 200);
          } else {
            final future = _getVideoThumbnail(effectiveUrl);
            mediaWidget = FutureBuilder<Uint8List?>(
              future: future,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.done) {
                  _pendingThumbFutures.remove(effectiveUrl);
                  if (snapshot.data != null) {
                    _chatVideoThumbCache[effectiveUrl] = snapshot.data!;
                    return Image.memory(snapshot.data!,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: height ?? 200);
                  }
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
        if (kIsWeb) {
          mediaWidget = Image.network(effectiveUrl,
              fit: BoxFit.cover,
              width: double.infinity,
              height: height ?? 200,
              errorBuilder: (_, __, ___) => _buildErrorPlaceholder(false));
        } else {
          mediaWidget = Image.file(File(effectiveUrl),
              fit: BoxFit.cover,
              width: double.infinity,
              height: height ?? 200,
              errorBuilder: (_, __, ___) => _buildErrorPlaceholder(false));
        }
      }
    } else {
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
            mediaWidget = _VideoFramePreview(url: effectiveUrl);
          } else {
            if (_chatVideoThumbCache.containsKey(effectiveUrl)) {
              mediaWidget = Image.memory(_chatVideoThumbCache[effectiveUrl]!,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: height ?? 200);
            } else {
              final future = _pendingThumbFutures.putIfAbsent(
                effectiveUrl,
                () => VideoThumbnail.thumbnailData(
                        video: effectiveUrl,
                        imageFormat: ImageFormat.JPEG,
                        maxWidth: 400,
                        quality: 50)
                    .catchError((_) => null),
              );
              mediaWidget = FutureBuilder<Uint8List?>(
                future: future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.done) {
                    _pendingThumbFutures.remove(effectiveUrl);
                    if (snapshot.data != null) {
                      _chatVideoThumbCache[effectiveUrl] = snapshot.data!;
                      return Image.memory(snapshot.data!,
                          fit: BoxFit.cover,
                          width: double.infinity,
                          height: height ?? 200);
                    }
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
                },
              );
            }
          }
        }
      } else {
        mediaWidget = CachedNetworkImage(
            imageUrl: effectiveUrl,
            fit: BoxFit.cover,
            width: double.infinity,
            height: height ?? 200,
            memCacheWidth: 800,
            memCacheHeight: 800,
            maxWidthDiskCache: 1200,
            maxHeightDiskCache: 1200,
            placeholder: (context, url) => Container(
                  color: Colors.grey[900],
                  child: const Center(
                    child: CircularProgressIndicator(
                      color: Color(0xFF4CAF50),
                      strokeWidth: 2,
                    ),
                  ),
                ),
            errorWidget: (c, u, e) => _buildErrorPlaceholder(false));
      }
    }

    return GestureDetector(
      onTap: () {
        if (!isPending) _openFullScreen(effectiveUrl);
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
                                        width: 50,
                                        height: 50,
                                        child: CircularProgressIndicator(
                                            value: progress,
                                            color: const Color(0xFF4CAF50),
                                            backgroundColor: Colors.white24,
                                            strokeWidth: 4)),
                                    IconButton(
                                        icon: const Icon(Icons.close,
                                            color: Colors.white, size: 24),
                                        onPressed: () => ChatSyncService
                                            .instance
                                            .cancelMessage(localId)),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                        color: Colors.black54,
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                    child: Text('$percent%',
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 12,
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

  Widget _buildCompactMedia(
      List<String> urls, String mediaType, Map<String, dynamic> message) {
    return urls.length == 1
        ? _buildSingleMediaItem(urls[0], mediaType, urls, 0, message)
        : _buildMediaCollage(urls, mediaType, message);
  }

  Widget _buildMediaWithOverlay(List<String> urls, String type, String time,
      bool isMe, bool isRead, Map<String, dynamic> message) {
    return Stack(
      children: [
        _buildCompactMedia(urls, type, message),
        Positioned(
          bottom: 4,
          right: 4,
          child: _buildMediaTime(time, isMe, isRead,
              isPending: message['is_pending'] == true,
              isFailed: message['is_failed'] == true,
              localId: message['local_id']),
        ),
      ],
    );
  }

  Widget _buildMediaTime(String time, bool isMe, bool isRead,
      {bool isPending = false, bool isFailed = false, String? localId}) {
    return Container(
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
                  onTap: () => ChatSyncService.instance.retryMessage(localId!),
                  child: const Icon(Icons.refresh,
                      size: 14, color: Colors.redAccent))
            else if (isPending)
              const Icon(Icons.access_time, size: 12, color: Colors.white70)
            else
              Icon(isRead ? Icons.done_all : Icons.done,
                  size: 12, color: isRead ? Colors.blueAccent : Colors.white70),
          ],
        ],
      ),
    );
  }

  Widget _buildMediaCollage(
      List<String> urls, String mediaType, Map<String, dynamic> message) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2, crossAxisSpacing: 4, mainAxisSpacing: 4),
      itemCount: urls.length > 4 ? 4 : urls.length,
      itemBuilder: (context, index) {
        if (index == 3 && urls.length > 4) {
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
                          _buildErrorPlaceholder(isVideo))
                else
                  _buildErrorPlaceholder(isVideo),
                Container(
                    color: Colors.black54,
                    alignment: Alignment.center,
                    child: Text('+${urls.length - 4}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold))),
              ],
            ),
          );
        }
        return _buildSingleMediaItem(
            urls[index], mediaType, urls, index, message);
      },
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

  // --- COMPACT WHATSAPP-STYLE MENU ITEM ---
  Widget _buildHorizontalOption({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: color, size: 24),
            const SizedBox(width: 16),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500)),
          ],
        ),
      ),
    );
  }

  void _showPlusOptions() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Center(
                  child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(10)))),
              const SizedBox(height: 12),
              _buildHorizontalOption(
                  icon: Icons.insert_drive_file,
                  label: 'Document',
                  color: Colors.blueAccent,
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickAndUploadFile();
                  }),
              _buildHorizontalOption(
                  icon: Icons.photo,
                  label: 'Gallery',
                  color: const Color(0xFF4CAF50),
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickAndUploadMedia(ImageSource.gallery, 'image');
                  }),
              _buildHorizontalOption(
                  icon: Icons.videocam,
                  label: 'Video',
                  color: Colors.pinkAccent,
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickAndUploadMedia(ImageSource.gallery, 'video');
                  }),
              _buildHorizontalOption(
                  icon: Icons.camera_alt,
                  label: 'Camera',
                  color: Colors.orangeAccent,
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickAndUploadMedia(ImageSource.camera, 'image');
                  }),
              _buildHorizontalOption(
                  icon: Icons.audiotrack,
                  label: 'Audio',
                  color: Colors.deepPurpleAccent,
                  onTap: () {
                    Navigator.pop(ctx);
                    _pickAndUploadAudioFile();
                  }),
              _buildHorizontalOption(
                  icon: Icons.emoji_emotions,
                  label: 'Stickers',
                  color: Colors.purpleAccent,
                  onTap: () {
                    Navigator.pop(ctx);
                    _showStickerMenu();
                  }),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

  void _showChatMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 12),
              Center(
                  child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(10)))),
              const SizedBox(height: 12),
              _buildHorizontalOption(
                  icon: Icons.group_add,
                  label: 'Create Group',
                  color: const Color(0xFF4CAF50),
                  onTap: () {
                    Navigator.pop(ctx); /* Create Group */
                  }),
              _buildHorizontalOption(
                  icon: Icons.block,
                  label: 'Block User',
                  color: Colors.redAccent,
                  onTap: () {
                    Navigator.pop(ctx); /* Block */
                  }),
              _buildHorizontalOption(
                  icon: Icons.archive,
                  label: 'Archive Chat',
                  color: Colors.blueAccent,
                  onTap: () {
                    Navigator.pop(ctx); /* Archive */
                  }),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

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
      } catch (e) {}
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
              _buildHorizontalOption(
                  icon: Icons.reply,
                  label: 'Reply',
                  color: Colors.blueAccent,
                  onTap: () {
                    Navigator.pop(ctx);
                    _onSwipeToReply(message);
                  }),
              _buildHorizontalOption(
                  icon: Icons.forward,
                  label: 'Forward',
                  color: Colors.blueAccent,
                  onTap: () {
                    Navigator.pop(ctx);
                    _showForwardSheet(message);
                  }),
              if (isMe)
                _buildHorizontalOption(
                    icon: Icons.speed,
                    label: 'Set Message Mood',
                    color: Colors.orange,
                    onTap: () {
                      Navigator.pop(ctx);
                      _showSeriousnessSlider(message);
                    }),

              // 🔥 FIX: RESTORED THE STICKER SAVER
              if (stickerUrl != null)
                FutureBuilder<bool>(
                  future: _isStickerSaved(stickerUrl),
                  builder: (context, snapshot) {
                    final isSaved = snapshot.data ?? false;
                    return _buildHorizontalOption(
                        icon: isSaved
                            ? Icons.bookmark_remove
                            : Icons.bookmark_add,
                        label: isSaved ? 'Remove Sticker' : 'Save Sticker',
                        color: isSaved
                            ? Colors.orangeAccent
                            : const Color(0xFF4CAF50),
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
                              if (mounted)
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('Sticker removed')));
                            } else {
                              await supabase.from('saved_stickers').insert({
                                'user_id': myId,
                                'url': stickerUrl,
                                'created_at': DateTime.now().toIso8601String()
                              });
                              if (mounted)
                                ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                        content: Text('Sticker saved!'),
                                        backgroundColor: Color(0xFF4CAF50)));
                            }
                          } catch (e) {}
                        });
                  },
                ),

              if (hasContent && !isSticker)
                _buildHorizontalOption(
                    icon: Icons.copy,
                    label: 'Copy Text',
                    color: Colors.white,
                    onTap: () {
                      Navigator.pop(ctx);
                      Clipboard.setData(
                          ClipboardData(text: message['content']));
                    }),
              if (isMe && canEdit && isText)
                _buildHorizontalOption(
                    icon: Icons.edit,
                    label: 'Edit Message',
                    color: Colors.white,
                    onTap: () {
                      Navigator.pop(ctx);
                      _showEditDialog(message);
                    }),
              if (isMe)
                _buildHorizontalOption(
                    icon: Icons.delete,
                    label: 'Delete Message',
                    color: Colors.redAccent,
                    onTap: () {
                      Navigator.pop(ctx);
                      _deleteMessage(message['id']);
                    }),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  void _showStickerMenu() {
    if (!mounted) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
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
                            color: Colors.white54, size: 28)),
                  ],
                ),
                const SizedBox(height: 16),
                ConstrainedBox(
                  constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * 0.4),
                  child: FutureBuilder(
                      future: supabase
                          .from('saved_stickers')
                          .select('id, url')
                          .eq('user_id', supabase.auth.currentUser!.id)
                          .order('created_at', ascending: false),
                      builder: (context, AsyncSnapshot<dynamic> snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting)
                          return const Center(
                              child: CircularProgressIndicator(
                                  color: Color(0xFF4CAF50)));
                        final savedStickers = List<Map<String, dynamic>>.from(
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
                                          color: Colors.white, size: 36)),
                                );
                              }
                              final url =
                                  savedStickers[index - 1]['url'].toString();
                              return GestureDetector(
                                onTap: () {
                                  _sendExistingSticker(url);
                                  HapticFeedback.lightImpact();
                                },
                                child: ClipRRect(
                                    borderRadius: BorderRadius.circular(12),
                                    child: CachedNetworkImage(
                                        imageUrl: url, fit: BoxFit.cover)),
                              );
                            });
                      }),
                )
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showForwardSheet(Map<String, dynamic> message) async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;
    final res = await supabase
        .from('followers')
        .select('following_id')
        .eq('follower_id', myId);
    final followingIds = res.map((e) => e['following_id']).toList();
    List<dynamic> friends = [];
    if (followingIds.isNotEmpty)
      friends = await supabase
          .from('profiles')
          .select('id, username, avatar_url')
          .inFilter('id', followingIds);
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
                                    ChatSyncService.instance.enqueueMessage({
                                      'chat_id': response.toString(),
                                      'sender_id': myId,
                                      'content': message['content'] ?? '',
                                      'media_type':
                                          message['media_type'] ?? 'text',
                                      'media_url': message['media_url'],
                                    });
                                  }
                                  if (mounted) {
                                    Navigator.pop(ctx);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                            content: Text('Forwarded!'),
                                            backgroundColor: Colors.green));
                                  }
                                },
                          child: isSending
                              ? const CircularProgressIndicator(
                                  color: Colors.black)
                              : const Text('Send',
                                  style: TextStyle(
                                      color: Colors.black,
                                      fontWeight: FontWeight.bold)),
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

  // --- NEW UI HELPER FOR HORIZONTAL COLORFUL BARS (COMPACT VERSION) ---

  Future<void> _pickAndUploadAudioFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        withData: kIsWeb,
      );
      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Sending Audio...')));

      final ext = file.extension ?? 'mp3';
      final fileName =
          '${DateTime.now().millisecondsSinceEpoch}_${file.name.hashCode}.$ext';
      final path = 'chat_media/${widget.chatId}/$fileName';

      if (kIsWeb) {
        await supabase.storage
            .from('chat_media')
            .uploadBinary(path, file.bytes!);
      } else {
        await supabase.storage
            .from('chat_media')
            .upload(path, File(file.path!));
      }

      final publicUrl = supabase.storage.from('chat_media').getPublicUrl(path);
      final myId = supabase.auth.currentUser?.id;
      if (myId == null) return;

      ChatSyncService.instance.enqueueMessage({
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': file.name,
        'media_type': 'audio',
        'media_url': publicUrl,
        'file_size_bytes': file.size,
      });
    } catch (e) {
      debugPrint("Audio upload error: $e");
    }
  }

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
      '🙌',
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
                  await Supabase.instance.client.from('messages').update(
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

// --- NEW: one colorful "add to chat" tile, styled like your activity tag pill, scaled up ---

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

  // --- NEW: MEDIA UPLOADER (Memory Optimized & Editable) ---
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

      String finalPickedPath = pickedFile.path;

      if (type == 'video' && !kIsWeb) {
        final pickedSize = await File(finalPickedPath).length();
        const warnAtBytes = 80 * 1024 * 1024;
        if (pickedSize > warnAtBytes && mounted) {
          final sizeMb = (pickedSize / (1024 * 1024)).toStringAsFixed(0);
          final shouldTrim = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: Colors.grey[900],
              title: const Text('Large video',
                  style: TextStyle(color: Colors.white)),
              content: Text(
                  'This video is ${sizeMb}MB. On a lot of phones that\'s enough to crash mid-upload. Trim it down first?',
                  style: const TextStyle(color: Colors.white70)),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Send anyway',
                        style: TextStyle(color: Colors.white54))),
                TextButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Trim it',
                        style: TextStyle(
                            color: Color(0xFF4CAF50),
                            fontWeight: FontWeight.bold))),
              ],
            ),
          );
          if (shouldTrim == true) {
            final trimmedPath = await Navigator.push<String?>(
                context,
                MaterialPageRoute(
                    builder: (context) =>
                        VideoTrimmerScreen(file: File(finalPickedPath))));
            if (trimmedPath != null) finalPickedPath = trimmedPath;
          }
        }
      }

      final captionController = TextEditingController();
      XFile currentFile = XFile(finalPickedPath);
      bool isViewOnce = false;

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
  bool _initialized = false; // 🔥 guards against re-subscribing

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
    if (_initialized) return;
    _initialized = true;

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
        // 🔥 THE FIX: this had no timeout. A stalled connection could hang
        // here indefinitely, and nothing after it — including the two
        // lines that turn the spinner off — ever ran. Matches exactly
        // what you saw, and exactly why it correlated with bad network.
        await _player.setUrl(url).timeout(const Duration(seconds: 15));
        _isLoaded = true;
        await _player.play();
      } catch (e) {
        debugPrint("Audio load error: $e");
        _isLoaded = false;
      } finally {
        // finally, not "after the try" — this now runs on timeout too,
        // so the spinner always resolves one way or the other.
        _isLoading = false;
        _loadingController.add(false);
      }
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
// LAZY-LOADED WHATSAPP-STYLE AUDIO PLAYER (With Download System)
// =========================================================================
class AudioPlayerBubble extends StatefulWidget {
  final String url;
  final bool isMe;
  final Color themeColor;
  final String timeStr;
  final bool isRead;
  final String audioName; // 🔥 NEW

  const AudioPlayerBubble({
    super.key,
    required this.url,
    required this.isMe,
    required this.themeColor,
    required this.timeStr,
    required this.isRead,
    required this.audioName, // 🔥 NEW
  });
  // ... rest of class remains identical until build:

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
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    _service.init();
    _service.checkDownloaded(widget.url);

    _subs.add(_service.playingStream.listen((playing) {
      if (mounted && _service.currentUrl == widget.url) {
        setState(() => _isPlaying = playing);
      }
    }));
    _subs.add(_service.loadingStream.listen((loading) {
      if (mounted && _service.currentUrl == widget.url) {
        setState(() => _isLoading = loading);
      }
    }));
    _subs.add(_service.durationStream.listen((d) {
      if (mounted && _service.currentUrl == widget.url) {
        setState(() {
          _duration = d;
          _isLoaded = true;
        });
      }
    }));
    _subs.add(_service.positionStream.listen((p) {
      if (mounted && _service.currentUrl == widget.url) {
        setState(() => _position = p);
      }
    }));
    _subs.add(_service.downloadedStream.listen((downloaded) {
      if (mounted) setState(() => _isDownloaded = downloaded);
    }));
    _subs.add(_service.urlStream.listen((url) {
      if (mounted && url != widget.url) {
        setState(() => _isPlaying = false);
      }
    }));
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
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isActive = _service.currentUrl == widget.url;
    final bool showPlaying = isActive ? _isPlaying : false;
    final bool canShowSlider = isActive && _isLoaded;

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
                    : Stack(
                        children: [
                          if (!_isDownloaded && widget.url.startsWith('http'))
                            SizedBox(
                              width: 38,
                              height: 38,
                              child: CircularProgressIndicator(
                                color: widget.isMe
                                    ? Colors.black38
                                    : widget.themeColor.withOpacity(0.4),
                                strokeWidth: 2,
                              ),
                            ),
                          Icon(
                            !_isDownloaded && widget.url.startsWith('http')
                                ? Icons.download_for_offline
                                : (showPlaying
                                    ? Icons.pause_circle_filled
                                    : Icons.play_circle_fill),
                            color: widget.isMe
                                ? Colors.black87
                                : widget.themeColor,
                            size: 38,
                          ),
                        ],
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: canShowSlider
                    ? SliderTheme(
                        data: SliderThemeData(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6),
                          overlayShape:
                              const RoundSliderOverlayShape(overlayRadius: 10),
                          activeTrackColor:
                              widget.isMe ? Colors.black87 : widget.themeColor,
                          inactiveTrackColor:
                              widget.isMe ? Colors.black26 : Colors.white24,
                          thumbColor:
                              widget.isMe ? Colors.black : widget.themeColor,
                        ),
                        child: Slider(
                          min: 0,
                          max: _duration.inMilliseconds.toDouble(),
                          value: _position.inMilliseconds
                              .toDouble()
                              .clamp(0.0, _duration.inMilliseconds.toDouble()),
                          onChanged: (val) {
                            _service.seek(Duration(milliseconds: val.toInt()));
                          },
                        ),
                      )
                    : SizedBox(
                        height: 20,
                        child: LinearProgressIndicator(
                          backgroundColor: widget.isMe
                              ? Colors.black.withOpacity(0.1)
                              : Colors.white10,
                          valueColor: AlwaysStoppedAnimation(
                            widget.isMe
                                ? Colors.black38
                                : widget.themeColor.withOpacity(0.4),
                          ),
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
                    canShowSlider
                        ? _formatDuration(_position)
                        : (_isLoaded
                            ? _formatDuration(_duration)
                            : widget.audioName), // 🔥 FIX: Shows proper name!
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

// =========================================================================
// OUR CALENDAR (For Individual Chats)
// =========================================================================
class OurCalendarSheet extends StatefulWidget {
  final String chatId;

  const OurCalendarSheet({
    super.key,
    required this.chatId,
  });

  @override
  State<OurCalendarSheet> createState() => _OurCalendarSheetState();
}

class _OurCalendarSheetState extends State<OurCalendarSheet> {
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

  void _markDayAsSeen(DateTime day) async {
    final eventsForDay = _getEventsForDay(day);
    final unseenEvents =
        eventsForDay.where((e) => _unseenEventIds.contains(e['id'])).toList();

    if (unseenEvents.isNotEmpty) {
      final myId = _supabase.auth.currentUser!.id;
      final inserts = unseenEvents
          .map((e) => {'event_id': e['id'], 'user_id': myId})
          .toList();

      setState(() {
        for (var e in unseenEvents) {
          _unseenEventIds.remove(e['id']);
        }
      });

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
            const Text("Our Calendar",
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
                            final bool canDelete = isCreator;

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
                                        if (canEdit)
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
                  Text(isEditing ? 'Edit Event' : 'Add Event',
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
                      if (!formKey.currentState!.validate()) return;

                      final day = isEditing
                          ? DateTime.parse(event['start_time']).toLocal()
                          : (_selectedDay ?? DateTime.now());
                      final startDateTime = DateTime(day.year, day.month,
                          day.day, startTime.hour, startTime.minute);
                      var endDateTime = DateTime(day.year, day.month, day.day,
                          endTime.hour, endTime.minute);
                      if (endDateTime.isBefore(startDateTime))
                        endDateTime = endDateTime.add(const Duration(days: 1));

                      String? finalImageUrl = existingImageUrl;

                      try {
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
                          // Save the event only — cron job will drop the banner at event time
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
                      } catch (e) {
                        debugPrint('Event save error: $e');
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Database error: ${e.toString()}'),
                              backgroundColor: Colors.redAccent,
                              duration: const Duration(seconds: 4),
                            ),
                          );
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
