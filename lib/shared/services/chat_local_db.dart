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
    if (kIsWeb) return null; // Web doesn't support SQLite
    if (_database != null) return _database!;
    _database = await _initDB('allowance_chats_v2.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, filePath);

    return await openDatabase(
      path,
      version: 1,
      onCreate: _createDB,
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
        created_at TEXT NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_chat_id ON messages (chat_id)');
  }

  // --- HYBRID CACHE METHOD ---
  Future<void> cacheMessages(
      String chatId, List<Map<String, dynamic>> messages) async {
    if (messages.isEmpty) return;

    if (kIsWeb) {
      // WEB FALLBACK: Safe and simple
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('web_chat_$chatId', jsonEncode(messages));
      return;
    }

    // MOBILE BASTARD SPEED: Native SQLite batch processing (Off main UI thread)
    final db = await instance.database;
    if (db == null) return;

    final batch = db.batch();
    for (var msg in messages) {
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
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  // --- HYBRID LOAD METHOD ---
  Future<List<Map<String, dynamic>>> getMessagesForChat(String chatId,
      {int limit = 100}) async {
    if (kIsWeb) {
      // WEB FALLBACK
      final prefs = await SharedPreferences.getInstance();
      final str = prefs.getString('web_chat_$chatId');
      if (str != null) {
        try {
          return List<Map<String, dynamic>>.from(jsonDecode(str).take(limit));
        } catch (_) {}
      }
      return [];
    }

    // MOBILE BASTARD SPEED: Instant native query
    final db = await instance.database;
    if (db == null) return [];

    final result = await db.query(
      'messages',
      where: 'chat_id = ?',
      whereArgs: [chatId],
      orderBy: 'created_at DESC',
      limit: limit,
    );

    return result.map((msg) {
      final mutableMsg = Map<String, dynamic>.from(msg);
      mutableMsg['is_read'] =
          mutableMsg['is_read'] == 1; // Convert SQL 1/0 to bool
      return mutableMsg;
    }).toList();
  }
}
