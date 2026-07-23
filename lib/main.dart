// lib/main.dart
import 'dart:async';
import 'dart:developer' as developer;
import 'package:allowance/screens/chat/group_invite_screen.dart';
import 'package:allowance/screens/home/moment_viewer_screen.dart';
import 'package:allowance/screens/introduction/reset_password_screen.dart';
import 'package:allowance/shared/services/global_message_prefetch_service.dart';
import 'package:allowance/widgets/docked_sheet.dart';
import 'shared/services/web_back_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'shared/services/realtime_guardian.dart';
import 'package:url_strategy/url_strategy.dart';

// Deep Linking
import 'package:app_links/app_links.dart';
import 'screens/home/single_gist_screen.dart';

// Firebase & Local Notifications
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'firebase_options.dart';

import 'models/user_preferences.dart';
import 'screens/introduction/introduction_screen.dart';
import 'screens/home/home_screen.dart';
import 'screens/profile/edit_profile_screen.dart';
import 'shared/services/fcm_service.dart';
import 'widgets/custom_loading_screen.dart';

// 🔥 1. Initialize the High Importance Channel for Android
const AndroidNotificationChannel channel = AndroidNotificationChannel(
  'high_importance_channel', // This matches the ID in your Edge Function!
  'High Importance Notifications',
  description:
      'This channel is used for important notifications like DMs and Gists.',
  importance: Importance.max, // THIS IS WHAT MAKES IT POP OUT
  playSound: true,
  enableVibration: true,
);

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  setPathUrlStrategy();

  // 🔥 FIX: Draw behind Android navigation bar so input bar sits ABOVE it
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarIconBrightness: Brightness.light,
    ),
  );
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  await dotenv.load(fileName: ".env");

  final supabaseUrl = dotenv.env['SUPABASE_URL'];
  final supabaseAnonKey = dotenv.env['SUPABASE_ANON_KEY'];
  if (supabaseUrl == null || supabaseAnonKey == null) {
    throw Exception('SUPABASE_URL and SUPABASE_ANON_KEY must be set in .env');
  }

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  if (!kIsWeb) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    await flutterLocalNotificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);

    await FirebaseMessaging.instance
        .setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      RemoteNotification? notification = message.notification;
      AndroidNotification? android = message.notification?.android;

      if (notification != null && android != null) {
        flutterLocalNotificationsPlugin.show(
          notification.hashCode,
          notification.title,
          notification.body,
          NotificationDetails(
            android: AndroidNotificationDetails(
              channel.id,
              channel.name,
              channelDescription: channel.description,
              icon: '@mipmap/ic_launcher',
              importance: Importance.max,
              priority: Priority.max,
              playSound: true,
              enableVibration: true,
            ),
          ),
        );
      }
    });
  }

  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);

  runApp(const AllowanceApp());
}

class AllowanceApp extends StatefulWidget {
  const AllowanceApp({super.key});

  @override
  State<AllowanceApp> createState() => _AllowanceAppState();
}

class _AllowanceAppState extends State<AllowanceApp>
    with WidgetsBindingObserver {
  final UserPreferences _userPreferences = UserPreferences();
  bool _isInitialized = false;
  bool _fcmListenersRegistered = false;

  StreamSubscription<AuthState>? _authSub;

  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this); // 🔥 NEW
    _initializeApp();
    _initDeepLinks();
    initWebBackButton(navigatorKey);
  }

  // 🔥 NEW: system back button/gesture, intercepted before Flutter's own
  // Navigator sees it. A DockedSheet is a raw Overlay entry, not a route,
  // so the Navigator has no idea it's open and would just pop whatever
  // screen is underneath. This closes the sheet first and swallows that
  // one back press — exactly like a real bottom sheet would.
  @override
  Future<bool> didPopRoute() async {
    if (DockedSheet.isShowing) {
      DockedSheet.dismiss();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // 🔥 NEW
    _authSub?.cancel();
    _linkSubscription?.cancel();
    RealtimeGuardian.instance.dispose();
    GlobalMessagePrefetchService.instance.dispose();
    super.dispose();
  }

  // --- NEW: YOUTUBE STYLE DEEP LINK LISTENER ---
  void _initDeepLinks() {
    _appLinks = AppLinks();

    // Handle link when app is in background and opened via link
    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      _handleDeepLink(uri);
    });

    // Handle link when app is completely closed (cold start)
    _appLinks.getInitialLink().then((uri) {
      if (uri != null) _handleDeepLink(uri);
    });
  }

  void _handleDeepLink(Uri uri) {
    if (uri.pathSegments.contains('share')) {
      final type = uri.queryParameters['type'];
      final id = uri.queryParameters['id'];

      if (type == 'gist' && id != null) {
        Future.delayed(const Duration(milliseconds: 500), () {
          navigatorKey.currentState?.pushNamed('/gist', arguments: {'id': id});
        });
      } else if (type == 'moment' && id != null) {
        Future.delayed(const Duration(milliseconds: 500), () {
          navigatorKey.currentState
              ?.pushNamed('/moment', arguments: {'id': id});
        });
      } else if (type == 'group' && id != null) {
        _routeToGroupInvite(id);
      }
      return;
    }

    if (uri.pathSegments.contains('join')) {
      final refCode = uri.queryParameters['ref'];
      if (refCode != null && refCode.isNotEmpty) {
        SharedPreferences.getInstance().then((prefs) {
          prefs.setString('pending_referral_code', refCode);
          developer.log('Saved referral code: $refCode', name: 'DeepLink');
        });
      }
      return;
    }

    if (uri.pathSegments.contains('gist')) {
      final gistId = uri.pathSegments.last;
      Future.delayed(const Duration(milliseconds: 500), () {
        navigatorKey.currentState
            ?.pushNamed('/gist', arguments: {'id': gistId});
      });
      return;
    }

    if (uri.pathSegments.contains('moment')) {
      final momentId = uri.pathSegments.last;
      Future.delayed(const Duration(milliseconds: 500), () {
        navigatorKey.currentState
            ?.pushNamed('/moment', arguments: {'id': momentId});
      });
      return;
    }

    if (uri.host == 'reset-password' ||
        uri.pathSegments.contains('reset-password')) {
      Future.delayed(const Duration(milliseconds: 500), () {
        navigatorKey.currentState?.push(
          MaterialPageRoute(builder: (_) => const ResetPasswordScreen()),
        );
      });
    }
  }

  void _routeToGroupInvite(String chatId) {
    final currentUser = Supabase.instance.client.auth.currentUser;
    if (currentUser == null) {
      SharedPreferences.getInstance().then((prefs) {
        prefs.setString('pending_group_join_id', chatId);
        developer.log('Saved pending group join: $chatId', name: 'DeepLink');
      });
      return;
    }
    Future.delayed(const Duration(milliseconds: 500), () {
      navigatorKey.currentState?.push(
        MaterialPageRoute(
            builder: (_) => GroupInviteScreen(
                chatId: chatId, userPreferences: _userPreferences)),
      );
    });
  }

  Future<void> _checkPendingGroupJoin() async {
    final prefs = await SharedPreferences.getInstance();
    final pendingChatId = prefs.getString('pending_group_join_id');
    if (pendingChatId == null || pendingChatId.isEmpty) return;
    await prefs.remove('pending_group_join_id');

    Future.delayed(const Duration(milliseconds: 800), () {
      navigatorKey.currentState?.push(
        MaterialPageRoute(
            builder: (_) => GroupInviteScreen(
                chatId: pendingChatId, userPreferences: _userPreferences)),
      );
    });
  }

  Future<void> _initializeApp() async {
    try {
      await _userPreferences.loadPreferences();

      RealtimeGuardian.instance.init(); // 🔥 NEW
      GlobalMessagePrefetchService.instance.init();

      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        await _setupFcmAndListeners();
      }

      _authSub = Supabase.instance.client.auth.onAuthStateChange
          .listen((authState) async {
        final session = authState.session;
        final event = authState.event;

        if (event == AuthChangeEvent.passwordRecovery) {
          navigatorKey.currentState?.push(
            MaterialPageRoute(builder: (_) => const ResetPasswordScreen()),
          );
          return;
        }

        if (event == AuthChangeEvent.initialSession ||
            event == AuthChangeEvent.signedIn ||
            event == AuthChangeEvent.signedOut) {
          if (session != null) {
            await _userPreferences.loadPreferences();
            await _setupFcmAndListeners();
            if (event == AuthChangeEvent.signedIn ||
                event == AuthChangeEvent.initialSession) {
              _checkPendingGroupJoin();
            }
          } else {
            await _userPreferences.clearLocal();
          }
          if (mounted) setState(() {});
        }
      });
    } catch (e) {
      developer.log('App initialization error: $e', name: 'main');
    } finally {
      if (mounted) setState(() => _isInitialized = true);
    }
  }

  Future<void> _setupFcmAndListeners() async {
    try {
      if (kIsWeb) {
        await requestWebPushPermissionAndSaveToken();
      } else {
        await initFcmAndSaveToken();
      }
    } catch (e) {
      developer.log('FCM setup error: $e', name: 'main');
    }

    // 🔥 FIX: this used to run from two call sites that both fire on cold
    // start (the direct pre-check, then the auth stream replaying
    // `initialSession`), registering FirebaseMessaging.onMessage.listen(...)
    // twice — so every foreground push showed its banner (or fired its
    // haptic) twice. Guard so the listener attaches exactly once per
    // process no matter how many auth events fire.
    if (_fcmListenersRegistered) return;
    _fcmListenersRegistered = true;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = navigatorKey.currentContext;
      if (context != null) {
        registerFcmListeners(context);
      } else {
        _fcmListenersRegistered = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        systemNavigationBarColor: Colors.transparent,
      ),
      child: MaterialApp(
        navigatorKey: _AllowanceAppState.navigatorKey,
        title: 'Allowance',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(primarySwatch: Colors.indigo),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [
          Locale('en', ''),
        ],
        // ↓↓↓ WEB FIXES ↓↓↓
        builder: (context, child) {
          if (kIsWeb) {
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(
                viewPadding: EdgeInsets.zero,
              ),
              child: child ?? const SizedBox.shrink(),
            );
          }
          return child ?? const SizedBox.shrink();
        },
        onGenerateRoute: (settings) {
          if (settings.name == '/gist') {
            final args = settings.arguments as Map<String, dynamic>?;
            final gistId = args?['id'] ?? '';
            return MaterialPageRoute(
              builder: (_) => SingleGistScreen(gistId: gistId.toString()),
            );
          }

          if (settings.name != null && settings.name!.startsWith('/share')) {
            final uri = Uri.parse(settings.name!);
            final type = uri.queryParameters['type'];
            final id = uri.queryParameters['id'];

            if (type == 'gist' && id != null) {
              return MaterialPageRoute(
                builder: (_) => SingleGistScreen(gistId: id),
              );
            } else if (type == 'moment' && id != null) {
              return MaterialPageRoute(
                builder: (_) => MomentViewerScreen(
                  moments: [],
                  initialIndex: 0,
                  userPreferences: _userPreferences,
                ),
              );
            } else if (type == 'group' && id != null) {
              return MaterialPageRoute(
                  builder: (_) => GroupInviteScreen(
                      chatId: id, userPreferences: _userPreferences));
            }
          }

          return null;
        },
        home: _isInitialized ? _buildHome() : const CustomLoadingScreen(),
      ),
    );
  }

  Widget _buildHome() {
    final user = Supabase.instance.client.auth.currentUser;

    if (user == null) {
      return IntroductionScreen(
        onFinishIntro: () {},
        userPreferences: _userPreferences,
      );
    }

    return _userPreferences.hasCompletedProfile == true
        ? HomeScreen(userPreferences: _userPreferences)
        : EditProfileScreen(userPreferences: _userPreferences);
  }
}
