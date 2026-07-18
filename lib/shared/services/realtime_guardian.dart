// lib/shared/services/realtime_guardian.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Keeps every already-open Supabase Realtime channel authorized as the
/// session JWT rotates. Root cause this exists for: nothing anywhere in
/// the app ever called `realtime.setAuth()` or handled
/// `AuthChangeEvent.tokenRefreshed` — confirmed by grepping the whole lib
/// folder. The websocket stays "connected" through a token expiry with no
/// visible error; the channel just quietly stops delivering events.
class RealtimeGuardian {
  RealtimeGuardian._();
  static final RealtimeGuardian instance = RealtimeGuardian._();

  StreamSubscription<AuthState>? _authSub;
  bool _initialized = false;

  void init() {
    if (_initialized) return;
    _initialized = true;

    final supabase = Supabase.instance.client;

    final currentToken = supabase.auth.currentSession?.accessToken;
    if (currentToken != null) {
      supabase.realtime.setAuth(currentToken);
    }

    _authSub = supabase.auth.onAuthStateChange.listen((state) {
      final token = state.session?.accessToken;
      if (token == null) return;

      if (state.event == AuthChangeEvent.tokenRefreshed ||
          state.event == AuthChangeEvent.signedIn ||
          state.event == AuthChangeEvent.initialSession) {
        supabase.realtime.setAuth(token);
        debugPrint(
            '🔐 RealtimeGuardian: refreshed realtime auth (${state.event})');
      }
    });
  }

  void dispose() {
    _authSub?.cancel();
    _authSub = null;
    _initialized = false;
  }
}
