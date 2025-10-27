// lib/shared/services/supabase_service.dart
import 'package:supabase_flutter/supabase_flutter.dart';

/// Central access to the initialized Supabase client.
/// After Supabase.initialize(...) in main.dart, use:
/// final supabase = SupabaseService.instance.client;
class SupabaseService {
  SupabaseService._();

  static final SupabaseService instance = SupabaseService._();

  SupabaseClient get client => Supabase.instance.client;

  /// Convenience getter for auth
  GoTrueClient get auth => client.auth;

  /// Current user id (null if not logged in)
  String? get userId => auth.currentUser?.id;

  /// Sign out convenience
  Future<void> signOut() async {
    await auth.signOut();
  }
}
