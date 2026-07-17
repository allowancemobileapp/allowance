// lib/shared/services/chat_local_db.dart
import 'dart:convert';
import 'package:flutter/foundation.dart'; // Gives us kIsWeb
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class ChatLocalDB {
  static final ChatLocalDB instance = ChatLocalDB._init();
  static Database? _database;

  ChatLocalDB._init();

  // --- SAFE DATABASE INITIALIZATION ---
  Future<Database?> get database async {
    if (kIsWeb) return null;
    if (_database != null) return _database!;
    _database = await _initDB('allowance_chats_v2.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 2, // 🔥 bumped from 1
      onCreate: _createDB,
      onUpgrade: _upgradeDB,
    );
  }

  Future<void> _createDB(Database db, int version) async {
    await db.execute('''
    CREATE TABLE messages (
      id TEXT PRIMARY KEY,
      chat_id TEXT NOT NULL,
      sender_id TEXT NOT NULL,
      content TEXT,
      media_url TEXT,
      media_type TEXT,
      thumbnail_url TEXT,
      file_size_bytes INTEGER,
      is_read INTEGER NOT NULL,
      reply_to_id TEXT,
      reply_content TEXT,
      created_at TEXT NOT NULL,
      event_id INTEGER,
      poll_options TEXT,
      poll_allow_multiple INTEGER
    )
  ''');
    await db.execute('CREATE INDEX idx_chat_id ON messages (chat_id)');
    await db.execute(
        'CREATE INDEX idx_chat_media_type ON messages (chat_id, media_type)');
  }

  Future<void> _upgradeDB(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE messages ADD COLUMN event_id INTEGER');
      await db.execute('ALTER TABLE messages ADD COLUMN poll_options TEXT');
      await db.execute(
          'ALTER TABLE messages ADD COLUMN poll_allow_multiple INTEGER');
      await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_chat_media_type ON messages (chat_id, media_type)');
    }
  }

  // --- HYBRID CACHE METHOD ---
  Future<void> cacheMessages(
      String chatId, List<Map<String, dynamic>> messages) async {
    if (messages.isEmpty) return;

    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('web_chat_$chatId', jsonEncode(messages));
      return;
    }

    final db = await instance.database;
    if (db == null) return;

    final batch = db.batch();
    for (var msg in messages) {
      // 🔥 poll_options is a List in memory, SQLite only stores primitives —
      // JSON-encode going in, decode coming back out in _decodeRow.
      final rawPollOptions = msg['poll_options'];
      String? pollOptionsJson;
      if (rawPollOptions != null) {
        try {
          pollOptionsJson = rawPollOptions is String
              ? rawPollOptions
              : jsonEncode(rawPollOptions);
        } catch (_) {
          pollOptionsJson = null;
        }
      }

      int? eventId;
      final rawEventId = msg['event_id'];
      if (rawEventId is int) {
        eventId = rawEventId;
      } else if (rawEventId != null) {
        eventId = int.tryParse(rawEventId.toString());
      }

      batch.insert(
        'messages',
        {
          'id': msg['id'].toString(),
          'chat_id': msg['chat_id'].toString(),
          'sender_id': msg['sender_id'].toString(),
          'content': msg['content']?.toString() ?? '',
          'media_url': msg['media_url']?.toString(),
          'media_type': msg['media_type']?.toString(),
          'thumbnail_url': msg['thumbnail_url']?.toString(),
          'file_size_bytes': msg['file_size_bytes'],
          'is_read': msg['is_read'] == true ? 1 : 0,
          'reply_to_id': msg['reply_to_id']?.toString(),
          'reply_content': msg['reply_content']?.toString(),
          'created_at': msg['created_at'].toString(),
          'event_id': eventId,
          'poll_options': pollOptionsJson,
          'poll_allow_multiple': msg['poll_allow_multiple'] == true ? 1 : 0,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

// Shared decode helper — used by both getMessagesForChat and
// getPinnedMessagesForChat so the poll/event field reconstruction lives
// in exactly one place.
  Map<String, dynamic> _decodeRow(Map<String, dynamic> msg) {
    final mutableMsg = Map<String, dynamic>.from(msg);
    mutableMsg['is_read'] = mutableMsg['is_read'] == 1;
    if (mutableMsg['poll_allow_multiple'] != null) {
      mutableMsg['poll_allow_multiple'] =
          mutableMsg['poll_allow_multiple'] == 1;
    }
    final pollOptionsRaw = mutableMsg['poll_options'];
    if (pollOptionsRaw is String && pollOptionsRaw.isNotEmpty) {
      try {
        mutableMsg['poll_options'] = jsonDecode(pollOptionsRaw);
      } catch (_) {
        // leave as-is; _buildPollBubble's parser already has a fallback
        // path for non-JSON poll_options strings
      }
    }
    return mutableMsg;
  }

// --- HYBRID LOAD METHOD ---
  Future<List<Map<String, dynamic>>> getMessagesForChat(String chatId,
      {int limit = 100}) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString('web_chat_$chatId');
      if (str != null) {
        try {
          return List<Map<String, dynamic>>.from(jsonDecode(str).take(limit));
        } catch (_) {}
      }
      return [];
    }

    final db = await instance.database;
    if (db == null) return [];

    final result = await db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'created_at DESC',
      limit: limit,
    );

    return result.map(_decodeRow).toList();
  }

// 🔥 NEW: polls and events, unbounded — never subject to the 50-row cap
// the scrolling cache uses, so they never silently evict.
  Future<List<Map<String, dynamic>>> getPinnedMessagesForChat(
      String chatId) async {
    if (kIsWeb) {
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString('web_chat_$chatId');
      if (str != null) {
        try {
          final all = List<Map<String, dynamic>>.from(jsonDecode(str));
          return all.where((m) {
            final t = m['media_type']?.toString();
            return t == 'poll' || t == 'event';
          }).toList();
        } catch (_) {}
      }
      return [];
    }

    final db = await instance.database;
    if (db == null) return [];

    final result = await db.query(
      'messages',
      where: 'chat_id = ? AND media_type IN (?, ?)',
      whereArgs: [chatId, 'poll', 'event'],
      orderBy: 'created_at DESC',
    );

    return result.map(_decodeRow).toList();
  }
}
