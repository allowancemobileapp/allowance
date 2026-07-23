// lib/shared/services/chat_sync_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:wechat_camera_picker/wechat_camera_picker.dart';

class ChatSyncService {
  static final ChatSyncService instance = ChatSyncService._internal();
  ChatSyncService._internal() {
    _loadPending();
  }

  final ValueNotifier<List<Map<String, dynamic>>> pendingMessages =
      ValueNotifier([]);
  final ValueNotifier<Map<String, double?>> uploadProgress = ValueNotifier({});
  final Map<String, Timer> _simulatedTimers = {}; // <--- The Timer Engine
  final Set<String> _processingIds = {}; // ← Prevents duplicate processing
  final Set<String> _sentLocalIds = {}; // ← Tracks successfully sent messages
  final Map<String, Timer> _confirmationSweepTimers = {};

  Future<void> _loadPending() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('pending_chat_msgs');
    if (stored != null) {
      final loaded = List<Map<String, dynamic>>.from(jsonDecode(stored));
      // Only keep messages that haven't been sent yet
      final unsent = loaded.where((m) {
        final wasSent = m['is_pending'] == false && m['is_failed'] != true;
        if (wasSent) _sentLocalIds.add(m['local_id'] as String);
        return !wasSent;
      }).toList();

      pendingMessages.value = unsent;

      // Only retry failed ones, not pending ones (they might be in-flight)
      for (var msg in unsent) {
        if (msg['is_failed'] == true) {
          _processQueueItem(msg);
        }
      }
    }
  }

  Future<void> _savePending() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'pending_chat_msgs', jsonEncode(pendingMessages.value));
  }

  void enqueueMessage(Map<String, dynamic> message,
      {List<String>? localPaths}) {
    final localId =
        '${DateTime.now().millisecondsSinceEpoch}_${message.hashCode}';

    // Guard: Never enqueue a duplicate
    if (_sentLocalIds.contains(localId) ||
        pendingMessages.value.any((m) => m['local_id'] == localId)) {
      return;
    }

    final msg = {
      ...message,
      'local_id': localId,
      'is_pending': true,
      'is_failed': false,
      'local_paths': localPaths ?? [],
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };

    pendingMessages.value = [msg, ...pendingMessages.value];
    _savePending();

    // 🚀 Instant chat list bump
    _optimisticallyBumpChat(msg);

    _processQueueItem(msg);
  }

  Future<void> _optimisticallyBumpChat(Map<String, dynamic> msg) async {
    final preview = (msg['content'] ?? '').toString().trim();
    try {
      await Supabase.instance.client.from('chats').update({
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'last_message': preview.isEmpty ? 'Media' : preview,
      }).eq('id', msg['chat_id']);
    } catch (_) {}
  }

  void retryMessage(String localId) {
    // Don't retry if already being processed
    if (_processingIds.contains(localId)) return;

    final msgs = List<Map<String, dynamic>>.from(pendingMessages.value);
    final index = msgs.indexWhere((m) => m['local_id'] == localId);
    if (index != -1) {
      msgs[index]['is_failed'] = false;
      msgs[index]['is_pending'] = true;
      pendingMessages.value = msgs;
      _savePending();
      _processQueueItem(msgs[index]);
    }
  }

  void cancelMessage(String localId) {
    _simulatedTimers[localId]?.cancel();
    uploadProgress.value = Map.from(uploadProgress.value)..remove(localId);
    pendingMessages.value =
        pendingMessages.value.where((m) => m['local_id'] != localId).toList();
    _savePending();
  }

  // --- 🚀 THE PROGRESS SIMULATOR ---
  void _simulateProgress(String localId) {
    double progress = 0.01;
    uploadProgress.value = Map.from(uploadProgress.value)..[localId] = progress;

    _simulatedTimers[localId] =
        Timer.periodic(const Duration(milliseconds: 250), (timer) {
      if (progress < 0.95) {
        // Logarithmic climb: Moves fast early, then crawls, looking very realistic!
        progress += (0.98 - progress) * 0.15;
        uploadProgress.value = Map.from(uploadProgress.value)
          ..[localId] = progress;
      }
    });
  }

  void _removeFromPending(String localId) {
    _simulatedTimers[localId]?.cancel();
    _simulatedTimers.remove(localId);
    _confirmationSweepTimers[localId]?.cancel(); // 🔥 NEW
    _confirmationSweepTimers.remove(localId); // 🔥 NEW
    uploadProgress.value = Map.from(uploadProgress.value)..remove(localId);

    pendingMessages.value =
        pendingMessages.value.where((m) => m['local_id'] != localId).toList();
    _savePending();
  }

  Future<void> _processQueueItem(Map<String, dynamic> msg) async {
    final localId = msg['local_id'] as String;

    // 🔒 CRITICAL: Prevent duplicate processing of same message
    if (_processingIds.contains(localId)) return;
    if (_sentLocalIds.contains(localId)) {
      // Already sent successfully, clean from pending
      _removeFromPending(localId);
      return;
    }

    _processingIds.add(localId);

    final supabase = Supabase.instance.client;

    try {
      List<String> uploadedUrls = [];
      List<String> localPaths = List<String>.from(msg['local_paths'] ?? []);

      if (localPaths.isNotEmpty) {
        _simulateProgress(localId);

        for (String path in localPaths) {
          String fileName;
          String storagePath;

          if (kIsWeb) {
            Uint8List fileBytes;
            if (path.startsWith('blob:')) {
              final xfile = XFile(path);
              fileBytes = await xfile.readAsBytes();
            } else {
              final response = await http.get(Uri.parse(path));
              fileBytes = response.bodyBytes;
            }
            final String mType = msg['media_type']?.toString() ?? 'image';
            final ext = (mType == 'video' || mType == 'view_once_video')
                ? 'mp4'
                : (mType == 'sticker' ? 'png' : 'jpg');
            fileName =
                '${DateTime.now().millisecondsSinceEpoch}_${path.hashCode}.$ext';
            storagePath = 'chat_media/${msg['chat_id']}/$fileName';
            await supabase.storage
                .from('chat_media')
                .uploadBinary(storagePath, fileBytes);
          } else {
            // 🔥 THE CRASH FIX: was readAsBytes() + uploadBinary() — buffers
            // the whole file in memory first. Now streams the File
            // straight to .upload(), same as your own working code paths
            // already do two methods away from this one.
            final file = File(path);
            if (!file.existsSync()) continue;

            final int sizeBytes = await file.length();
            const int maxUploadBytes = 300 * 1024 * 1024;
            if (sizeBytes > maxUploadBytes) {
              throw Exception(
                  'File too large to send (${(sizeBytes / (1024 * 1024)).toStringAsFixed(0)}MB) — trim it first.');
            }

            final ext =
                path.split('.').last.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
            fileName =
                '${DateTime.now().millisecondsSinceEpoch}_${file.hashCode}.$ext';
            storagePath = 'chat_media/${msg['chat_id']}/$fileName';
            await supabase.storage.from('chat_media').upload(storagePath, file);
          }

          uploadedUrls.add(
              supabase.storage.from('chat_media').getPublicUrl(storagePath));
        }

        if (msg['local_thumb_path'] != null && !kIsWeb) {
          final thumbFile = File(msg['local_thumb_path']);
          if (thumbFile.existsSync()) {
            final thumbName =
                'thumb_${DateTime.now().millisecondsSinceEpoch}.jpg';
            final thumbPath = 'chat_media/${msg['chat_id']}/$thumbName';
            await supabase.storage
                .from('chat_media')
                .upload(thumbPath, thumbFile);
            msg['thumbnail_url'] =
                supabase.storage.from('chat_media').getPublicUrl(thumbPath);
          }
        }

        _simulatedTimers[localId]?.cancel();
        _simulatedTimers.remove(localId);
        uploadProgress.value = Map.from(uploadProgress.value)..[localId] = 1.0;
      }

      // Sanitize reply_to_id
      String? replyToId = msg['reply_to_id']?.toString();
      final String? replyContent = msg['reply_content']?.toString();
      final bool isSyntheticReply = replyToId != null &&
          (replyToId.startsWith('event_') ||
              replyToId.startsWith('story_') ||
              (replyContent?.startsWith('Story_') ?? false) ||
              (replyContent?.startsWith('Event_') ?? false));
      if (isSyntheticReply) replyToId = null;

      final payload = {
        'chat_id': msg['chat_id'],
        'sender_id': msg['sender_id'],
        'content': msg['content'],
        'is_read': false,
        'local_id': localId,
        if (uploadedUrls.isNotEmpty || msg['media_url'] != null)
          'media_url': uploadedUrls.isNotEmpty
              ? uploadedUrls.join(',')
              : msg['media_url'],
        if (msg['media_type'] != null) 'media_type': msg['media_type'],
        if (msg['thumbnail_url'] != null) 'thumbnail_url': msg['thumbnail_url'],
        if (msg['file_size_bytes'] != null)
          'file_size_bytes': msg['file_size_bytes'],
        if (msg['poll_options'] != null) 'poll_options': msg['poll_options'],
        if (msg['poll_allow_multiple'] != null)
          'poll_allow_multiple': msg['poll_allow_multiple'],
        if (replyToId != null) 'reply_to_id': replyToId,
        if (replyContent != null && replyContent.isNotEmpty)
          'reply_content': replyContent,
      };

      await supabase.from('messages').insert(payload);

      // 🔥 THE FLICKER FIX: previously this called _removeFromPending(localId)
      // right here — the instant the REST insert acknowledged. But the
      // matching row landing in _messages happens via a SEPARATE, slightly
      // later realtime broadcast. For that gap the message existed in
      // neither list — just-removed from pending, not-yet-arrived as
      // confirmed — so it visibly vanished, then popped back once the
      // event landed. Worse gap on bad networks = longer vanish, exactly
      // what you saw.
      //
      // Fix: mark it sent, leave it in pendingMessages. Each chat screen's
      // _computeCombinedMessages already drops any pending entry whose
      // local_id has a confirmed twin in _messages — so the instant the
      // real row arrives, the duplicate disappears with nothing ever
      // having been absent. The sweep timer below is just later cleanup
      // for local storage, not what drives visibility.
      _sentLocalIds.add(localId);

      final msgs = List<Map<String, dynamic>>.from(pendingMessages.value);
      final idx = msgs.indexWhere((m) => m['local_id'] == localId);
      if (idx != -1) {
        msgs[idx] = {...msgs[idx], 'is_pending': false, 'is_failed': false};
        pendingMessages.value = msgs;
        _savePending();
      }

      _confirmationSweepTimers[localId]?.cancel();
      _confirmationSweepTimers[localId] =
          Timer(const Duration(seconds: 8), () => _removeFromPending(localId));

      final preview = (msg['content'] ?? '').toString().trim();
      await supabase.from('chats').update({
        'updated_at': DateTime.now().toUtc().toIso8601String(),
        'last_message': preview.isEmpty ? 'Media' : preview,
      }).eq('id', msg['chat_id']);
    } catch (e) {
      debugPrint("Message send failed: $e");

      _simulatedTimers[localId]?.cancel();
      _simulatedTimers.remove(localId);
      uploadProgress.value = Map.from(uploadProgress.value)..remove(localId);

      // Mark as failed but keep in pending for retry
      final msgs = List<Map<String, dynamic>>.from(pendingMessages.value);
      final index = msgs.indexWhere((m) => m['local_id'] == localId);
      if (index != -1) {
        msgs[index]['is_failed'] = true;
        msgs[index]['is_pending'] = false;
        pendingMessages.value = msgs;
        _savePending();
      }
    } finally {
      _processingIds.remove(localId);
    }
  }
}
