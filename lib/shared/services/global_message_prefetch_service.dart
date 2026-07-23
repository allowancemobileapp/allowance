import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'chat_local_db.dart';

class GlobalMessagePrefetchService {
  GlobalMessagePrefetchService._();
  static final GlobalMessagePrefetchService instance =
      GlobalMessagePrefetchService._();

  Timer? _pollTimer;
  Timer? _chatIdRefreshTimer;
  StreamSubscription? _liveSub;
  Set<String> _myChatIds = {};
  DateTime _lastSyncedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    await _refreshChatIds();
    await _sync();

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => _sync());

    _chatIdRefreshTimer?.cancel();
    _chatIdRefreshTimer =
        Timer.periodic(const Duration(seconds: 30), (_) async {
      final before = _myChatIds;
      await _refreshChatIds();
      if (!setEquals(before, _myChatIds))
        _tryStartLiveLayer(); // picks up newly-joined groups
    });

    _tryStartLiveLayer();
  }

  Future<void> _refreshChatIds() async {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    if (myId == null) return;
    try {
      final parts = await Supabase.instance.client
          .from('chat_participants')
          .select('chat_id')
          .eq('user_id', myId);
      _myChatIds = (parts as List).map((p) => p['chat_id'].toString()).toSet();
    } catch (e) {
      debugPrint('Prefetch chat-id refresh error: $e');
    }
  }

  Future<void> _sync() async {
    if (_myChatIds.isEmpty) {
      await _refreshChatIds();
      if (_myChatIds.isEmpty) return;
    }
    try {
      final resp = await Supabase.instance.client
          .from('messages')
          .select()
          .inFilter('chat_id', _myChatIds.toList())
          .gt('created_at', _lastSyncedAt.toUtc().toIso8601String())
          .order('created_at', ascending: true)
          .limit(200);

      final rows = List<Map<String, dynamic>>.from(resp);
      if (rows.isEmpty) return;

      final byChatId = <String, List<Map<String, dynamic>>>{};
      for (final row in rows) {
        final chatId = row['chat_id']?.toString();
        if (chatId == null) continue;
        byChatId.putIfAbsent(chatId, () => []).add(row);
      }
      for (final entry in byChatId.entries) {
        await ChatLocalDB.instance.cacheMessages(entry.key, entry.value);
      }
      _lastSyncedAt = DateTime.now().toUtc();
    } catch (e) {
      debugPrint('Prefetch sync error: $e');
    }
  }

  void _tryStartLiveLayer() {
    try {
      _liveSub?.cancel();
      _liveSub = Supabase.instance.client
          .from('messages')
          .stream(primaryKey: ['id'])
          .inFilter('chat_id', _myChatIds.toList())
          .order('created_at', ascending: false)
          .limit(200)
          .listen((rows) async {
            final byChatId = <String, List<Map<String, dynamic>>>{};
            for (final row in rows) {
              final chatId = row['chat_id']?.toString();
              if (chatId == null || !_myChatIds.contains(chatId)) continue;
              byChatId.putIfAbsent(chatId, () => []).add(row);
            }
            for (final entry in byChatId.entries) {
              await ChatLocalDB.instance.cacheMessages(entry.key, entry.value);
            }
          },
              onError: (e) =>
                  debugPrint('Live layer error (poll still covers this): $e'));
    } catch (e) {
      debugPrint('Live layer unavailable, relying on poll only: $e');
    }
  }

  void dispose() {
    _pollTimer?.cancel();
    _chatIdRefreshTimer?.cancel();
    _liveSub?.cancel();
    _initialized = false;
  }
}
