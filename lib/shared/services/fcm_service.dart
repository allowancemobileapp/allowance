// lib/shared/services/fcm_service.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dart:developer' as developer;

/// Top-level background handler required by firebase_messaging.
/// Keep it as a top-level function (not inside a class).
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  // make sure Firebase is initialized
  try {
    await Firebase.initializeApp();
  } catch (_) {}
  developer.log('Background message received: ${message.messageId}',
      name: 'fcm');
  // No UI work here. Optionally store data to DB/analytics via Edge Function.
}

/// Initialize FCM, request permissions, save token to profiles, and listen for token refresh.
/// Call this once after the user is signed in (or at app start if user already signed in).
Future<void> initFcmAndSaveToken() async {
  try {
    // Ensure Firebase initialized (safe to call multiple times)
    await Firebase.initializeApp();
  } catch (e) {
    developer.log('Firebase.initializeApp() error: $e', name: 'fcm');
  }

  // Register background handler
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

  final messaging = FirebaseMessaging.instance;

  // Request permission (iOS) - Android will just return granted
  final settings = await messaging.requestPermission(
    alert: true,
    announcement: false,
    badge: true,
    carPlay: false,
    criticalAlert: false,
    provisional: true,
    sound: true,
  );

  developer.log('FCM permission status: ${settings.authorizationStatus}',
      name: 'fcm');

  // If user denied, do nothing (respect opt-out)
  if (settings.authorizationStatus == AuthorizationStatus.denied) {
    developer.log('User denied FCM permissions', name: 'fcm');
    return;
  }

  // Get current token
  final token = await messaging.getToken();
  if (token == null) {
    developer.log('FCM token null', name: 'fcm');
    return;
  }

  developer.log('FCM token: $token', name: 'fcm');

  // Save token to profiles table (RLS must allow user to update their own profile)
  try {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user != null) {
      await supabase
          .from('profiles')
          .update({'fcm_token': token}).eq('id', user.id);
      developer.log('Saved token to profiles for user ${user.id}', name: 'fcm');
    } else {
      developer.log('No supabase user when saving FCM token', name: 'fcm');
    }
  } catch (e) {
    developer.log('Error saving FCM token to DB: $e', name: 'fcm');
  }

  // Listen for token refresh and update DB
  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
    developer.log('FCM token refreshed: $newToken', name: 'fcm');
    try {
      final supabase = Supabase.instance.client;
      final user = supabase.auth.currentUser;
      if (user != null) {
        await supabase
            .from('profiles')
            .update({'fcm_token': newToken}).eq('id', user.id);
      }
    } catch (e) {
      developer.log('Error saving refreshed token: $e', name: 'fcm');
    }
  });
}

/// Register listeners so when user taps a notification the app deep-links properly.
/// Call this once you have a BuildContext available (e.g. after the first screen is built).
void registerFcmListeners(BuildContext context) {
  // When app opened from background via a notification
  FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
    developer.log('onMessageOpenedApp: ${message.data}', name: 'fcm');
    _handleMessageNavigation(context, message.data);
  });

  // When app launched from terminated state via a notification
  FirebaseMessaging.instance.getInitialMessage().then((message) {
    if (message != null) {
      developer.log('getInitialMessage: ${message.data}', name: 'fcm');
      // Delay until first frame to ensure Navigator is ready
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleMessageNavigation(context, message.data);
      });
    }
  });

  // Foreground messages: you can show a snackbar or in-app banner
  FirebaseMessaging.onMessage.listen((RemoteMessage message) {
    developer.log(
        'onMessage (foreground): ${message.notification} / ${message.data}',
        name: 'fcm');
    // Optionally show an in-app banner here.
    final title = message.notification?.title ?? '';
    final body = message.notification?.body ?? '';
    if (title.isNotEmpty || body.isNotEmpty) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger != null) {
        messenger.showSnackBar(SnackBar(
          content: Text('$title\n$body'),
          duration: const Duration(seconds: 4),
        ));
      }
    }
  });
}

/// Helper: inspect message.data and navigate accordingly
void _handleMessageNavigation(BuildContext context, Map<String, dynamic> data) {
  // expected payload shape from your Edge Function:
  // { "type": "gist", "gist_id": "123", "target": "local" }
  try {
    final type = data['type']?.toString();
    if (type == 'gist') {
      final gistId = data['gist_id'] ?? data['id'];
      if (gistId != null) {
        // adjust route name to your app's routing
        Navigator.pushNamed(context, '/gist',
            arguments: {'id': gistId.toString()});
      }
    }
    // add other types as needed
  } catch (e) {
    developer.log('Error handling FCM message navigation: $e', name: 'fcm');
  }
}
