// lib/shared/services/fcm_service.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:developer' as developer;

/// Top-level background handler (required by Firebase)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  developer.log('Background message: ${message.messageId}', name: 'fcm');
}

/// Mobile (Android/iOS) — get token + save to profiles
Future<void> initFcmAndSaveToken() async {
  if (kIsWeb) return;

  try {
    await Firebase.initializeApp();

    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    final messaging = FirebaseMessaging.instance;

    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      carPlay: false,
      criticalAlert: false,
      provisional: false,
    );

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      developer.log('User denied notification permission');
      return;
    }

    final token = await messaging.getToken();

    if (token == null) return;

    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user != null) {
      await supabase
          .from('profiles')
          .update({'fcm_token': token}).eq('id', user.id);
      developer.log('Mobile FCM token saved');
    }

    // Auto-update on token refresh
    messaging.onTokenRefresh.listen((newToken) async {
      if (supabase.auth.currentUser != null) {
        await supabase.from('profiles').update({'fcm_token': newToken}).eq(
            'id', supabase.auth.currentUser!.id);
      }
    });
  } catch (e) {
    developer.log('initFcmAndSave error: $e');
  }
}

/// Web — get token + save to profiles
Future<void> requestWebPushPermissionAndSaveToken() async {
  if (!kIsWeb) return;

  try {
    final messaging = FirebaseMessaging.instance;

    final settings = await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
      developer.log('Web push permission denied');
      return;
    }

    final token = await messaging.getToken(
      vapidKey:
          "BOMEfy6tL0GjcSnjfjTB-Jzk9UXCn8u0_1D2lcISqkzpktaq3cpq0eRA-wHaNSBicK5xdOsMyt2PjNamcbEv6Co",
    );

    if (token == null) {
      developer.log('No web FCM token received');
      return;
    }

    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user != null) {
      await supabase
          .from('profiles')
          .update({'fcm_token': token}).eq('id', user.id);
      developer.log('WEB FCM TOKEN SAVED SUCCESSFULLY: $token');
    }

    // Listen for token refresh on web too
    messaging.onTokenRefresh.listen((newToken) async {
      if (supabase.auth.currentUser != null) {
        await supabase.from('profiles').update({'fcm_token': newToken}).eq(
            'id', supabase.auth.currentUser!.id);
      }
    });
  } catch (e) {
    developer.log('Web FCM error: $e');
  }
}

/// Register foreground + tap listeners (Android/iOS/Web)
void registerFcmListeners(BuildContext context) {
  // Foreground message (show snackbar)
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    final title = message.notification?.title ?? '';
    final body = message.notification?.body ?? '';

    if (title.isNotEmpty || body.isNotEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            '$title\n$body',
            style: const TextStyle(
              color: Colors.white, // ← WHITE TEXT (fixed)
              fontSize: 16,
            ),
          ),
          duration: const Duration(seconds: 5),
          backgroundColor: Colors.black87,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  });

  // When app is in background and user taps notification
  FirebaseMessaging.onMessageOpenedApp.listen((message) {
    _handleNavigation(context, message.data);
  });

  // When app is terminated and opened via notification
  FirebaseMessaging.instance.getInitialMessage().then((message) {
    if (message != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleNavigation(context, message.data);
      });
    }
  });
}

void _handleNavigation(BuildContext context, Map<String, dynamic> data) {
  final type = data['type']?.toString().toLowerCase();

  if (type == 'gist') {
    final gistId = data['gist_id'] ?? data['id'];
    if (gistId != null) {
      Navigator.pushNamed(context, '/gist',
          arguments: {'id': gistId.toString()});
    }
  } else if (type == 'ticket') {
    final ticketId = data['ticket_id'] ?? data['id'];
    if (ticketId != null) {
      Navigator.pushNamed(context, '/ticket',
          arguments: {'id': ticketId.toString()});
    }
  }
}
