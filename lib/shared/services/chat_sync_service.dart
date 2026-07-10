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

  Future<void> _loadPending() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString('pending_chat_msgs');
    if (stored != null) {
      pendingMessages.value =
          List<Map<String, dynamic>>.from(jsonDecode(stored));
      for (var msg in pendingMessages.value) {
        if (msg['is_failed'] != true) _processQueueItem(msg);
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
    _processQueueItem(msg);
  }

  void retryMessage(String localId) {
    final msgs = List<Map<String, dynamic>>.from(pendingMessages.value);
    final index = msgs.indexWhere((m) => m['local_id'] == localId);
    if (index != -1) {
      msgs[index]['is_failed'] = false;
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

  Future<void> _processQueueItem(Map<String, dynamic> msg) async {
    final localId = msg['local_id'];
    final supabase = Supabase.instance.client;

    try {
      List<String> uploadedUrls = [];
      List<String> localPaths = List<String>.from(msg['local_paths'] ?? []);

      if (localPaths.isNotEmpty) {
        _simulateProgress(localId);

        for (String path in localPaths) {
          Uint8List fileBytes;
          String fileName;

          // 🔥 FIX 1: Safely extract the media type
          final String mType = msg['media_type']?.toString() ?? 'image';

          if (kIsWeb) {
            if (path.startsWith('blob:')) {
              final xfile = XFile(path);
              fileBytes = await xfile.readAsBytes();
            } else {
              final response = await http.get(Uri.parse(path));
              fileBytes = response.bodyBytes;
            }

            // 🔥 FIX 2: Correctly identifies View Once videos so they don't get saved as JPGs!
            final ext = (mType == 'video' || mType == 'view_once_video')
                ? 'mp4'
                : (mType == 'sticker' ? 'png' : 'jpg');

            fileName =
                '${DateTime.now().millisecondsSinceEpoch}_${path.hashCode}.$ext';
          } else {
            final file = File(path);
            if (!file.existsSync()) continue;
            fileBytes = await file.readAsBytes();
            final ext =
                path.split('.').last.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '');
            fileName =
                '${DateTime.now().millisecondsSinceEpoch}_${file.hashCode}.$ext';
          }

          final storagePath = 'chat_media/${msg['chat_id']}/$fileName';

          await supabase.storage
              .from('chat_media')
              .uploadBinary(storagePath, fileBytes);
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
        uploadProgress.value = Map.from(uploadProgress.value)..[localId] = 1.0;
      }

      // 🔥 FIXED: Preserves the 'media_url' if we sent a pre-saved sticker
      final payload = {
        'chat_id': msg['chat_id'],
        'sender_id': msg['sender_id'],
        'content': msg['content'],
        'is_read': false,
        if (uploadedUrls.isNotEmpty || msg['media_url'] != null)
          'media_url': uploadedUrls.isNotEmpty
              ? uploadedUrls.join(',')
              : msg['media_url'],
        if (msg['media_type'] != null) 'media_type': msg['media_type'],
        if (msg['thumbnail_url'] != null) 'thumbnail_url': msg['thumbnail_url'],
        if (msg['file_size_bytes'] != null)
          'file_size_bytes': msg['file_size_bytes'],
        if (msg['reply_to_id'] != null) 'reply_to_id': msg['reply_to_id'],
        if (msg['reply_content'] != null) 'reply_content': msg['reply_content'],
      };

      await supabase.from('messages').insert(payload);

      final msgs = List<Map<String, dynamic>>.from(pendingMessages.value);
      final idx = msgs.indexWhere((m) => m['local_id'] == localId);
      if (idx != -1) {
        msgs[idx]['is_pending'] = false;
        pendingMessages.value = msgs;
        _savePending();
      }

      Future.delayed(const Duration(seconds: 15), () => cancelMessage(localId));

      try {
        await supabase.from('chats').update({
          'updated_at': DateTime.now().toUtc().toIso8601String(),
          'last_message': msg['content'].toString().trim().isEmpty
              ? 'Media'
              : msg['content'],
        }).eq('id', msg['chat_id']);
      } catch (_) {}
    } catch (e) {
      _simulatedTimers[localId]?.cancel();
      final msgs = List<Map<String, dynamic>>.from(pendingMessages.value);
      final index = msgs.indexWhere((m) => m['local_id'] == localId);
      if (index != -1) {
        msgs[index]['is_failed'] = true;
        pendingMessages.value = msgs;
        _savePending();
      }
    }
  }
}
