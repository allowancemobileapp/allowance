// lib/services/chat_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';

class ChatService {
  final _supabase = Supabase.instance.client;

  // Get or Create Chat ID for 1-on-1
  Future<String> getChatId(String otherUserId) async {
    final response = await _supabase.rpc(
      'get_or_create_personal_chat',
      params: {
        'user_a': _supabase.auth.currentUser!.id,
        'user_b': otherUserId,
      },
    );
    return response.toString();
  }

  // Send Message
  Future<void> sendMessage(String chatId, String content) async {
    await _supabase.from('messages').insert({
      'chat_id': chatId,
      'sender_id': _supabase.auth.currentUser!.id,
      'content': content,
    });
  }

  // Real-time Stream
  Stream<List<Map<String, dynamic>>> getMessagesStream(String chatId) {
    return _supabase
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('chat_id', chatId)
        .order('created_at', ascending: false);
  }
}
