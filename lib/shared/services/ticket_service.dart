// lib/shared/services/ticket_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';
import 'supabase_service.dart';

class TicketService {
  TicketService._();
  static final TicketService instance = TicketService._();

  final SupabaseClient _supabase = SupabaseService.instance.client;

  /// Creates a ticket row and returns the inserted record as a Map.
  /// Throws on error.
  Future<Map<String, dynamic>> createTicket({
    required int schoolId,
    required String name,
    String? description,
    required DateTime date, // pass a DateTime
    required String
        time, // pass time as a string matching your schema e.g. "03:28:00"
    required String location,
    required String organizers,
    required int ticketsRemaining,
    String? photoUrl,
  }) async {
    final user = _supabase.auth.currentUser;
    if (user == null) {
      throw Exception('User not authenticated');
    }

    final purchaserId = user.id; // UUID string from Supabase Auth

    // Format date to YYYY-MM-DD (adjust if your schema expects a different format)
    final String dateStr = date.toIso8601String().split('T').first;

    final insertData = {
      'school_id': schoolId,
      'name': name,
      'description': description ?? '',
      'date': dateStr,
      'time': time,
      'location': location,
      'organizers': organizers,
      'tickets_remaining': ticketsRemaining,
      'photo_url': photoUrl,
      'purchaser_id': purchaserId,
      'created_at': DateTime.now().toUtc().toIso8601String(),
    };

    final response = await _supabase
        .from('tickets')
        .insert(insertData)
        .select()
        .maybeSingle(); // use single() if you always expect a row

    if (response == null) {
      throw Exception('Insert returned null');
    }

    // response is Map<String,dynamic>
    return response as Map<String, dynamic>;
  }

  /// (Optional) helper to decrement tickets_remaining atomically after purchase.
  /// Returns the updated ticket row (or null if not found).
  Future<Map<String, dynamic>?> decrementTicketsRemaining({
    required int ticketId,
    required int decrementBy,
  }) async {
    final res = await _supabase.rpc('decrement_tickets_remaining', params: {
      'p_ticket_id': ticketId,
      'p_decrement_by': decrementBy,
    }).maybeSingle();

    // NOTE: The RPC must exist in your DB. If you don't have it, remove this helper.
    if (res == null) return null;
    return res as Map<String, dynamic>;
  }
}
