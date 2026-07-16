// lib/shared/services/fcm_service.dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // <-- Needed for Sound & Haptics
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:developer' as developer;

// --- GLOBAL CHAT TRACKER ---
String? activeChatId;

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  developer.log('Background message: ${message.messageId}', name: 'fcm');
}

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
    );

    if (settings.authorizationStatus == AuthorizationStatus.denied) {
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
    }

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
      return;
    }

    final token = await messaging.getToken(
      vapidKey:
          "BOMEfy6tL0GjcSnjfjTB-Jzk9UXCn8u0_1D2lcISqkzpktaq3cpq0eRA-wHaNSBicK5xdOsMyt2PjNamcbEv6Co",
    );

    if (token == null) return;

    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user != null) {
      await supabase
          .from('profiles')
          .update({'fcm_token': token}).eq('id', user.id);
    }

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

void registerFcmListeners(BuildContext context) {
  // Foreground message
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    final title = message.notification?.title ?? '';
    final body = message.notification?.body ?? '';
    final data = message.data;
    final type = data['type']?.toString().toLowerCase();
    final chatId = data['chat_id']?.toString();

    if (title.isNotEmpty || body.isNotEmpty) {
      // --- FIX: WHATSAPP STYLE SILENCER ---
      if (type == 'chat' && chatId != null && chatId == activeChatId) {
        // We are currently in this chat! Do NOT show visual popup.
        HapticFeedback.lightImpact();
        SystemSound.play(SystemSoundType.click); // Play a subtle sound
        return;
      }

      // Show Custom Top Drop-down Notification
      _showTopNotification(context, title, body, data);
    }
  });

  FirebaseMessaging.onMessageOpenedApp.listen((message) {
    _handleNavigation(context, message.data);
  });

  FirebaseMessaging.instance.getInitialMessage().then((message) {
    if (message != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleNavigation(context, message.data);
      });
    }
  });
}

// --- FIX: CUSTOM TOP NOTIFICATION BANNER ---
void _showTopNotification(BuildContext context, String title, String body,
    Map<String, dynamic> data) {
  final overlay = Overlay.of(context);
  late OverlayEntry entry;

  entry = OverlayEntry(
    builder: (context) => Positioned(
      top: MediaQuery.paddingOf(context).top +
          10, // Drops right below the phone notch
      left: 16,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: GestureDetector(
          onTap: () {
            entry.remove();
            _handleNavigation(context, data);
          },
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(
                    color: Colors.black45, blurRadius: 10, spreadRadius: 2)
              ],
              border: Border.all(color: const Color(0xFF4CAF50), width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                const SizedBox(height: 4),
                Text(body,
                    style: const TextStyle(color: Colors.white70, fontSize: 14),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  overlay.insert(entry);

  // Auto-dismiss after 4 seconds
  Future.delayed(const Duration(seconds: 4), () {
    if (entry.mounted) entry.remove();
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
