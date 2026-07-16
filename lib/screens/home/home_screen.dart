// lib/screens/home/home_screen.dart
import 'dart:async';
import 'dart:convert';
import 'package:allowance/screens/chat/chat_list_screen.dart';
import 'package:allowance/screens/chat/create_group_screen.dart';
import 'package:allowance/screens/chat/explore_screen.dart';
import 'package:allowance/screens/home/create_story_screen.dart';
import 'package:allowance/screens/home/gist_submission_screen.dart';
import 'package:allowance/screens/home/media_editor_screen.dart';
import 'package:allowance/screens/home/moment_viewer_screen.dart';
import 'package:allowance/screens/home/ticket_submission_screen.dart';
import 'package:allowance/screens/library/library_screen.dart';
import 'package:allowance/shared/services/fcm_service.dart';
import 'package:allowance/widgets/stories_bar.dart';
import 'package:allowance/widgets/universal_profile_card.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/home/available_options_screen.dart';
import 'package:allowance/screens/home/favorites_screen.dart';
import 'package:allowance/screens/profile/profile_screen.dart';
import 'package:allowance/screens/home/ticket_screen.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as js;
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:wechat_camera_picker/wechat_camera_picker.dart';
import 'order_screen.dart';
import 'package:allowance/services/api_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:developer' as developer;
import 'package:gal/gal.dart';
import 'package:video_player/video_player.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'dart:math';
import 'package:visibility_detector/visibility_detector.dart';

class HomeScreen extends StatefulWidget {
  final UserPreferences? userPreferences;
  const HomeScreen({super.key, this.userPreferences});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late UserPreferences _prefs;
  int _selectedIndex = 0;
  final bool _isDarkMode = true;
  final TextEditingController _budgetController = TextEditingController();
  final FocusNode _budgetFocusNode = FocusNode();
  bool _vendorBarTapped = false;
  final Color themeColor = const Color(0xFF4CAF50);
  final GlobalKey<StoriesBarState> _storiesBarKey =
      GlobalKey<StoriesBarState>();
  final Map<int, VideoPlayerController> _videoControllers = {};
  final Map<int, bool> _isVideoMuted = {};
  final Map<String, int> _schoolActivityCounts = {};
  // 1. Updated _colorfulTabs (changed Order icon to food-related)
  // 1. Updated _colorfulTabs (Circular icons, Library added)
  final List<Map<String, dynamic>> _colorfulTabs = [
    {"label": "Favorites", "icon": BoxIcons.bxs_heart, "color": Colors.orange},
    {"label": "Tickets", "icon": BoxIcons.bxs_coupon, "color": Colors.purple},
    {"label": "Order", "icon": BoxIcons.bx_food_menu, "color": Colors.teal},
    {
      "label": "Library",
      "icon": BoxIcons.bx_book_reader,
      "color": Colors.blueAccent
    }, // ← New Library Tab
  ];

  List<String> _restaurants = [];
  List<String> _selectedRestaurants = [];
  bool _selectAll = false;
  final TextEditingController _restaurantsController = TextEditingController();
  final FocusNode _restaurantFocusNode = FocusNode();
  final supabase = Supabase.instance.client;
  late PageController _pageController;
  Timer? _slideshowTimer;
  Timer? _feedRefreshDebounce;
  List<Map<String, dynamic>> _fetchedGists = [];
  final ValueNotifier<bool> _showBackToTopButton = ValueNotifier(false);

  // NEW: track loading vs loaded-with-zero-items
  bool _isGistsLoading = true;
  RealtimeChannel? _globalChatChannel;
  bool _isProcessingSubscription = false;
  // 🔥 NEW: Endless Scroll Variables
  bool _isLoadingMore = false;
  bool _hasMoreGists = true;
  bool _hasMoreMoments = true;
  int _gistOffset = 0;
  int _momentOffset = 0;
  final int _pageSize = 15;

  String _gistFilter = 'Moments & Gists';
  final Map<int, int> _gistLikeCounts = {};
  final Set<int> _likedGistIds = {};
  final Set<int> _likedMomentIds = {};
  final ScrollController _scrollController = ScrollController(); // The listener
  final Set<String> _loadedContentKeys = {};
  final List<int> _sentContentIds = [];
  int _currentPage = 1;
  // 🔥 NEW: Suggested users state
  List<Map<String, dynamic>> _suggestedUsers = [];
  bool _isLoadingSuggested = false;
  final Set<String> _followedUserIds = {};
// The visibility state

  // Fallback images (replace with your own public URLs or storage links)
  // Fallback images (now fully compatible with your UI)
  final List<Map<String, dynamic>> _fallbackGists = [
    {
      'id': -1, // negative int so it never conflicts with real gists
      'title': 'Market your brand exclusively on campus',
      'image_url':
          'https://quuazutreaitqoquzolg.supabase.co/storage/v1/object/public/random/InShot_20251114_172942404.jpg',
      'category': 'All', // ← IMPORTANT
      'profiles': {'username': 'Allowance', 'avatar_url': null, 'bio': null},
    },
    {
      'id': -2,
      'title': 'Get the best and tastiest food combos',
      'image_url':
          'https://quuazutreaitqoquzolg.supabase.co/storage/v1/object/public/random/InShot_20251114_173051467.jpg',
      'category': 'All',
      'profiles': {'username': 'Allowance', 'avatar_url': null, 'bio': null},
    },
    {
      'id': -3,
      'title': 'Let the world see your new EP!',
      'image_url':
          'https://quuazutreaitqoquzolg.supabase.co/storage/v1/object/public/random/file_00000000da98720ab5cdd39756c77926.png',
      'category': 'All',
      'profiles': {'username': 'Allowance', 'avatar_url': null, 'bio': null},
    },
  ];

  // --- OUTSIDE THE BOX: Use ValueNotifier instead of setState to prevent global scroll lag! --

  @override
  void initState() {
    super.initState();
    _prefs = widget.userPreferences ?? UserPreferences();

    _scrollController.addListener(() {
      // Back to top button logic
      if (_scrollController.offset > 300 && !_showBackToTopButton.value) {
        _showBackToTopButton.value = true;
      } else if (_scrollController.offset <= 300 &&
          _showBackToTopButton.value) {
        _showBackToTopButton.value = false;
      }

      // 🔥 FIXED: Endless Scroll Logic - Trigger when 2000 pixels from bottom
      if (!_isLoadingMore &&
          _hasMoreGists &&
          _scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 2000) {
        developer.log('🔄 Triggering load more...', name: 'scroll');
        _loadMoreItems();
      }
    });

    _budgetFocusNode.addListener(() => setState(() {}));
    _pageController = PageController(viewportFraction: 0.85);
    _budgetController.text = _prefs.budget?.toString() ?? "";

    _fetchGistsAndStartSlideshow();
    _setupGlobalChatListener();
    _recoverPendingSubscription();
    _checkWebInstallPrompt();
    _checkLocationPrompt();
  }

  @override
  void dispose() {
    _globalChatChannel?.unsubscribe();
    _disposeVideoControllers();
    _slideshowTimer?.cancel();
    _pageController.dispose();
    _budgetController.dispose();
    _budgetFocusNode.dispose();
    _restaurantsController.dispose();
    _restaurantFocusNode.dispose();
    _scrollController.dispose();
    _showBackToTopButton.dispose(); // <-- Dispose notifier
    _feedRefreshDebounce?.cancel();
    super.dispose();
  }

  // --- NEW: THE COOL ROUNDED TOP BANNER ---
  void _showInAppNotification(
      String senderName, String message, String avatarUrl) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;

    entry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.paddingOf(context).top + 10,
        left: 16,
        right: 16,
        child: Material(
          color: Colors.transparent,
          child: TweenAnimationBuilder<double>(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOutBack,
            tween: Tween<double>(begin: -100, end: 0),
            builder: (context, value, child) => Transform.translate(
              offset: Offset(0, value),
              child: child,
            ),
            child: GestureDetector(
              onTap: () {
                entry.remove();
                Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) =>
                            ChatListScreen(userPreferences: _prefs)));
              },
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius:
                      BorderRadius.circular(20), // Cool rounded corners!
                  boxShadow: const [
                    BoxShadow(
                        color: Colors.black45, blurRadius: 10, spreadRadius: 2)
                  ],
                  border:
                      Border.all(color: const Color(0xFF4CAF50), width: 1.5),
                ),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 20,
                      backgroundColor: Colors.grey[800],
                      backgroundImage:
                          avatarUrl.isNotEmpty ? NetworkImage(avatarUrl) : null,
                      child: avatarUrl.isEmpty
                          ? const Icon(Icons.person, color: Colors.white54)
                          : null,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('@$senderName',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                          Text(message,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 14),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    overlay.insert(entry);
    // Slides back up after 4 seconds
    Future.delayed(const Duration(seconds: 4), () {
      if (entry.mounted) entry.remove();
    });
  }

  // Dispose all video controllers
  void _disposeVideoControllers() {
    for (var controller in _videoControllers.values) {
      controller.dispose();
    }
    _videoControllers.clear();
    _isVideoMuted.clear();
  }

  Future<void> _handleRefresh() async {
    // Reset everything and start fresh
    _sentContentIds.clear();
    _currentPage = 1;

    setState(() {
      _fetchedGists.clear();
      _hasMoreGists = true;
      _hasMoreMoments = true;
    });

    await _fetchGistsAndStartSlideshow();
    _storiesBarKey.currentState?.refresh();
  }

  // ── NEW: Load like counts and whether current user liked each gist ──
  Future<void> _loadGistLikes(List<Map<String, dynamic>> gists,
      List<Map<String, dynamic>> moments) async {
    final user = supabase.auth.currentUser;
    if (user == null) return;

    try {
      final gistIds = gists
          .where((g) => g['id'] != null && (g['id'] as int) > 0)
          .map((g) => g['id'] as int)
          .toList();

      final momentIds = moments
          .where((m) => m['real_moment_id'] != null)
          .map((m) => m['real_moment_id'] as int)
          .toList();

      // Clear ONLY the entries for items we're about to display
      // Don't clear everything — that causes flicker
      for (final id in gistIds) {
        _gistLikeCounts.remove(id);
        _likedGistIds.remove(id);
      }
      for (final id in momentIds) {
        _likedMomentIds.remove(id);
      }

      if (gistIds.isNotEmpty) {
        final likesResponse = await supabase
            .from('gist_likes')
            .select('gist_id, user_id')
            .inFilter('gist_id', gistIds);

        for (var like in likesResponse) {
          final gid = like['gist_id'] as int;
          _gistLikeCounts[gid] = (_gistLikeCounts[gid] ?? 0) + 1;
          if (like['user_id'].toString() == user.id) {
            _likedGistIds.add(gid);
          }
        }
      }

      if (momentIds.isNotEmpty) {
        final momentLikesResponse = await supabase
            .from('moment_likes')
            .select('moment_id, user_id')
            .inFilter('moment_id', momentIds);

        for (var like in momentLikesResponse) {
          final mid = like['moment_id'] as int;
          if (like['user_id'].toString() == user.id) {
            _likedMomentIds.add(mid);
          }
        }
      }
    } catch (e) {
      developer.log('Like load error: $e', name: 'likes');
    }
  }

  // ── NEW: Toggle like (Optimistic UI Update for Instant Feedback) ──
  Future<void> _toggleLike(int id, bool isMoment) async {
    final user = supabase.auth.currentUser;
    if (user == null) return;

    final bool wasLiked =
        isMoment ? _likedMomentIds.contains(id) : _likedGistIds.contains(id);

    // 1. OPTIMISTIC UPDATE — update UI immediately
    setState(() {
      if (isMoment) {
        final momentIndex = _fetchedGists.indexWhere(
            (g) => g['is_moment'] == true && g['real_moment_id'] == id);
        if (wasLiked) {
          _likedMomentIds.remove(id);
          if (momentIndex != -1) {
            final current = _fetchedGists[momentIndex]['likes_count'] ?? 1;
            _fetchedGists[momentIndex]['likes_count'] =
                (current - 1).clamp(0, 999999);
          }
        } else {
          _likedMomentIds.add(id);
          if (momentIndex != -1) {
            final current = _fetchedGists[momentIndex]['likes_count'] ?? 0;
            _fetchedGists[momentIndex]['likes_count'] = current + 1;
          }
        }
      } else {
        if (wasLiked) {
          _likedGistIds.remove(id);
          _gistLikeCounts[id] =
              ((_gistLikeCounts[id] ?? 1) - 1).clamp(0, 999999);
        } else {
          _likedGistIds.add(id);
          _gistLikeCounts[id] = (_gistLikeCounts[id] ?? 0) + 1;
        }
      }
    });

    // 2. NETWORK CALL — do it quietly in background
    try {
      if (isMoment) {
        if (wasLiked) {
          await supabase
              .from('moment_likes')
              .delete()
              .eq('moment_id', id)
              .eq('user_id', user.id);
        } else {
          await supabase
              .from('moment_likes')
              .insert({'moment_id': id, 'user_id': user.id});
        }
      } else {
        if (wasLiked) {
          await supabase
              .from('gist_likes')
              .delete()
              .eq('gist_id', id)
              .eq('user_id', user.id);
        } else {
          await supabase
              .from('gist_likes')
              .insert({'gist_id': id, 'user_id': user.id});
        }
      }
    } catch (e) {
      developer.log('Like error: $e', name: 'likes');
      // Rollback on error
      if (mounted) {
        setState(() {
          if (isMoment) {
            final momentIndex = _fetchedGists.indexWhere(
                (g) => g['is_moment'] == true && g['real_moment_id'] == id);
            if (wasLiked) {
              _likedMomentIds.add(id);
              if (momentIndex != -1) {
                final current = _fetchedGists[momentIndex]['likes_count'] ?? 0;
                _fetchedGists[momentIndex]['likes_count'] = current + 1;
              }
            } else {
              _likedMomentIds.remove(id);
              if (momentIndex != -1) {
                final current = _fetchedGists[momentIndex]['likes_count'] ?? 1;
                _fetchedGists[momentIndex]['likes_count'] =
                    (current - 1).clamp(0, 999999);
              }
            }
          } else {
            if (wasLiked) {
              _likedGistIds.add(id);
              _gistLikeCounts[id] = (_gistLikeCounts[id] ?? 0) + 1;
            } else {
              _likedGistIds.remove(id);
              _gistLikeCounts[id] =
                  ((_gistLikeCounts[id] ?? 1) - 1).clamp(0, 999999);
            }
          }
        });
      }
    }
  }

  Future<void> _fetchGistsAndStartSlideshow() async {
    // Reset pagination state
    _sentContentIds.clear();
    _currentPage = 1;

    setState(() {
      _isGistsLoading = true;
      _hasMoreGists = true;
      _hasMoreMoments = true;
      _fetchedGists.clear();
    });

    await _loadMoreItems(isInitialLoad: true);
  }

  // 🔥 NEW: Endless Scroll Data Fetcher

  // Track which content IDs we've already sent to the server to exclude

  Future<void> _loadMoreItems({bool isInitialLoad = false}) async {
    if (_isLoadingMore) return;

    if (mounted && !isInitialLoad) {
      setState(() => _isLoadingMore = true);
    }
    if (mounted && isInitialLoad) {
      setState(() {
        _isGistsLoading = true;
        _sentContentIds.clear();
        _currentPage = 1;
      });
    }

    try {
      final user = supabase.auth.currentUser;

      // 🔥 FIX: Handle null user gracefully
      if (user == null) {
        await _loadLegacyFeed(isInitialLoad: isInitialLoad);
        return;
      }

      final sidStr = _prefs.schoolId;
      final isStateMode = sidStr != null && sidStr.startsWith('STATE_');
      final actualStateId =
          isStateMode ? sidStr.replaceAll('STATE_', '') : null;
      final actualSchoolId = !isStateMode ? sidStr : null;

      // Get muted categories
      List<String> mutedCats = [];
      try {
        final profile = await supabase
            .from('profiles')
            .select('muted_categories')
            .eq('id', user.id)
            .maybeSingle();
        if (profile != null && profile['muted_categories'] != null) {
          mutedCats = List<String>.from(profile['muted_categories']);
        }
      } catch (_) {
        // Ignore profile fetch errors
      }

      // Call smart feed edge function
      final response = await supabase.functions.invoke(
        'smart-feed',
        body: {
          'user_id': user.id,
          'school_id':
              actualSchoolId != null ? int.tryParse(actualSchoolId) : null,
          'state_id':
              actualStateId != null ? int.tryParse(actualStateId) : null,
          'is_state_mode': isStateMode,
          'page': _currentPage,
          'page_size': _pageSize,
          'muted_categories': mutedCats,
          'gist_filter': _gistFilter,
          'exclude_ids': _sentContentIds,
        },
      );

      if (response.status != 200 || response.data == null) {
        throw Exception('Smart feed failed: status=${response.status}');
      }

      final data = response.data as Map<String, dynamic>;
      final List<dynamic> feed = data['feed'] ?? [];
      final bool hasMore = data['has_more'] ?? false;

      developer.log(
        '🎯 Smart Feed | page=$_currentPage | returned=${feed.length} | hasMore=$hasMore',
        name: 'smart_feed',
      );

      // Convert feed items
      final List<Map<String, dynamic>> newItems = [];
      for (final rawItem in feed) {
        final g = rawItem as Map<String, dynamic>;
        _sentContentIds.add(g['id'] as int);

        final rawProfiles = g['profiles'];
        Map<String, dynamic> profiles = {
          'username': 'User',
          'avatar_url': '',
          'bio': '',
          'school_name': '',
        };

        if (rawProfiles is Map) {
          final rp = Map<String, dynamic>.from(rawProfiles);
          profiles = {
            'username': rp['username']?.toString() ?? 'User',
            'avatar_url': rp['avatar_url']?.toString() ?? '',
            'bio': rp['bio']?.toString() ?? '',
            'school_name': rp['school_name']?.toString() ?? '',
          };
        }

        if (g['is_moment'] == true) {
          newItems.add({
            'id': g['id'],
            'is_moment': true,
            'real_moment_id': g['real_moment_id'],
            'user_id': g['user_id'],
            'title': g['title'] ?? '',
            'image_url': g['image_url'] ?? '',
            'image_urls': g['image_urls'] ?? [],
            'media_type': g['media_type'] ?? 'image',
            'type': g['type'] ?? 'local',
            'created_at': g['created_at'],
            'category': g['category'] ?? 'Random',
            'profiles': profiles,
            'likes_count': g['likes_count'] ?? 0,
            'comments_count': g['comments_count'] ?? 0,
          });
        } else {
          newItems.add({
            'id': g['id'],
            'user_id': g['user_id'],
            'title': g['title'] ?? '',
            'image_url': g['image_url'] ?? '',
            'image_urls': g['image_urls'] ?? [],
            'media_type': g['media_type'] ?? 'image',
            'type': g['type'] ?? 'global',
            'school_id': g['school_id'],
            'state_id': g['state_id'],
            'url': g['url'],
            'created_at': g['created_at'],
            'category': g['category'] ?? 'Random',
            'has_poll': g['has_poll'] ?? false,
            'poll_options': g['poll_options'],
            'allow_multiple_votes': g['allow_multiple_votes'] ?? false,
            'profiles': profiles,
          });
        }
      }

      // Load like states
      if (newItems.isNotEmpty) {
        final gistsList =
            newItems.where((g) => g['is_moment'] != true).toList();
        final momentsList =
            newItems.where((g) => g['is_moment'] == true).toList();
        await _loadGistLikes(gistsList, momentsList);
      }

      if (mounted) {
        setState(() {
          if (isInitialLoad) {
            _fetchedGists = newItems;
          } else {
            _fetchedGists.addAll(newItems);
          }
          _isGistsLoading = false;
          _isLoadingMore = false;
          _hasMoreGists = hasMore;
          _hasMoreMoments = hasMore;
        });
      }

      if (hasMore) {
        _currentPage++;
      }

      // Fetch suggested users
      if (mounted && _suggestedUsers.isEmpty) {
        _fetchSuggestedUsers();
      }

      // Fallback if completely empty
      if (isInitialLoad && newItems.isEmpty && mounted) {
        setState(() => _fetchedGists = List.from(_fallbackGists));
      }
    } catch (e, stackTrace) {
      developer.log('Smart feed error: $e\n$stackTrace', name: 'smart_feed');

      // 🔥 CRITICAL FIX: Always reset loading state on error
      if (mounted) {
        setState(() {
          _isGistsLoading = false;
          _isLoadingMore = false;
        });
      }

      // Try legacy feed as fallback
      await _loadLegacyFeed(isInitialLoad: isInitialLoad);
    }
  }

  // 🔥 NEW: Fetch suggested users (friends of friends / same school / mutuals)
  // 🔥 NEW: Fetch suggested users (friends of friends / same school / mutuals)
  Future<void> _fetchSuggestedUsers() async {
    if (_isLoadingSuggested) return;
    setState(() => _isLoadingSuggested = true);

    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      final myId = user.id;
      final sidStr = _prefs.schoolId;
      final isStateMode = sidStr != null && sidStr.startsWith('STATE_');
      final actualStateId =
          isStateMode ? sidStr.replaceAll('STATE_', '') : null;
      final actualSchoolId = !isStateMode ? sidStr : null;

      // Step 1: Get who I follow
      final myFollowingResp = await supabase
          .from('followers')
          .select('following_id')
          .eq('follower_id', myId);

      final followingIds = (myFollowingResp as List<dynamic>)
          .map((f) => f['following_id'] as String)
          .toSet();
      followingIds.add(myId);

      // Step 2: Get friends of friends
      List<String> fofIds = [];
      if (followingIds.isNotEmpty) {
        // Build the "not in" string for following_ids
        final notInList = followingIds.toList();

        var fofQuery = supabase
            .from('followers')
            .select('following_id')
            .inFilter('follower_id', followingIds.toList());

        // Use neq to exclude already-followed users
        if (notInList.isNotEmpty) {
          fofQuery =
              fofQuery.not('following_id', 'in', '(${notInList.join(',')})');
        }

        final fofResp = await fofQuery.limit(50);

        fofIds = (fofResp as List<dynamic>)
            .map((f) => f['following_id'] as String)
            .where((id) => !followingIds.contains(id))
            .toSet()
            .toList();
      }

      // Step 3: Get same-school / same-state users if needed
      List<Map<String, dynamic>> schoolUsers = [];
      if (fofIds.length < 6) {
        var schoolQuery = supabase
            .from('profiles')
            .select(
                'id, username, avatar_url, bio, school_name, subscription_tier')
            .neq('id', myId);

        // Exclude already followed users
        if (followingIds.isNotEmpty) {
          schoolQuery =
              schoolQuery.not('id', 'in', '(${followingIds.join(',')})');
        }

        if (isStateMode && actualStateId != null) {
          schoolQuery =
              schoolQuery.eq('state_id', int.tryParse(actualStateId) ?? 0);
        } else if (actualSchoolId != null) {
          schoolQuery = schoolQuery.eq('school_id', actualSchoolId);
        }

        final su = await schoolQuery.limit(20);
        schoolUsers = (su as List<dynamic>).cast<Map<String, dynamic>>();
      }

      // Step 4: Combine and prioritize
      List<Map<String, dynamic>> suggested = [];

      if (fofIds.isNotEmpty) {
        final fofProfilesResp = await supabase
            .from('profiles')
            .select(
                'id, username, avatar_url, bio, school_name, subscription_tier')
            .inFilter('id', fofIds.take(20).toList());

        final fofProfiles =
            (fofProfilesResp as List<dynamic>).cast<Map<String, dynamic>>();

        // Count mutuals for each
        for (var profile in fofProfiles) {
          final pid = profile['id'] as String;

          final mutualsResp = await supabase
              .from('followers')
              .select('follower_id')
              .eq('following_id', pid)
              .inFilter('follower_id', followingIds.toList());

          final count = (mutualsResp as List<dynamic>).length;
          profile['mutual_count'] = count;
          suggested.add(profile);
        }

        suggested.sort((a, b) =>
            (b['mutual_count'] ?? 0).compareTo(a['mutual_count'] ?? 0));
      }

      // Fill remaining slots with same-school users
      final existingIds = suggested.map((s) => s['id'] as String).toSet();
      for (var su in schoolUsers) {
        if (!existingIds.contains(su['id'])) {
          su['mutual_count'] = 0;
          suggested.add(su);
          existingIds.add(su['id'] as String);
        }
        if (suggested.length >= 12) break;
      }

      if (mounted) {
        setState(() {
          _suggestedUsers = suggested.take(12).toList();
          _isLoadingSuggested = false;
        });
      }
    } catch (e) {
      developer.log('Suggested users error: $e', name: 'suggestions');
      if (mounted) setState(() => _isLoadingSuggested = false);
    }
  }

  // 🔥 NEW: Follow a user from suggestions
  Future<void> _followUser(String userId) async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return;

      await supabase.from('followers').insert({
        'follower_id': user.id,
        'following_id': userId,
      });

      setState(() => _followedUserIds.add(userId));
    } catch (e) {
      developer.log('Follow error: $e', name: 'follow');
    }
  }

  // 🔥 LEGACY FEED (kept as fallback)
  Future<void> _loadLegacyFeed({bool isInitialLoad = false}) async {
    try {
      final sidStr = _prefs.schoolId;
      final isStateMode = sidStr != null && sidStr.startsWith('STATE_');
      final actualStateId =
          isStateMode ? sidStr.replaceAll('STATE_', '') : null;
      final myId = supabase.auth.currentUser?.id;

      List<String> mutedCats = [];
      if (myId != null) {
        final profile = await supabase
            .from('profiles')
            .select('muted_categories')
            .eq('id', myId)
            .maybeSingle();
        if (profile != null && profile['muted_categories'] != null) {
          mutedCats = List<String>.from(profile['muted_categories']);
        }
      }

      List<Map<String, dynamic>> rawGists = [];
      if (_hasMoreGists) {
        rawGists = await supabase
            .from('gists')
            .select(
                'id, user_id, title, image_url, image_urls, media_type, type, school_id, state_id, url, created_at, category, has_poll, poll_options, allow_multiple_votes, profiles:user_id (username, avatar_url, bio, school_name)')
            .eq('paid', true)
            .eq('status', 'active')
            .order('created_at', ascending: false)
            .range(_gistOffset, _gistOffset + _pageSize - 1);

        if (rawGists.length < _pageSize) _hasMoreGists = false;
        _gistOffset += _pageSize;
      }

      List<Map<String, dynamic>> rawMoments = [];
      if (_hasMoreMoments) {
        rawMoments = await supabase
            .from('moments')
            .select(
                'id, user_id, caption, media_url, media_type, created_at, category, likes_count, comments_count, profiles:user_id (username, avatar_url, bio, school_id, school_name, state_id)')
            .order('created_at', ascending: false)
            .range(_momentOffset, _momentOffset + _pageSize - 1);

        if (rawMoments.length < _pageSize) _hasMoreMoments = false;
        _momentOffset += _pageSize;
      }

      List<Map<String, dynamic>> finalGists = [];
      List<Map<String, dynamic>> finalMoments = [];

      for (var g in rawGists) {
        bool match = false;
        final type = (g['type'] ?? '').toString().toLowerCase();
        if (type == 'global') match = true;
        if (type == 'local') {
          if (!isStateMode && g['school_id']?.toString() == sidStr)
            match = true;
          if (isStateMode && g['state_id']?.toString() == actualStateId)
            match = true;
        }
        if (match && !mutedCats.contains(g['category'])) finalGists.add(g);
      }

      for (var m in rawMoments) {
        final mSchoolId = m['profiles']?['school_id']?.toString();
        final mStateId = m['profiles']?['state_id']?.toString();
        bool match = false;
        if (!isStateMode && mSchoolId == sidStr) match = true;
        if (isStateMode && mStateId == actualStateId) match = true;
        if (match && !mutedCats.contains(m['category'])) {
          finalMoments.add({
            'id': -(m['id'] as int),
            'is_moment': true,
            'real_moment_id': m['id'],
            'user_id': m['user_id'],
            'title': m['caption'],
            'image_url': m['media_url'],
            'image_urls': [],
            'media_type': m['media_type'],
            'type': 'local',
            'created_at': m['created_at'],
            'category': m['category'] ?? 'Random',
            'profiles': m['profiles'],
            'likes_count': m['likes_count'] ?? 0,
            'comments_count': m['comments_count'] ?? 0,
          });
        }
      }

      await _loadGistLikes(finalGists, finalMoments);

      List<Map<String, dynamic>> unlikedMoments = [];
      List<Map<String, dynamic>> likedMoments = [];

      for (var m in finalMoments) {
        if (_likedMomentIds.contains(m['real_moment_id'])) {
          likedMoments.add(m);
        } else {
          unlikedMoments.add(m);
        }
      }

      finalGists.sort((a, b) => DateTime.parse(b['created_at'])
          .compareTo(DateTime.parse(a['created_at'])));
      unlikedMoments.shuffle(Random());
      likedMoments.shuffle(Random());

      List<Map<String, dynamic>> combined = List.from(finalGists);
      for (var m in unlikedMoments) {
        int maxInsertIndex = (combined.length * 0.7).toInt();
        if (maxInsertIndex < 1) maxInsertIndex = combined.length;
        final randomPos =
            combined.isEmpty ? 0 : Random().nextInt(maxInsertIndex + 1);
        combined.insert(randomPos, m);
      }
      combined.addAll(likedMoments);

      if (mounted) {
        setState(() {
          _fetchedGists.addAll(combined);
          _isGistsLoading = false;
          _isLoadingMore = false;
        });
      }

      if (isInitialLoad && _fetchedGists.isEmpty) {
        setState(() => _fetchedGists = List.from(_fallbackGists));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isGistsLoading = false;
          _isLoadingMore = false;
          if (isInitialLoad) _fetchedGists = List.from(_fallbackGists);
        });
      }
    }
  }

  // 3. ULTIMATE PERFORMANCE SLIDESHOW
  Widget _buildGistSlideshow() {
    List<Map<String, dynamic>> filteredGists;
    if (_gistFilter == 'Moments & Gists' || _gistFilter == 'All') {
      filteredGists = _fetchedGists;
    } else if (_gistFilter == 'Just Gists') {
      filteredGists =
          _fetchedGists.where((g) => g['is_moment'] != true).toList();
    } else {
      filteredGists =
          _fetchedGists.where((g) => g['category'] == _gistFilter).toList();
    }

    if (_isGistsLoading && _fetchedGists.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: 40.0),
          child: Center(
            child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
          ),
        ),
      );
    }

    if (filteredGists.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 60.0),
          child: Center(
            child: Column(
              children: [
                Icon(Icons.inbox, color: Colors.white24, size: 48),
                const SizedBox(height: 16),
                Text(
                  _gistFilter == 'Just Gists'
                      ? 'No gists available'
                      : _gistFilter == 'Moments & Gists' || _gistFilter == 'All'
                          ? 'No content available'
                          : 'No $_gistFilter content available',
                  style: const TextStyle(color: Colors.white54, fontSize: 16),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // 🔥 Build the list with suggested users injected every 5 posts
    final List<dynamic> displayItems = [];
    for (int i = 0; i < filteredGists.length; i++) {
      displayItems.add(filteredGists[i]);
      // After every 5 posts, inject a suggested users row
      if ((i + 1) % 5 == 0 && _suggestedUsers.isNotEmpty) {
        displayItems.add({'type': 'suggested_users', 'id': 'suggested_$i'});
      }
    }

    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 40, top: 0),
      sliver: SliverList.builder(
        itemCount: displayItems.length + (_isLoadingMore ? 1 : 0),
        itemBuilder: (ctx, idx) {
          // Loading indicator at bottom
          if (idx == displayItems.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 24.0),
              child: Center(
                child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
              ),
            );
          }

          final item = displayItems[idx];

          // 🔥 Render suggested users row
          if (item is Map && item['type'] == 'suggested_users') {
            return _buildSuggestedUsersRow();
          }

          final gist = item as Map<String, dynamic>;
          final gistId = (gist['id'] is int)
              ? gist['id'] as int
              : int.tryParse(gist['id'].toString()) ?? 0;

          final isMoment = gist['is_moment'] == true;
          final realId = isMoment ? gist['real_moment_id'] as int : gistId;

          return VisibilityDetector(
            key: Key('feed_item_$realId'),
            onVisibilityChanged: (info) {
              if (info.visibleFraction > 0.5) {
                _trackContentView(realId, isMoment);
              }
            },
            child: _GistItemCard(
              key: ValueKey('item_$realId'),
              gist: gist,
              gistId: realId,
              videoController: _videoControllers[gistId],
              isMutedInitial: _isVideoMuted[gistId] ?? true,
              likeCount: isMoment
                  ? (gist['likes_count'] ?? 0)
                  : (_gistLikeCounts[realId] ?? 0),
              isLiked: isMoment
                  ? _likedMomentIds.contains(realId)
                  : _likedGistIds.contains(realId),
              onToggleLike: () => _toggleLike(realId, isMoment),
              onShowComments: () => isMoment
                  ? _showMomentCommentsSheet(realId.toString())
                  : _showCommentsSheet(realId.toString()),
              onDownload: _downloadGistImage,
              onToggleMute: (muted) => _isVideoMuted[gistId] = muted,
              themeColor: themeColor,
              prefs: _prefs,
              allFeedItems: filteredGists,
            ),
          );
        },
      ),
    );
  }

  // 🔥 NEW: Instagram-style suggested users horizontal row
  // 🔥 NEW: Instagram-style suggested users horizontal row
  Widget _buildSuggestedUsersRow() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 12),
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        border: Border(
          top: BorderSide(color: Colors.white.withOpacity(0.05)),
          bottom: BorderSide(color: Colors.white.withOpacity(0.05)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.people_outline, color: themeColor, size: 18),
                    const SizedBox(width: 8),
                    const Text(
                      'Suggested for you',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                GestureDetector(
                  onTap: () {
                    setState(() => _selectedIndex = 1);
                  },
                  child: Text(
                    'See All',
                    style: TextStyle(
                      color: themeColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Horizontal scrollable cards
          SizedBox(
            height: 185,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _suggestedUsers.length,
              itemBuilder: (ctx, index) {
                final user = _suggestedUsers[index];
                final userId = user['id'] as String;
                final username = user['username']?.toString() ?? 'User';
                final avatarUrl = user['avatar_url']?.toString();
                final schoolName = user['school_name']?.toString() ?? '';
                final isPlus = user['subscription_tier'] == 'Membership';
                final mutualCount = user['mutual_count'] ?? 0;
                final isFollowed = _followedUserIds.contains(userId);

                return Container(
                  width: 140,
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2A2A2A),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(height: 12),
                      // 🔥 AVATAR — now tappable
                      GestureDetector(
                        onTap: () {
                          if (userId.isNotEmpty) {
                            UniversalProfileCard.show(context, userId, _prefs);
                          }
                        },
                        child: Stack(
                          children: [
                            CircleAvatar(
                              radius: 32,
                              backgroundColor: Colors.grey[800],
                              backgroundImage:
                                  (avatarUrl != null && avatarUrl.isNotEmpty)
                                      ? CachedNetworkImageProvider(avatarUrl)
                                      : null,
                              child: (avatarUrl == null || avatarUrl.isEmpty)
                                  ? Text(
                                      username.isNotEmpty
                                          ? username[0].toUpperCase()
                                          : '?',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 20,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    )
                                  : null,
                            ),
                            if (isPlus)
                              Positioned(
                                bottom: 0,
                                right: 0,
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: const BoxDecoration(
                                    color: Color(0xFF2A2A2A),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.verified,
                                    color: Colors.amber,
                                    size: 14,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 10),
                      // 🔥 USERNAME — now tappable
                      GestureDetector(
                        onTap: () {
                          if (userId.isNotEmpty) {
                            UniversalProfileCard.show(context, userId, _prefs);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            '@$username',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      // Mutual friends or school
                      Text(
                        mutualCount > 0
                            ? '$mutualCount mutual friend${mutualCount > 1 ? 's' : ''}'
                            : (schoolName.isNotEmpty
                                ? schoolName
                                : 'Suggested'),
                        style: TextStyle(
                          color: Colors.white.withOpacity(0.5),
                          fontSize: 10,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 10),
                      // Follow button
                      GestureDetector(
                        onTap: isFollowed ? null : () => _followUser(userId),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 6),
                          decoration: BoxDecoration(
                            color: isFollowed
                                ? Colors.white.withOpacity(0.1)
                                : themeColor,
                            borderRadius: BorderRadius.circular(20),
                            border: isFollowed
                                ? Border.all(
                                    color: Colors.white.withOpacity(0.2))
                                : null,
                          ),
                          child: Text(
                            isFollowed ? 'Following' : 'Follow',
                            style: TextStyle(
                              color: isFollowed ? Colors.white70 : Colors.black,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _trackContentView(int contentId, bool isMoment) {
    final user = supabase.auth.currentUser;
    if (user == null) return;

    supabase
        .from('user_views')
        .upsert({
          'user_id': user.id,
          'content_type': isMoment ? 'moment' : 'gist',
          'content_id': contentId,
          'viewed_at': DateTime.now().toIso8601String(),
        }, onConflict: 'user_id,content_type,content_id')
        .then((_) {})
        .catchError((_) {});
  }

  // --- NEW: MANDATORY LOCATION PROMPT ---
  Future<void> _checkLocationPrompt() async {
    // If user already has a valid school OR a public state selected, do nothing
    if (_prefs.schoolName != null &&
        _prefs.schoolName!.trim().isNotEmpty &&
        _prefs.schoolName != 'Allowance') {
      return;
    }

    // Delay to let the home screen finish rendering its initial frame
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      isDismissible: false, // 🔥 Force them to choose before continuing
      enableDrag: false,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => PopScope(
        canPop: false, // Prevents Android back button bypass
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.travel_explore,
                  size: 60, color: Color(0xFF4CAF50)),
              const SizedBox(height: 16),
              const Text("Where do you belong?",
                  style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const SizedBox(height: 12),
              const Text(
                  "To enjoy the full Allowance experience, join your Campus community or explore globally in Public Mode!",
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white70, fontSize: 15, height: 1.4)),
              const SizedBox(height: 32),

              // 🎓 School Button
              ElevatedButton.icon(
                icon: const Icon(Icons.school, color: Colors.black),
                label: const Text("Select University",
                    style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  minimumSize: const Size(double.infinity, 56),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  _chooseUniversity();
                },
              ),
              const SizedBox(height: 16),

              // 🌍 Public State Button
              OutlinedButton.icon(
                icon: const Icon(Icons.public, color: Colors.blueAccent),
                label: const Text("Go Public (Select State)",
                    style: TextStyle(
                        color: Colors.blueAccent,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.blueAccent, width: 1.5),
                  backgroundColor: Colors.blueAccent.withOpacity(0.1),
                  minimumSize: const Size(double.infinity, 56),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  _showStatePicker();
                },
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  // --- 2. DYNAMIC ACTIVITY TAGS ---
  Widget _getActivityTagForSchool(String id) {
    final count = _schoolActivityCounts[id] ?? 0;

    String text;
    Color color;

    // 🔥 100% ACCURATE THRESHOLDS based on actual registered students!
    if (count >= 100) {
      text = 'Highly Active 🔥';
      color = Colors.greenAccent;
    } else if (count >= 30) {
      text = 'Very Active ⚡';
      color = Colors.blueAccent;
    } else if (count >= 10) {
      text = 'Active ✨';
      color = Colors.purpleAccent;
    } else if (count >= 2) {
      text = 'Calm/Slow 🍃';
      color = Colors.orangeAccent;
    } else {
      text = 'Not Active 😴';
      color = Colors.redAccent;
    }

    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        border: Border.all(color: color.withOpacity(0.3), width: 1.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5),
      ),
    );
  }

  // --- 1. THE BACKGROUND FETCH FOR THE PICKER ---
  Future<List<dynamic>> _fetchSchoolsAndActivity() async {
    try {
      final schools = await ApiService.fetchSchools();
      // 🔥 REAL ACTIVITY MEASUREMENT: Accurately count users per school
      final profiles = await supabase.from('profiles').select('school_id');
      _schoolActivityCounts.clear();
      for (var p in profiles) {
        final sId = p['school_id']?.toString() ?? '';
        if (sId.isNotEmpty) {
          _schoolActivityCounts[sId] = (_schoolActivityCounts[sId] ?? 0) + 1;
        }
      }
      return schools;
    } catch (e) {
      throw Exception("Failed to load schools");
    }
  }

  // --- 2. INSTANT LOAD SCHOOL PICKER ---
  void _chooseUniversity() {
    // 🔥 FIX: Opens instantly! No awaiting here.
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (sheetContext) => _buildSchoolPicker(sheetContext),
    );
  }

  // --- 3. THE INSTANT RENDER PICKER UI ---
  Widget _buildSchoolPicker(BuildContext modalContext) {
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      builder: (BuildContext draggableSheetContext,
          ScrollController scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: _isDarkMode ? const Color(0xFF121212) : Colors.grey[100],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              const SizedBox(height: 12),
              Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2))),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text("Select University",
                    style: TextStyle(
                        fontFamily: 'Montserrat',
                        fontSize: 20,
                        color: textColor,
                        fontWeight: FontWeight.bold)),
              ),
              const Divider(color: Colors.white10, height: 1),

              // THE SCROLLABLE SCHOOL LIST WITH FUTURE BUILDER
              Expanded(
                child: FutureBuilder<List<dynamic>>(
                    future: _fetchSchoolsAndActivity(),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting) {
                        return const Center(
                            child: CircularProgressIndicator(
                                color: Color(0xFF4CAF50)));
                      }
                      if (snapshot.hasError) {
                        return Center(
                            child: Text(
                                "Couldn't load schools. Please try again.",
                                style: TextStyle(color: textColor)));
                      }

                      final schools = snapshot.data ?? [];
                      if (schools.isEmpty) {
                        return Center(
                            child: Text("No schools available",
                                style: TextStyle(color: textColor)));
                      }

                      return ListView.builder(
                        controller: scrollController,
                        itemCount: schools.length,
                        itemBuilder: (ctx, index) {
                          final school = schools[index];
                          final name =
                              school["name"] as String? ?? "Unnamed School";
                          final idStr = school["id"].toString();
                          final isSelected = _prefs.schoolId == idStr;

                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 8),
                            title: Text(name,
                                style: TextStyle(
                                    fontFamily: 'Montserrat',
                                    fontSize: 16,
                                    color: textColor,
                                    fontWeight: FontWeight.w600)),
                            subtitle: Align(
                              alignment: Alignment.centerLeft,
                              child: _getActivityTagForSchool(idStr),
                            ),
                            trailing: isSelected
                                ? Icon(Icons.check_circle,
                                    color: themeColor, size: 28)
                                : null,
                            onTap: () async {
                              _prefs.schoolId = idStr;
                              _prefs.schoolName = name;
                              await _prefs.savePreferences();
                              if (!mounted) return;
                              Navigator.pop(modalContext);
                              setState(() => _selectedRestaurants.clear());
                              _handleRefresh(); // Instantly update Home Screen
                            },
                          );
                        },
                      );
                    }),
              ),

              // THE STEADY PUBLIC MODE BOTTOM BAR (BRAND THEMED)
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: _isDarkMode ? const Color(0xFF1E1E1E) : Colors.white,
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(24)),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 10,
                        offset: const Offset(0, -5))
                  ],
                ),
                child: SafeArea(
                  top: false,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: themeColor.withOpacity(0.15),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                            color: themeColor.withOpacity(0.5), width: 1.5),
                      ),
                      minimumSize: const Size(double.infinity, 56),
                    ),
                    onPressed: () {
                      Navigator.pop(modalContext);
                      _showStatePicker();
                    },
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.public, color: themeColor, size: 24),
                        const SizedBox(width: 10),
                        Text('Switch to Public Mode (State)',
                            style: TextStyle(
                                color: themeColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                letterSpacing: 0.5)),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // --- 4. PUBLIC MODE STATE PICKER ---
  void _showStatePicker() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        return FutureBuilder<List<dynamic>>(
            future: supabase
                .from('states')
                .select('id, name')
                .order('name', ascending: true),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const SizedBox(
                    height: 400,
                    child: Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFF4CAF50))));
              }

              final states = snapshot.data ?? [];
              int selectedIndex = 0;

              return Container(
                height: 400,
                padding: const EdgeInsets.only(top: 24),
                child: Column(
                  children: [
                    const Text("Select Your State",
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 4),
                    Text("Public Mode",
                        style: TextStyle(
                            color: themeColor,
                            fontSize: 13,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    Expanded(
                      child: CupertinoPicker(
                        itemExtent: 45,
                        scrollController:
                            FixedExtentScrollController(initialItem: 0),
                        onSelectedItemChanged: (index) => selectedIndex = index,
                        children: states
                            .map((state) => Center(
                                child: Text(state['name'],
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 22,
                                        fontWeight: FontWeight.w500))))
                            .toList(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: SafeArea(
                        top: false,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: themeColor,
                              minimumSize: const Size(double.infinity, 56),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16))),
                          onPressed: () async {
                            final selectedState = states[selectedIndex];

                            final stateCode = "STATE_${selectedState['id']}";
                            _prefs.schoolId = stateCode;
                            _prefs.schoolName = selectedState['name'];
                            await _prefs.savePreferences();

                            final myId = supabase.auth.currentUser?.id;
                            if (myId != null) {
                              // 🔥 FIX: Save the STATE_ID format to school_id so the database remembers it!
                              supabase
                                  .from('profiles')
                                  .update({
                                    'school_id': stateCode,
                                    'school_name': selectedState['name'],
                                    'state_id': selectedState['id']
                                  })
                                  .eq('id', myId)
                                  .then((_) {});
                            }

                            if (mounted) {
                              Navigator.pop(ctx);
                              setState(() => _selectedRestaurants.clear());
                              _handleRefresh();
                            }
                          },
                          child: const Text('Confirm',
                              style: TextStyle(
                                  color: Colors.black,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            });
      },
    );
  }

  // --- ULTRA-SLEEK WEB INSTALL PROMPT (OVERFLOW FIXED) ---
  Future<void> _checkWebInstallPrompt() async {
    if (!kIsWeb) return;

    final prefs = await SharedPreferences.getInstance();
    final hasSeen = prefs.getBool('has_seen_web_install') ?? false;

    if (!hasSeen) {
      await prefs.setBool('has_seen_web_install', true);

      Future.delayed(const Duration(seconds: 3), () {
        if (!mounted) return;
        showModalBottomSheet(
          context: context,
          backgroundColor: const Color(0xFF121212),
          isScrollControlled: true, // Allows sheet to adjust dynamically
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(30))),
          builder: (ctx) => SafeArea(
            // 🔥 FIX 1: SafeArea added
            child: SingleChildScrollView(
              // 🔥 FIX 2: Prevents pixel overflow on small screens!
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(2))),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: themeColor.withOpacity(0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.install_mobile,
                          size: 50, color: themeColor),
                    ),
                    const SizedBox(height: 20),
                    const Text("Get the Allowance App!",
                        style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                    const SizedBox(height: 12),
                    const Text(
                        "Install Allowance on your home screen for lightning-fast speeds, offline access, and real-time push notifications! 🚀",
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white70, fontSize: 15, height: 1.4)),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        children: [
                          _buildInstallStep("1",
                              "Tap the Share icon (iOS) or Menu (Android) in your browser header."),
                          const Divider(color: Colors.white10, height: 20),
                          _buildInstallStep(
                              "2", "Select 'Add to Home Screen'."),
                          const Divider(color: Colors.white10, height: 20),
                          _buildInstallStep("3",
                              "Open Allowance directly from your app drawer!"),
                        ],
                      ),
                    ),
                    const SizedBox(height: 32),
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          if (kIsWeb) {
                            try {
                              (js.context as dynamic)
                                  .callMethod('triggerPwaInstall');
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                      content: Text(
                                          "Click the browser menu and select 'Add to Home Screen'")));
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                            backgroundColor: themeColor,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16))),
                        child: const Text("I'll Install It Now",
                            style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                                fontSize: 16)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text("Maybe later",
                            style: TextStyle(
                                color: Colors.white54, fontSize: 15))),
                  ],
                ),
              ),
            ),
          ),
        );
      });
    }
  }

  Widget _buildInstallStep(String number, String text) {
    return Row(
      children: [
        CircleAvatar(
            radius: 12,
            backgroundColor: themeColor.withOpacity(0.2),
            child: Text(number,
                style: TextStyle(
                    color: themeColor,
                    fontSize: 12,
                    fontWeight: FontWeight.bold))),
        const SizedBox(width: 12),
        Expanded(
            child: Text(text,
                style: const TextStyle(color: Colors.white, fontSize: 14))),
      ],
    );
  }

  void _showRestaurantSelection() async {
    final sid = _prefs.schoolId;
    setState(() => _vendorBarTapped = true);

    // 🔥 FIX: Trap State Users and show "Coming Soon" immediately
    if (sid != null && sid.startsWith('STATE_')) {
      showModalBottomSheet(
          context: context,
          backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
          shape: const RoundedRectangleBorder(
              borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
          builder: (ctx) {
            return SizedBox(
              height: 350,
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.storefront,
                        color: Colors.white24, size: 80),
                    const SizedBox(height: 16),
                    const Text("State Vendors Coming Soon! 🚀",
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text("We're expanding food delivery to states soon.",
                        style: TextStyle(color: Colors.white54, fontSize: 14)),
                  ],
                ),
              ),
            );
          });
      return;
    }

    if (sid != null && sid.isNotEmpty) {
      List<dynamic> vendors = [];
      String? errorMsg;
      try {
        vendors = await ApiService.fetchVendors(sid);
        _restaurants = vendors
            .map<String>((v) => v['name'] as String? ?? "Unnamed Vendor")
            .toList();
      } catch (e) {
        errorMsg = "error";
      }

      if (!mounted) return;

      if (errorMsg != null || _restaurants.isEmpty) {
        showModalBottomSheet(
            context: context,
            backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
            shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
            builder: (ctx) {
              final assetPath = errorMsg != null
                  ? 'assets/images/no_internet.jpg'
                  : 'assets/images/coming_soon.jpg';
              return SizedBox(
                height: 350,
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: Image.asset(
                      assetPath,
                      width: 220,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) => Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                            color: Colors.grey[900],
                            borderRadius: BorderRadius.circular(24)),
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.image_not_supported,
                                  color: Colors.white24, size: 50),
                              const SizedBox(height: 12),
                              Text(assetPath.split('/').last,
                                  style: const TextStyle(
                                      color: Colors.white54, fontSize: 12))
                            ]),
                      ),
                    ),
                  ),
                ),
              );
            });
        return;
      }

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (sheetContext) => _buildVendorPicker(sheetContext),
      );
    } else {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        builder: (sheetContext) => _buildSelectSchoolPrompt(sheetContext),
      );
    }
  }

  Widget _buildVendorPicker(BuildContext modalContext) {
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      builder: (BuildContext draggableSheetContext,
          ScrollController scrollController) {
        return StatefulBuilder(
            builder: (BuildContext context, StateSetter modalSetState) {
          return Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Column(
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text("Select Vendors",
                      style: TextStyle(
                          fontFamily: 'Montserrat',
                          color: themeColor,
                          fontSize: 20,
                          fontWeight: FontWeight.bold)),
                ),
                Expanded(
                  child: ListView.builder(
                      controller: scrollController,
                      itemCount: _restaurants.length + 1,
                      itemBuilder: (ctx, i) {
                        if (i == 0) {
                          return CheckboxListTile(
                            title: Text("Select all vendors",
                                style: TextStyle(
                                    fontFamily: 'Montserrat',
                                    fontSize: 16,
                                    color: textColor)),
                            value: _selectAll,
                            onChanged: (v) {
                              modalSetState(() {
                                _selectAll = v!;
                                if (_selectAll) {
                                  _selectedRestaurants =
                                      List.from(_restaurants);
                                } else {
                                  _selectedRestaurants.clear();
                                }
                              });
                              setState(() {});
                            },
                            activeColor: themeColor,
                            checkColor: Colors.white,
                          );
                        }
                        final r = _restaurants[i - 1];
                        return CheckboxListTile(
                          title: Text(r,
                              style: TextStyle(
                                  fontFamily: 'Montserrat',
                                  fontSize: 16,
                                  color: textColor)),
                          value: _selectedRestaurants.contains(r),
                          onChanged: (v) {
                            modalSetState(() {
                              if (v!) {
                                _selectedRestaurants.add(r);
                              } else {
                                _selectedRestaurants.remove(r);
                              }
                              _selectAll = _selectedRestaurants.length ==
                                  _restaurants.length;
                            });
                            setState(() {});
                          },
                          activeColor: themeColor,
                          checkColor: Colors.white,
                        );
                      }),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => Navigator.pop(modalContext),
                      child: Text("Done",
                          style: TextStyle(
                              fontFamily: 'Montserrat', color: themeColor)),
                    ),
                  ),
                ),
              ],
            ),
          );
        });
      },
    );
  }

  Widget _buildSelectSchoolPrompt(BuildContext modalContext) {
    final textColor = _isDarkMode ? Colors.white : Colors.black87;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.4,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      builder: (BuildContext draggableSheetContext,
          ScrollController scrollController) {
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: ListView(
            controller: scrollController,
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text("Select Restaurant",
                    style: TextStyle(
                        fontFamily: 'Montserrat',
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: textColor)),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text("Please select a school at the top right corner.",
                    style: TextStyle(
                        fontFamily: 'Montserrat',
                        fontSize: 16,
                        color: textColor)),
              ),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.pop(modalContext),
                    child: Text("Ok",
                        style: TextStyle(
                            fontFamily: 'Montserrat', color: textColor)),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCircularTab(Map<String, dynamic> tab) {
    return InkWell(
      borderRadius: BorderRadius.circular(30),
      onTap: () {
        if (tab["label"] == "Favorites") {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => FavoritesScreen(userPreferences: _prefs)));
        } else if (tab["label"] == "Tickets") {
          Navigator.push(
              context, MaterialPageRoute(builder: (_) => const TicketScreen()));
        } else if (tab["label"] == "Order") {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (_) => OrderScreen(userPreferences: _prefs)));
        } else if (tab["label"] == "Library") {
          // 🔥 NEW: Navigates to the Library Screen!
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => LibraryScreen(userPreferences: _prefs),
            ),
          );
        }
      },
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
            color: (tab["color"] as Color).withOpacity(0.65),
            shape: BoxShape.circle),
        child: Center(
            child:
                Icon(tab["icon"] as IconData?, color: Colors.white, size: 24)),
      ),
    );
  }

  // ── NEW: Sticky Gist Filter Bar (used by the SliverPersistentHeader) ──
  Widget _buildGistFilterBar() {
    final String label = _isGistsLoading ? "Loading..." : _gistFilter;
    final horizontalBarWidth = MediaQuery.sizeOf(context).width * 0.85;

    return GestureDetector(
      onTap: _showGistFilterSheet,
      child: Container(
        width: horizontalBarWidth, // 🔥 Full width restored
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
            color: Colors.grey[800], borderRadius: BorderRadius.circular(25)),
        child: Row(
          children: [
            Icon(BoxIcons.bxs_megaphone, color: themeColor, size: 20),
            const SizedBox(width: 8),
            Expanded(
                child: Text(label,
                    style: const TextStyle(
                        color: Color(0xFF4CAF50),
                        fontWeight: FontWeight.bold))),
            Icon(Icons.keyboard_arrow_down, color: themeColor, size: 24),
          ],
        ),
      ),
    );
  }

  void _showGistFilterSheet() async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;

    final profile = await supabase
        .from('profiles')
        .select('muted_categories')
        .eq('id', myId)
        .maybeSingle();
    List<String> mutedCats = profile?['muted_categories'] != null
        ? List<String>.from(profile!['muted_categories'])
        : [];

    final categories = [
      'Moments & Gists',
      'Just Gists',
      'Sports',
      'Entertainment',
      'Official',
      'Religion',
      'Random',
      'Tech'
    ];
    final notificableCats = [
      'Sports',
      'Entertainment',
      'Official',
      'Religion',
      'Random',
      'Tech'
    ];

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        expand: false,
        builder: (_, controller) => StatefulBuilder(
          builder: (ctx, setSheetState) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Filter & Alerts',
                    style: TextStyle(
                        color: themeColor,
                        fontSize: 20,
                        fontWeight: FontWeight.bold)),
              ),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  itemCount: categories.length,
                  itemBuilder: (_, i) {
                    final cat = categories[i];
                    final isMuted = mutedCats.contains(cat);
                    final canMute = notificableCats.contains(cat);

                    return ListTile(
                      leading: Radio<String>(
                        value: cat,
                        groupValue: _gistFilter,
                        activeColor: themeColor,
                        onChanged: (val) {
                          setState(() => _gistFilter = val!);
                          _handleRefresh();
                          Navigator.pop(context);
                        },
                      ),
                      title: Text(cat,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 18)),
                      trailing: canMute
                          ? IconButton(
                              icon: Icon(
                                  isMuted
                                      ? Icons.notifications_off
                                      : Icons.notifications_active,
                                  color:
                                      isMuted ? Colors.redAccent : themeColor),
                              onPressed: () async {
                                setSheetState(() {
                                  if (isMuted)
                                    mutedCats.remove(cat);
                                  else
                                    mutedCats.add(cat);
                                });
                                await supabase
                                    .from('profiles')
                                    .update({'muted_categories': mutedCats}).eq(
                                        'id', myId);
                                _handleRefresh(); // Refresh feed immediately behind the scenes
                              },
                            )
                          : null,
                      onTap: () {
                        setState(() => _gistFilter = cat);
                        _handleRefresh();
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showCommentsSheet(String gistId) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => GistCommentsSheet(
        gistId: gistId,
        themeColor: themeColor,
        userPreferences: _prefs,
      ),
    );
  }

  Future<void> _showMomentCommentsSheet(String momentId) async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111111),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) => MomentCommentsSheet(
        momentId: momentId,
        themeColor: themeColor,
      ),
    );
  }

  // ... (Keep your _downloadGistImage, _pickMemoryFlow, build, etc. as they are)

  // Helper method to download the image
  Future<void> _downloadGistImage(String imageUrl) async {
    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final request = await Gal.requestAccess();
        if (!request) return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Downloading to gallery...')),
      );

      // Download the network image to a temporary local file
      final file = await DefaultCacheManager().getSingleFile(imageUrl);

      // Save the local file to the gallery
      await Gal.putImage(file.path);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Saved to Gallery/Photos!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('❌ Could not save image.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _pickMemoryFlow(BuildContext context) async {
    // === 1. WEB IMPLEMENTATION ===
    if (kIsWeb) {
      final picker = ImagePicker();
      final XFile? pickedFile = await picker.pickMedia();

      if (pickedFile != null && mounted) {
        final isVideo = pickedFile.mimeType?.startsWith('video/') == true ||
            pickedFile.name.toLowerCase().endsWith('.mp4') ||
            pickedFile.name.toLowerCase().endsWith('.mov');

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MediaEditorScreen(
              file: pickedFile,
              isVideo: isVideo,
              userPreferences: _prefs,
            ),
          ),
        );
      }
      return;
    }

    // === 2. MOBILE IMPLEMENTATION ===
    final List<AssetEntity>? result = await AssetPicker.pickAssets(
      context,
      pickerConfig: AssetPickerConfig(
        maxAssets: 1,
        requestType: RequestType.common,
        themeColor: themeColor,
        specialItemPosition: SpecialItemPosition.prepend,
        specialItemBuilder: (context, _, __) {
          return GestureDetector(
            onTap: () async {
              final AssetEntity? cameraResult =
                  await CameraPicker.pickFromCamera(
                context,
                pickerConfig: const CameraPickerConfig(
                  enableRecording: true,
                  onlyEnableRecording: false,
                  enableAudio: true,
                ),
              );
              if (cameraResult != null) {
                if (mounted) Navigator.pop(context);
                final file = await cameraResult.file;
                if (file != null && mounted) {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MediaEditorScreen(
                        file: XFile(file.path),
                        isVideo: cameraResult.type == AssetType.video,
                        userPreferences: _prefs,
                      ),
                    ),
                  );
                }
              }
            },
            child: const Center(
              child: Icon(Icons.camera_alt, size: 42, color: Colors.grey),
            ),
          );
        },
      ),
    );

    if (result != null && result.isNotEmpty) {
      final file = await result.first.file;
      if (file != null && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => MediaEditorScreen(
              file: XFile(file.path),
              isVideo: result.first.type == AssetType.video,
              userPreferences: _prefs,
            ),
          ),
        );
      }
    }
  }

  // --- UPDATED: LISTENS FOR CHATS AND REAL-TIME GISTS ---
  void _setupGlobalChatListener() {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;

    _globalChatChannel = supabase.channel('global-app-events');

    _globalChatChannel!.onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'messages',
        callback: (payload) async {
          final newMsg = payload.newRecord;
          final senderId = newMsg['sender_id'];
          final chatId = newMsg['chat_id'];

          if (senderId != myId && chatId != activeChatId) {
            final senderData = await supabase
                .from('profiles')
                .select('username, avatar_url')
                .eq('id', senderId)
                .maybeSingle();
            final senderName = senderData?['username'] ?? 'Someone';
            final avatarUrl = senderData?['avatar_url'] ?? '';
            _showInAppNotification(
                senderName, newMsg['content'] ?? '📷 Media', avatarUrl);
          }
        });

    // 🔥 FIX: new gists still refresh the feed, but debounced — several
    // posts landing in quick succession now coalesce into ONE reload
    // instead of one full feed wipe-and-refetch per post.
    _globalChatChannel!.onPostgresChanges(
        event: PostgresChangeEvent.insert,
        schema: 'public',
        table: 'gists',
        callback: (_) => _scheduleDebouncedRefresh());

    // 🔥 REMOVED: gist_likes / gist_comments / poll_votes listeners.
    // Those tables broadcast to every connected client with no filter,
    // and each one was nuking your whole feed. Your own likes/comments
    // already update instantly via optimistic UI (_toggleLike). Other
    // people's now catch up next time you naturally refresh instead of
    // forcing a reload continuously in the background.

    _globalChatChannel!.subscribe();
  }

  void _scheduleDebouncedRefresh() {
    _feedRefreshDebounce?.cancel();
    _feedRefreshDebounce = Timer(const Duration(seconds: 4), () {
      if (mounted) _handleRefresh();
    });
  }

  // --- UPDATED: BUILD METHOD WITH WHATSAPP LOADING SCREEN ---
  @override
  Widget build(BuildContext context) {
    final Color bgColor =
        _isDarkMode ? const Color(0xFF121212) : Colors.grey[100]!;

    return Theme(
      data: _isDarkMode
          ? ThemeData.dark().copyWith(scaffoldBackgroundColor: bgColor)
          : ThemeData.light().copyWith(scaffoldBackgroundColor: bgColor),
      child: Stack(
        children: [
          Scaffold(
            appBar: _selectedIndex == 0 ? _buildAppBar() : null,
            bottomNavigationBar: _buildCustomFooter(bgColor),
            floatingActionButton: FloatingActionButton(
              heroTag: 'universal_plus_btn',
              backgroundColor: themeColor,
              elevation: 4,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              onPressed: () => _showUniversalPlusMenu(context),
              child: const Icon(Icons.add, color: Colors.white, size: 32),
            ),
            body: SafeArea(
              child: Stack(
                children: [
                  IndexedStack(
                    index: _selectedIndex,
                    children: [
                      RefreshIndicator(
                        color: themeColor,
                        onRefresh: _handleRefresh,
                        child: CustomScrollView(
                          controller: _scrollController,
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.only(
                                    left: 16, top: 20, right: 16, bottom: 8),
                                child: Column(
                                  children: [
                                    GestureDetector(
                                      onTap: () {
                                        setState(() => _vendorBarTapped = true);
                                        _showRestaurantSelection();
                                      },
                                      child: Container(
                                        width:
                                            MediaQuery.sizeOf(context).width *
                                                0.85,
                                        height: 44,
                                        decoration: BoxDecoration(
                                            color: const Color(0xFF1E1E1E),
                                            borderRadius:
                                                BorderRadius.circular(25)),
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 16),
                                        child: Row(children: [
                                          Icon(BoxIcons.bxs_store,
                                              color: themeColor, size: 20),
                                          const SizedBox(width: 8),
                                          Expanded(
                                              child: _selectedRestaurants
                                                      .isNotEmpty
                                                  ? SingleChildScrollView(
                                                      scrollDirection:
                                                          Axis.horizontal,
                                                      child: Row(
                                                          children: _selectedRestaurants
                                                              .map((v) => Padding(
                                                                  padding:
                                                                      const EdgeInsets.only(
                                                                          right:
                                                                              12),
                                                                  child: Chip(
                                                                      label: Text(
                                                                          v,
                                                                          style: const TextStyle(
                                                                              fontSize: 12.6,
                                                                              color: Colors.white)),
                                                                      backgroundColor: const Color(0xFF2A2A2A))))
                                                              .toList()))
                                                  : const Text("Select Vendor", style: TextStyle(fontSize: 15.4, color: Colors.white54))),
                                          !_vendorBarTapped
                                              ? Icon(BoxIcons.bxs_chevron_down,
                                                  color: themeColor, size: 22)
                                              : const SizedBox(),
                                        ]),
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                    Container(
                                      width: MediaQuery.sizeOf(context).width *
                                          0.85,
                                      height: 44,
                                      decoration: BoxDecoration(
                                          color: const Color(0xFF1E1E1E),
                                          borderRadius:
                                              BorderRadius.circular(25)),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 16),
                                      child: Row(children: [
                                        Icon(BoxIcons.bxs_dollar_circle,
                                            color: themeColor, size: 20),
                                        const SizedBox(width: 8),
                                        Expanded(
                                            child: TextField(
                                                controller: _budgetController,
                                                focusNode: _budgetFocusNode,
                                                keyboardType:
                                                    TextInputType.number,
                                                style: const TextStyle(
                                                    fontSize: 12.6,
                                                    color: Colors.white),
                                                decoration:
                                                    const InputDecoration(
                                                        hintText:
                                                            "Enter Budget",
                                                        hintStyle: TextStyle(
                                                            color:
                                                                Colors.white54,
                                                            fontSize: 15.4),
                                                        border:
                                                            InputBorder.none))),
                                        InkWell(
                                            onTap: () => Navigator.push(
                                                context,
                                                MaterialPageRoute(
                                                    builder: (_) =>
                                                        AvailableOptionsScreen(
                                                            userPreferences:
                                                                _prefs,
                                                            selectedRestaurants:
                                                                _selectedRestaurants))),
                                            child: Container(
                                                decoration: BoxDecoration(
                                                    color: themeColor,
                                                    shape: BoxShape.circle),
                                                padding:
                                                    const EdgeInsets.all(6),
                                                child: const Icon(
                                                    BoxIcons.bxs_chevron_right,
                                                    color: Colors.white,
                                                    size: 22))),
                                      ]),
                                    ),
                                    const SizedBox(height: 12),
                                    SizedBox(
                                      width: MediaQuery.sizeOf(context).width *
                                          0.85,
                                      height: 60,
                                      child: Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: _colorfulTabs
                                            .map(
                                                (tab) => _buildCircularTab(tab))
                                            .toList(),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            SliverPersistentHeader(
                              pinned: true,
                              delegate: _GistBarHeaderDelegate(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _buildGistFilterBar(),
                                    const SizedBox(height: 10),
                                    StoriesBar(
                                        key: _storiesBarKey,
                                        userPreferences:
                                            widget.userPreferences ?? _prefs),
                                  ],
                                ),
                              ),
                            ),
                            _buildGistSlideshow(),
                          ],
                        ),
                      ),
                      ExploreScreen(userPreferences: _prefs),
                      ChatListScreen(userPreferences: _prefs),
                      ProfileScreen(
                          userPreferences: _prefs,
                          onSave: () => setState(() => _selectedIndex = 0)),
                    ],
                  ),
                  if (_selectedIndex == 0)
                    Positioned(
                      bottom: 20,
                      left: 0,
                      right: 0,
                      child: ValueListenableBuilder<bool>(
                        valueListenable: _showBackToTopButton,
                        builder: (context, show, child) {
                          if (!show) return const SizedBox.shrink();
                          return Center(
                            child: Opacity(
                              opacity: 0.5,
                              child: GestureDetector(
                                onTap: () => _scrollController.animateTo(0,
                                    duration: const Duration(milliseconds: 600),
                                    curve: Curves.easeInOut),
                                child: Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                        color: themeColor,
                                        shape: BoxShape.circle),
                                    child: const Icon(Icons.arrow_upward,
                                        color: Colors.white, size: 28)),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 🔥 SYNC SCREEN COMPLETELY REMOVED! YOU GO STRAIGHT IN!
        ],
      ),
    );
  }

  // --- UPDATED: REAL-TIME NOTIFICATION BADGE ---
  PreferredSizeWidget _buildAppBar() {
    // 🔥 FIX: Safe detection of State IDs
    final isPublicMode = _prefs.schoolId?.startsWith('STATE_') == true;
    final hasLocation = _prefs.schoolId?.isNotEmpty == true;
    final myId = supabase.auth.currentUser?.id ?? '';

    return AppBar(
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: _isDarkMode ? const Color(0xFF121212) : Colors.grey[100],
      elevation: 0,
      centerTitle: true,
      leading: StreamBuilder<List<Map<String, dynamic>>>(
        stream: myId.isEmpty
            ? const Stream.empty()
            : supabase
                .from('notifications')
                .stream(primaryKey: ['id']).eq('user_id', myId),
        builder: (context, snapshot) {
          final unreadCount =
              snapshot.data?.where((n) => n['read'] == false).length ?? 0;
          return IconButton(
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications, size: 36),
                if (unreadCount > 0)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: const BoxDecoration(
                          color: Colors.redAccent, shape: BoxShape.circle),
                      child: Text(
                        unreadCount > 9 ? '9+' : unreadCount.toString(),
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
              ],
            ),
            onPressed: _showNotifications,
          );
        },
      ),
      title: Image.asset('assets/images/allowance_logo.png',
          height: 200, width: 200, fit: BoxFit.contain),
      actions: [
        IconButton(
          icon: Icon(isPublicMode ? Icons.public : BoxIcons.bxs_map,
              size: isPublicMode ? 32 : 36),
          color: hasLocation
              ? (isPublicMode ? Colors.blueAccent : themeColor)
              : (_isDarkMode ? Colors.white54 : Colors.black54),
          onPressed: _chooseUniversity,
        )
      ],
    );
  }

  // --- UPDATED: HYPER-RESPONSIVE TASKBAR ---
  Widget _buildCustomFooter(Color screenBgColor) {
    final icons = [
      BoxIcons.bxs_home,
      Icons.explore_outlined,
      CupertinoIcons.chat_bubble_2_fill,
      BoxIcons.bxs_user
    ];
    final acts = [
      () => setState(() => _selectedIndex = 0),
      () => setState(() => _selectedIndex = 1),
      () => setState(() => _selectedIndex = 2),
      () => setState(() => _selectedIndex = 3)
    ];

    // 🔥 FIX: Added SafeArea to stop taskbar collision!
    return SafeArea(
      bottom: true,
      child: Container(
        height: 56,
        decoration: BoxDecoration(
            color: const Color(0xFF121212),
            border:
                Border(top: BorderSide(color: Colors.white.withOpacity(0.05)))),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: List.generate(icons.length, (i) {
            final sel = _selectedIndex == i;
            final isProfileTab = i == 3;
            final isChatTab = i == 2;

            Widget iconWidget;
            if (isProfileTab &&
                _prefs.avatarUrl != null &&
                _prefs.avatarUrl!.isNotEmpty) {
              iconWidget = Container(
                padding: EdgeInsets.all(sel ? 2 : 0),
                decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border:
                        sel ? Border.all(color: themeColor, width: 2) : null),
                child: CircleAvatar(
                    radius: 13,
                    backgroundColor: const Color(0xFF1E1E1E),
                    backgroundImage: NetworkImage(_prefs.avatarUrl!)),
              );
            } else if (isChatTab) {
              iconWidget = StreamBuilder<List<Map<String, dynamic>>>(
                stream: supabase.auth.currentUser == null
                    ? const Stream.empty()
                    : supabase
                        .from('messages')
                        .stream(primaryKey: ['id']).eq('is_read', false),
                builder: (context, snapshot) {
                  final myId = supabase.auth.currentUser?.id;
                  final allUnread = snapshot.data ?? [];
                  final unreadCount =
                      allUnread.where((msg) => msg['sender_id'] != myId).length;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Icon(icons[i],
                          size: 26, color: sel ? themeColor : Colors.white54),
                      if (unreadCount > 0)
                        Positioned(
                            top: -4,
                            right: -6,
                            child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(
                                    color: Colors.redAccent,
                                    shape: BoxShape.circle),
                                child: Text(
                                    unreadCount > 99
                                        ? '99+'
                                        : unreadCount.toString(),
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold)))),
                    ],
                  );
                },
              );
            } else {
              iconWidget = Icon(icons[i],
                  size: 28, color: sel ? themeColor : Colors.white54);
            }

            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: acts[i],
              child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  child: iconWidget),
            );
          }),
        ),
      ),
    );
  }

  // NEW: method to fetch notifications for current user
  // --- REPLACED: Fetch Notifications (Much cleaner now!) ---
  Future<List<Map<String, dynamic>>> _fetchNotifications() async {
    try {
      final user = supabase.auth.currentUser;
      if (user == null) return [];

      final resp = await supabase
          .from('notifications')
          .select()
          .eq('user_id', user.id)
          .order('sent_at', ascending: false)
          .limit(50);

      final List<Map<String, dynamic>> result = [];
      for (var notif in resp) {
        final data = notif['data'] as Map<String, dynamic>? ?? {};
        final type = data['type']?.toString() ?? '';
        final gistId = data['gist_id'];

        // Automatically falls back through all image possibilities
        String? avatarUrl = data['avatar_url']?.toString() ??
            data['sender_avatar']?.toString() ??
            data['photo_url']?.toString();
        String? username =
            data['username']?.toString() ?? data['sender_username']?.toString();
        bool isNewTicket = false;

        // Fetch Gist author if missing
        if (gistId != null && avatarUrl == null) {
          try {
            final gist = await supabase
                .from('gists')
                .select('profiles:user_id (username, avatar_url)')
                .eq('id', gistId)
                .single();
            final profile = gist['profiles'];
            if (profile is Map) {
              avatarUrl = profile['avatar_url'] as String?;
              username = profile['username'] as String?;
            }
          } catch (_) {}
        } else if (type == 'ticket' ||
            (notif['title']?.toString() ?? '')
                .contains('New Ticket Available')) {
          isNewTicket = true;
          username = 'Allowance';
        }

        notif['avatar_url'] = avatarUrl;
        notif['username'] = username;
        notif['isNewTicket'] = isNewTicket;
        result.add(notif);
      }
      return result;
    } catch (e) {
      developer.log('Error fetching notifications: $e', name: 'notifications');
      return [];
    }
  }

  // --- REPLACED: Show Notifications Bottom Sheet (Added routing logic!) ---
  // --- UPDATED: CLEARS ALL NOTIFICATIONS INSTANTLY WHEN OPENED ---
  void _showNotifications() async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;

    // 🔥 INSTANTLY MARK ALL AS READ SO THE BELL NUMBER DISAPPEARS IMMEDIATELY
    supabase
        .from('notifications')
        .update({'read': true})
        .eq('user_id', myId)
        .eq('read', false)
        .then((_) {});

    final notifications = await _fetchNotifications();
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetContext) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        builder: (_, scrollController) => Container(
          decoration: BoxDecoration(
            color: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                child: Text('Notifications',
                    style: TextStyle(
                        fontFamily: 'Montserrat',
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: themeColor)),
              ),
              Expanded(
                child: notifications.isEmpty
                    ? Center(
                        child: Text('No notifications yet.',
                            style: TextStyle(
                                color:
                                    _isDarkMode ? Colors.white : Colors.black)))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: notifications.length,
                        itemBuilder: (ctx, i) {
                          final notif = notifications[i];
                          final title = notif['title'] ?? 'Notification';
                          final body = notif['body'] ?? '';
                          final data = notif['data'] ?? {};
                          final type = data['type']?.toString();

                          final gistId = data['gist_id']?.toString();
                          final ticketId = data['ticket_id']?.toString();
                          final followerId = data['follower_id']?.toString();
                          final senderId = data['sender_id']?.toString();

                          final String? displayImage =
                              notif['avatar_url'] as String?;
                          final String? username = notif['username'] as String?;
                          final bool isNewTicket =
                              notif['isNewTicket'] as bool? ?? false;

                          return ListTile(
                            leading: isNewTicket
                                ? CircleAvatar(
                                    radius: 22,
                                    backgroundColor: const Color(0xFF4CAF50),
                                    child: const Icon(Icons.confirmation_number,
                                        color: Colors.white, size: 26))
                                : CircleAvatar(
                                    radius: 22,
                                    backgroundColor: Colors.grey[700],
                                    backgroundImage: (displayImage != null &&
                                            displayImage.isNotEmpty)
                                        ? NetworkImage(displayImage)
                                        : null,
                                    child: (displayImage == null ||
                                            displayImage.isEmpty)
                                        ? Text(
                                            username?.isNotEmpty == true
                                                ? username![0].toUpperCase()
                                                : '?',
                                            style: const TextStyle(
                                                fontSize: 18,
                                                color: Colors.white))
                                        : null,
                                  ),
                            title: Text(title,
                                style: TextStyle(
                                    color: _isDarkMode
                                        ? Colors.white
                                        : Colors.black,
                                    fontWeight: FontWeight.w600)),
                            subtitle: Text(body,
                                style: TextStyle(
                                    color: _isDarkMode
                                        ? Colors.white70
                                        : Colors.grey[700])),
                            onTap: () async {
                              if (gistId != null) {
                                Navigator.pushNamed(context, '/gist',
                                    arguments: {'id': gistId});
                              } else if (ticketId != null) {
                                Navigator.pushNamed(context, '/ticket',
                                    arguments: {'id': ticketId});
                              } else if (type == 'follow' &&
                                  followerId != null) {
                                Navigator.pop(sheetContext);
                                UniversalProfileCard.show(
                                    context, followerId, _prefs);
                              } else if (type == 'chat') {
                                Navigator.pop(sheetContext);
                                Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => ChatListScreen(
                                            userPreferences: _prefs)));
                              } else if ((type == 'memory' ||
                                      type == 'story') &&
                                  senderId != null) {
                                Navigator.pop(sheetContext);
                                UniversalProfileCard.show(
                                    context, senderId, _prefs);
                              }
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- 1. UNIVERSAL PLUS MENU ---
  void _showUniversalPlusMenu(BuildContext context) {
    final isPlus = _prefs.subscriptionTier == 'Membership';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.8,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => Column(
          children: [
            const SizedBox(height: 12),
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 16),

            // --- FUNCTIONAL SEARCH BAR ---
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: TextField(
                style: const TextStyle(color: Colors.white),
                textInputAction: TextInputAction.search,
                onSubmitted: (query) {
                  if (query.trim().isNotEmpty) {
                    Navigator.pop(ctx);
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ExploreScreen(
                          userPreferences: _prefs,
                          initialQuery: query.trim(),
                        ),
                      ),
                    );
                  }
                },
                decoration: InputDecoration(
                  hintText: 'Search people, gists, tickets...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  prefixIcon: const Icon(Icons.search, color: Colors.white54),
                  filled: true,
                  fillColor: const Color(0xFF121212),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0),
                ),
              ),
            ),
            const SizedBox(height: 16),

            Expanded(
              child: ListView(
                controller: scrollController,
                children: [
                  _buildActionRowItem(
                    icon: Icons.amp_stories,
                    color: Colors.purpleAccent,
                    title: 'Create Story',
                    subtitle: 'Share updates with your campus',
                    onTap: () async {
                      Navigator.pop(ctx);
                      // 🔥 FIX: Free users can now post unlimited stories (duration restricted inside CreateStoryScreen)
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) =>
                                  CreateStoryScreen(userPreferences: _prefs)));
                    },
                  ),
                  _buildActionRowItem(
                    icon: Icons.photo_library,
                    color: Colors.orangeAccent,
                    title: 'Add Moment',
                    subtitle: 'Post memories permanently to your profile',
                    onTap: () async {
                      Navigator.pop(ctx);
                      // LIMIT REMOVED: Everyone can post unlimited moments now!
                      _pickMemoryFlow(context);
                    },
                  ),
                  _buildActionRowItem(
                    icon: BoxIcons.bxs_megaphone,
                    color: Colors.blueAccent,
                    title: 'Gist Us',
                    subtitle: 'Advertise your brand or campus news',
                    onTap: () {
                      Navigator.pop(ctx);
                      Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => GistSubmissionScreen(
                                  themeColor: themeColor,
                                  schoolId: _prefs.schoolId)));
                    },
                  ),
                  _buildActionRowItem(
                    icon: BoxIcons.bxs_coupon,
                    color: Colors.redAccent,
                    title: 'Create Ticket',
                    subtitle: 'Host an event and sell tickets',
                    onTap: () {
                      Navigator.pop(ctx);
                      if (!isPlus) {
                        _showUniversalSubscriptionSheet(
                            customMessage:
                                "Ticketing is an exclusive feature for Allowance Plus members. Upgrade to host events!");
                      } else {
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => TicketSubmissionScreen(
                                    themeColor: themeColor,
                                    schoolId:
                                        int.tryParse(_prefs.schoolId ?? ''))));
                      }
                    },
                  ),
                  _buildActionRowItem(
                    icon: Icons.group_add,
                    color: Colors.tealAccent,
                    title: 'Create Group',
                    subtitle: 'Build a community on campus',
                    onTap: () {
                      Navigator.pop(ctx);
                      if (!isPlus) {
                        _showUniversalSubscriptionSheet(
                            customMessage:
                                "Building campus groups is an exclusive feature for Allowance Plus members.");
                      } else {
                        Navigator.push(
                            context,
                            MaterialPageRoute(
                                builder: (_) => CreateGroupScreen(
                                    userPreferences: _prefs)));
                      }
                    },
                  ),
                  FutureBuilder<Map<String, dynamic>?>(
                      future: supabase
                          .from('referral_leaderboard')
                          .select('total_users, total_subs')
                          .eq('referrer_id',
                              supabase.auth.currentUser?.id ?? '')
                          .maybeSingle(),
                      builder: (context, snapshot) {
                        int u = 0;
                        int s = 0;
                        if (snapshot.hasData && snapshot.data != null) {
                          u = snapshot.data!['total_users'] ?? 0;
                          s = snapshot.data!['total_subs'] ?? 0;
                        }

                        return _buildActionRowItem(
                          icon: Icons.diversity_3,
                          color: Colors.amber,
                          title: 'Referrals',
                          subtitle:
                              'Your code: ${_prefs.username ?? 'Unknown'}\nu: $u, s: $s',
                          onTap: () {
                            Navigator.pop(ctx);
                            _showReferralLeaderboard();
                          },
                        );
                      }),
                ],
              ),
            ),
            const Divider(color: Colors.white10, height: 1),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                  color: Color(0xFF121212),
                  borderRadius:
                      BorderRadius.vertical(bottom: Radius.circular(24))),
              child: Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Current Plan',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 12)),
                      Text(isPlus ? 'Allowance Plus ✨' : 'Free Tier',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const Spacer(),
                  if (!isPlus)
                    ElevatedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showUniversalSubscriptionSheet();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: themeColor,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20)),
                      ),
                      child: const Text('Upgrade',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    )
                  else
                    Container(
                      decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08),
                          shape: BoxShape.circle),
                      child: IconButton(
                        icon: const Icon(Icons.more_vert, color: Colors.white),
                        tooltip: 'Manage Subscription',
                        onPressed: () {
                          Navigator.pop(ctx);
                          _confirmCancelSubscription();
                        },
                      ),
                    )
                ],
              ),
            )
          ],
        ),
      ),
    );
  }

  // --- 3. UNIVERSAL SUBSCRIPTION POPUP (OVERFLOW FIXED) ---
  void _showUniversalSubscriptionSheet({String? customMessage}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
        return SingleChildScrollView(
          // 🔥 FIX 2: Wrapped in SingleChildScrollView to prevent pixel overflow
          child: Padding(
            padding: EdgeInsets.only(
              left: 24.0,
              right: 24.0,
              top: 24.0,
              bottom: MediaQuery.viewInsetsOf(context).bottom +
                  24.0, // Safe padding for bottom
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                    child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(2)))),
                const SizedBox(height: 24),
                const Text('Upgrade to Plus ✨',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),

                if (customMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                        color: Colors.orangeAccent.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orangeAccent)),
                    child: Text(customMessage,
                        style: const TextStyle(
                            color: Colors.orangeAccent,
                            fontWeight: FontWeight.bold)),
                  )
                else
                  const Text(
                      'Unlock the full university cheat code and remove all limits.',
                      style: TextStyle(color: Colors.white70, fontSize: 14)),

                const SizedBox(height: 16),
                _buildPerkRow(Icons.delivery_dining,
                    'Massively discounted delivery rates'),
                _buildPerkRow(
                    Icons.timer, 'Book unavailable delivery agents in advance'),
                _buildPerkRow(
                    Icons.amp_stories, 'Post Stories that last up to 10 days'),
                _buildPerkRow(Icons.photo_library,
                    'Post unlimited Moments (Free max is 3)'),
                _buildPerkRow(Icons.history,
                    'Save & Backup Chats (Free chats delete in 24h)'),
                _buildPerkRow(Icons.group_add, 'Create custom Campus Groups'),
                _buildPerkRow(Icons.airplane_ticket,
                    'Create & Sell Tickets for events'), // Updated Icon

                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _isProcessingSubscription
                        ? null
                        : () => _subscribeToMembership(context, setModalState),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF4CAF50),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16))),
                    child: _isProcessingSubscription
                        ? const CircularProgressIndicator(color: Colors.black)
                        : const Text('Subscribe - ₦700/mo',
                            style: TextStyle(
                                color: Colors.black,
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        );
      }),
    );
  }

  // --- NEW: REFERRAL LEADERBOARD ---
  void _showReferralLeaderboard() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121212),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        int localSegment = 0;
        return StatefulBuilder(
            builder: (BuildContext context, StateSetter setModalState) {
          return DraggableScrollableSheet(
            initialChildSize: 0.85,
            minChildSize: 0.5,
            maxChildSize: 0.95,
            expand: false,
            builder: (_, scrollController) => Column(
              children: [
                const SizedBox(height: 12),
                Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                        color: Colors.white24,
                        borderRadius: BorderRadius.circular(2))),
                const SizedBox(height: 16),
                const Text('LEADERBOARD 🏆',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5)),
                const SizedBox(height: 4),
                // 🔥 FIX: Removed null-aware operator to fix compiler warning
                Text('Your Code: ${_prefs.username}',
                    style: TextStyle(
                        color: themeColor,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),

                ElevatedButton.icon(
                    icon: const Icon(Icons.share, color: Colors.black),
                    label: const Text('Share Referral Link',
                        style: TextStyle(
                            color: Colors.black, fontWeight: FontWeight.bold)),
                    style: ElevatedButton.styleFrom(
                        backgroundColor: themeColor,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12))),
                    onPressed: () {
                      // 🔥 FIX: Removed null-aware operator here too
                      Share.share(
                          'Join Allowance! Use my referral code: ${_prefs.username} or click here: https://allowanceapp.org/join?ref=${_prefs.username}');
                    }),
                const SizedBox(height: 16),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 60),
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white10)),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setModalState(() => localSegment = 0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              decoration: BoxDecoration(
                                  color: localSegment == 0
                                      ? themeColor
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8)),
                              child: Text("Users",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: localSegment == 0
                                          ? Colors.black
                                          : Colors.white54,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13.5)),
                            ),
                          ),
                        ),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setModalState(() => localSegment = 1),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              decoration: BoxDecoration(
                                  color: localSegment == 1
                                      ? themeColor
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(8)),
                              child: Text("Subscribers",
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      color: localSegment == 1
                                          ? Colors.black
                                          : Colors.white54,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13.5)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Expanded(
                  child: FutureBuilder<List<dynamic>>(
                    future: supabase
                        .from('referral_leaderboard')
                        .select()
                        .order(localSegment == 0 ? 'total_users' : 'total_subs',
                            ascending: false)
                        .limit(50),
                    builder: (context, snapshot) {
                      if (snapshot.connectionState == ConnectionState.waiting)
                        return Center(
                            child:
                                CircularProgressIndicator(color: themeColor));
                      final data = snapshot.data ?? [];
                      final filteredData = data.where((r) {
                        final count = localSegment == 0
                            ? (r['total_users'] ?? 0)
                            : (r['total_subs'] ?? 0);
                        return count > 0;
                      }).toList();

                      if (filteredData.isEmpty)
                        return const Center(
                            child: Text('No referrals yet on the leaderboard.',
                                style: TextStyle(color: Colors.white54)));

                      return ListView.builder(
                        controller: scrollController,
                        itemCount: filteredData.length,
                        itemBuilder: (context, index) {
                          final row = filteredData[index];
                          final username =
                              row['referrer_username'] ?? 'Unknown';
                          final avatarUrl = row['referrer_avatar_url'];
                          final count = localSegment == 0
                              ? row['total_users']
                              : row['total_subs'];
                          final dateRaw = row['first_referral_date'];
                          final dateFormatted = dateRaw != null
                              ? DateFormat('d MMMM')
                                  .format(DateTime.parse(dateRaw))
                              : 'Unknown';

                          String prefix = '${index + 1}.';
                          if (index == 0)
                            prefix = '🥇';
                          else if (index == 1)
                            prefix = '🥈';
                          else if (index == 2) prefix = '🥉';

                          return ListTile(
                            leading: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(prefix,
                                    style: const TextStyle(fontSize: 22)),
                                const SizedBox(width: 8),
                                CircleAvatar(
                                  radius: 18,
                                  backgroundColor: Colors.grey[800],
                                  backgroundImage: avatarUrl != null
                                      ? NetworkImage(avatarUrl)
                                      : null,
                                  child: avatarUrl == null
                                      ? const Icon(Icons.person,
                                          color: Colors.white54, size: 20)
                                      : null,
                                ),
                              ],
                            ),
                            title: Text('@$username',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16)),
                            subtitle: Text(
                                '$count ${localSegment == 0 ? 'users' : 'subs'} since $dateFormatted',
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 12)),
                          );
                        },
                      );
                    },
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: const BoxDecoration(
                      color: Color(0xFF1E1E1E),
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(24))),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('View Rewards & Benefits 🎁',
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.bold)),
                      ElevatedButton(
                        onPressed: () => _showBenefitsSheet(context),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: themeColor,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12))),
                        child: const Text('Show',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      )
                    ],
                  ),
                )
              ],
            ),
          );
        });
      },
    );
  }

  // --- 2. REPLACE: _showBenefitsSheet ---
  void _showBenefitsSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, scrollController) => Padding(
          padding: const EdgeInsets.all(24.0),
          child: ListView(
            controller: scrollController,
            children: [
              const Text('Referral Benefits 🎉',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),

              // --- UPDATED TEXT ---
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: themeColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: themeColor.withOpacity(0.5))),
                child: Column(
                  children: [
                    Text('LTG = Life Time Gist Credits',
                        style: TextStyle(
                            color: themeColor,
                            fontSize: 14,
                            fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center),
                    const SizedBox(height: 4),
                    Text('1m+s = 1 Month Plus Subscription',
                        style: TextStyle(
                            color: themeColor,
                            fontSize: 14,
                            fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
              const SizedBox(height: 32),

              const Text('👥 USER REFERRALS',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const Divider(color: Colors.white24, height: 24),
              _buildBenefitText('10 USERS', '1m+s', '🌱'),
              _buildBenefitText('50 USERS', '20 LTG and 1m+s', '🥉'),
              _buildBenefitText('100 USERS', '50 LTG and 2m+s', '🥈'),
              _buildBenefitText('200 USERS',
                  '100 LTG and 3m+s\n(FIRST TO HIT: 150 LTG and 5m+s)', '🥇'),
              _buildBenefitText('500 USERS',
                  '150 LTG and 5m+s\n(FIRST TO HIT: 300 LTG and 7m+s)', '💎'),
              _buildBenefitText('1000 USERS',
                  '300 LTG and 7m+s\n(FIRST TO HIT: 500 LTG and 1y+s)', '👑'),

              const SizedBox(height: 32),

              const Text('🌟 SUB REFERRALS',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const Divider(color: Colors.white24, height: 24),
              _buildBenefitText('10 SUBS', '1m+s and ₦2k', '💸'),
              _buildBenefitText('50 SUBS', '5m+s and ₦10k', '💰'),
              _buildBenefitText('100 SUBS', '10m+s and ₦20k', '🏦'),
              _buildBenefitText(
                  '200 SUBS',
                  '20m+s and ₦40k\n(FIRST TO HIT: ₦40k EVERY MONTH for a year)',
                  '🏆'),
              _buildBenefitText(
                  '500 SUBS',
                  '50m+s and ₦100k\n(FIRST TO HIT: ₦100k EVERY MONTH for a year)',
                  '🚀'),
              _buildBenefitText(
                  '1000 SUBS',
                  '100m+s and ₦200k\n(FIRST TO HIT: ₦200k EVERY MONTH for a year)',
                  '🐐'),

              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }

  // --- 3. REPLACE: _buildBenefitText ---
  Widget _buildBenefitText(String milestone, String reward, String emoji) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 28)),
            const SizedBox(width: 16),
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 14, height: 1.4),
                  children: [
                    TextSpan(
                        text: '$milestone\n',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            fontSize: 16)),
                    TextSpan(
                        text: reward,
                        style: const TextStyle(
                            color: Color(0xFF4CAF50),
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Helper Widget for the Row-by-Row layout
  Widget _buildActionRowItem(
      {required IconData icon,
      required Color color,
      required String title,
      required String subtitle,
      required VoidCallback onTap}) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 24),
      ),
      title: Text(title,
          style: const TextStyle(
              color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
      subtitle: Text(subtitle,
          style: const TextStyle(color: Colors.white54, fontSize: 13)),
      trailing: const Icon(Icons.chevron_right, color: Colors.white24),
      onTap: onTap,
    );
  }

  // --- 2. CANCEL SUBSCRIPTION DIALOG ---
  Future<void> _confirmCancelSubscription() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text('Cancel Subscription?',
            style: TextStyle(color: Colors.white)),
        content: const Text(
          'Are you sure you want to cancel your Allowance Plus membership? You will lose access to premium features.\n\nNote: To completely stop future card charges, please click the "Manage Subscription" link in your Paystack email receipt.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Keep It', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel Plan',
                style: TextStyle(
                    color: Colors.redAccent, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      final user = supabase.auth.currentUser;
      if (user != null) {
        try {
          await supabase.from('profiles').update({
            'subscription_tier': 'Free',
            'subscription_expires_at': null,
            'updated_at': DateTime.now().toIso8601String(),
          }).eq('id', user.id);

          _prefs.subscriptionTier = 'Free';
          await _prefs.savePreferences();

          if (mounted) {
            setState(() {});
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('Subscription canceled successfully.'),
                  backgroundColor: Colors.green),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                  content: Text('Error canceling subscription: $e'),
                  backgroundColor: Colors.red),
            );
          }
        }
      }
    }
  }

  Widget _buildPerkRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Row(
        children: [
          Icon(icon, color: themeColor, size: 22),
          const SizedBox(width: 12),
          Expanded(
              child: Text(text,
                  style: const TextStyle(color: Colors.white, fontSize: 14))),
        ],
      ),
    );
  }

  // =========================================================================
  // SUBSCRIPTION PAYMENT LOGIC (WITH FAILOVER)
  // =========================================================================

  Future<void> _recoverPendingSubscription() async {
    final prefs = await SharedPreferences.getInstance();
    final pendingJson = prefs.getString('pending_sub_reference');
    if (pendingJson == null) return;

    setState(() => _isProcessingSubscription = true);

    try {
      String reference = '';
      String gateway = 'paystack';
      if (pendingJson.startsWith('{')) {
        final data = jsonDecode(pendingJson);
        reference = data['reference'];
        gateway = data['gateway'] ?? 'paystack';
      } else {
        reference = pendingJson;
      }

      // FIX: Now correctly passes both reference AND gateway!
      final success =
          await _pollAndProcessVerification(reference, gateway, maxAttempts: 1);

      if (success) {
        await prefs.remove('pending_sub_reference');
        if (mounted) {
          setState(() {
            _prefs.subscriptionTier = 'Membership';
          });
          await _prefs.savePreferences();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('✅ Subscription recovered!'),
                backgroundColor: Colors.green),
          );
        }
      }
    } catch (_) {}

    if (mounted) setState(() => _isProcessingSubscription = false);
  }

  // --- 2. SUBSCRIBE TO MEMBERSHIP (FAILOVER LOGIC) ---
  // --- 2. SUBSCRIBE TO MEMBERSHIP (FAILOVER LOGIC) ---
  Future<void> _subscribeToMembership(
      BuildContext context, StateSetter setModalState) async {
    setModalState(() => _isProcessingSubscription = true);
    final user = supabase.auth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please log in.')));
      setModalState(() => _isProcessingSubscription = false);
      return;
    }

    // 🔥 FIX: Embed user.id into reference for webhook safety!
    final reference = 'sub_${user.id}_${DateTime.now().millisecondsSinceEpoch}';
    final int amountNaira = 700;
    String gateway = 'paystack';
    String? authUrlString;

    try {
      // === ATTEMPT PAYSTACK FIRST VIA EDGE FUNCTION ===
      final payResp = await supabase.functions.invoke(
        'paystack-init',
        body: {
          'amount': amountNaira * 100, // Paystack uses Kobo
          'email': user.email ?? 'user@allowance.com',
          'reference': reference,
          'metadata': {
            'plan_code': 'PLN_2tgtzyaurt8qz0d',
            'user_id': user.id,
            'plan_type': 'Membership' // Read by paystack-webhook
          }
        },
      );

      final data =
          payResp.data is String ? jsonDecode(payResp.data) : payResp.data;
      if (payResp.status == 200 && data != null && data['data'] != null) {
        authUrlString = data['data']['authorization_url'];
      } else {
        throw 'Paystack unavailable';
      }
    } catch (e) {
      // === FAILOVER TO FLUTTERWAVE VIA EDGE FUNCTION ===
      debugPrint('Paystack failed. Rerouting to Flutterwave... Error: $e');
      gateway = 'flutterwave';

      try {
        final flwResp = await supabase.functions.invoke(
          'flutterwave-init',
          body: {
            'tx_ref': reference,
            'amount': amountNaira.toString(),
            'currency': 'NGN',
            'redirect_url': 'https://allowanceapp.org',
            'customer': {'email': user.email ?? 'user@allowance.com'},
            'payment_plan': dotenv.env['FLW_PLAN_ID'] ?? '',
            'meta': {'user_id': user.id, 'plan_code': 'Allowance_Plus'},
            'customizations': {
              'title': 'Allowance Plus',
              'description': 'Subscription payment'
            }
          },
        );

        final data =
            flwResp.data is String ? jsonDecode(flwResp.data) : flwResp.data;
        if (flwResp.status == 200 && data != null && data['data'] != null) {
          authUrlString = data['data']['link'];
        } else {
          debugPrint('Flutterwave Error Body: ${flwResp.data}');
          throw 'Flutterwave unavailable';
        }
      } catch (flwErr) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Both payment gateways are currently offline. Try again later.'),
              backgroundColor: Colors.red));
        }
        setModalState(() => _isProcessingSubscription = false);
        return;
      }
    }

    if (authUrlString != null) {
      final Uri url = Uri.parse(authUrlString);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_sub_reference',
          jsonEncode({'reference': reference, 'gateway': gateway}));

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.inAppBrowserView);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Payment opened. Complete it in the browser — we verify automatically...'),
            duration: Duration(seconds: 8)));
      } else {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not launch payment page')));
      }
    }

    final success = await _pollAndProcessVerification(reference, gateway,
        maxAttempts: 30, interval: const Duration(seconds: 4));

    if (success) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('pending_sub_reference');
      setState(() {
        _prefs.subscriptionTier = 'Membership';
      });
      await _prefs.savePreferences();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('✅ Subscription activated!'),
            backgroundColor: Colors.green));
        Navigator.pop(context); // Close the Bottom Sheet!
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Payment taking a while. You can close this; we will check again when you return.'),
            backgroundColor: Colors.orange));
      }
    }
    if (mounted) setModalState(() => _isProcessingSubscription = false);
  }

  // --- 🔥 FIX: Now uses the `verify-payment` Edge Function to guarantee stability! ---
  Future<bool> _pollAndProcessVerification(String reference, String gateway,
      {int maxAttempts = 10,
      Duration interval = const Duration(seconds: 3)}) async {
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final funcResp = await Supabase.instance.client.functions.invoke(
          'verify-payment',
          body: {'reference': reference, 'gateway': gateway},
        );

        final data =
            funcResp.data is String ? jsonDecode(funcResp.data) : funcResp.data;

        if (funcResp.status == 200 && data != null) {
          bool isSuccess = false;

          if (gateway == 'paystack' &&
              data['status'] == true &&
              data['data']?['status'] == 'success') {
            isSuccess = true;
            await _activateSubscriptionDb(
                data['data']['customer']?['customer_code'],
                data['data']['subscription_code']);
          } else if (gateway == 'flutterwave' &&
              data['status'] == 'success' &&
              data['data']?['status'] == 'successful') {
            isSuccess = true;
            await _activateSubscriptionDb('FLW_NATIVE', 'FLW_SUB');
          }

          if (isSuccess) return true;
        }
      } catch (e) {
        debugPrint('Verify transaction error: $e');
      }
      await Future.delayed(interval);
    }
    return false;
  }

  // FIX: This method was missing! It handles the database update
  Future<void> _activateSubscriptionDb(
      String? customerCode, String? subCode) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      await Supabase.instance.client.from('profiles').update({
        'subscription_tier': 'Membership',
        'paystack_customer_code': customerCode,
        'paystack_subscription_id': subCode,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', user.id);

      setState(() {
        _prefs.subscriptionTier = 'Membership';
      });
      await _prefs.savePreferences();
    }
  }

  // Also include the helper for grid buttons
}

// ── NEW: Delegate for sticky Gist Bar ──
class _GistBarHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;

  _GistBarHeaderDelegate({required this.child});

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      color: Theme.of(context)
          .scaffoldBackgroundColor, // Prevents gists from showing behind the bar
      child: Center(
        child: SizedBox(
          width: MediaQuery.sizeOf(context).width,
          child: child,
        ),
      ),
    );
  }

  @override
  double get maxExtent => 160.0;

  @override
  double get minExtent => 160.0;

  @override
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate oldDelegate) =>
      true;
}

class _GistItemCard extends StatefulWidget {
  final Map<String, dynamic> gist;
  final List<dynamic>
      allFeedItems; // 🔥 FIXED: Strongly typed to prevent errors
  final int gistId;
  final VideoPlayerController? videoController;
  final bool isMutedInitial;
  final int likeCount;
  final bool isLiked;
  final VoidCallback onToggleLike;
  final Future<void> Function() onShowComments;
  final Function(String) onDownload;
  final Function(bool) onToggleMute;
  final Color themeColor;
  final UserPreferences prefs;

  const _GistItemCard({
    super.key,
    required this.gist,
    required this.allFeedItems, // 🔥 FIXED: Will stop the compiler error on line 516
    required this.gistId,
    this.videoController,
    required this.isMutedInitial,
    required this.likeCount,
    required this.isLiked,
    required this.onToggleLike,
    required this.onShowComments,
    required this.onDownload,
    required this.onToggleMute,
    required this.themeColor,
    required this.prefs,
  });

  @override
  State<_GistItemCard> createState() => _GistItemCardState();
}

class _GistItemCardState extends State<_GistItemCard>
    with AutomaticKeepAliveClientMixin {
  int _localPageIndex = 0;
  late bool _isMuted;
  int _commentCount = 0;
  bool _isDisposed = false;
  bool _showHeartOverlay = false;
  bool _userPaused = false;

  // 🔥 NEW: Lazy Video Loading Variables
  VideoPlayerController? _localVideoController;
  bool _isVideoInitialized = false;
  bool _isInitializing = false;
  bool _isLocallyOwned = false;
  static const int _maxConcurrentVideos = 2;
  static int _activeVideoInits = 0;
  bool _countedActive = false;
  bool _isCurrentlyVisible = false;

  void _releaseActiveSlot() {
    if (_countedActive) {
      _countedActive = false;
      _activeVideoInits--;
    }
  }

  @override
  bool get wantKeepAlive => _isVideoInitialized || _isInitializing;

  @override
  void initState() {
    super.initState();
    _isMuted = widget.isMutedInitial;

    // Grab the pre-loaded controller if it was in the top 2, otherwise wait for scroll
    if (widget.videoController != null) {
      _localVideoController = widget.videoController;
      _isVideoInitialized = _localVideoController!.value.isInitialized;
      _isLocallyOwned = false;
    }

    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted && !_isDisposed) _fetchCommentCount();
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    if (_isLocallyOwned) {
      _localVideoController?.dispose();
      _releaseActiveSlot(); // was missing — this is what leaked the counter
    } else if (_isInitializing) {
      _releaseActiveSlot();
    }
    super.dispose();
  }

  // 🔥 NEW: Method to initialize the video ONLY when it scrolls onto the screen
  Future<void> _initializeLocalVideoIfNeeded() async {
    if (_localVideoController != null ||
        _isInitializing ||
        widget.gist['media_type'] != 'video') return;

    final videoUrl = widget.gist['image_url']?.toString() ?? '';
    if (videoUrl.isEmpty) return;

    if (_activeVideoInits >= _maxConcurrentVideos) {
      Future.delayed(const Duration(milliseconds: 400), () {
        if (mounted && !_isDisposed && _isCurrentlyVisible) {
          _initializeLocalVideoIfNeeded();
        }
      });
      return;
    }

    _isInitializing = true;
    _countedActive = true;
    _activeVideoInits++;

    Future.microtask(() async {
      try {
        final fileInfo = await DefaultCacheManager().getFileFromCache(videoUrl);
        final options = VideoPlayerOptions(mixWithOthers: true);

        final newController = fileInfo != null
            ? VideoPlayerController.file(fileInfo.file,
                videoPlayerOptions: options)
            : VideoPlayerController.networkUrl(Uri.parse(videoUrl),
                videoPlayerOptions: options);

        await newController.initialize();

        if (_isDisposed || !mounted || !_isCurrentlyVisible) {
          await newController.dispose();
          _releaseActiveSlot();
          if (mounted) setState(() => _isInitializing = false);
          return;
        }

        newController.setLooping(true);
        newController.setVolume(_isMuted ? 0.0 : 1.0);
        _localVideoController = newController;
        _isLocallyOwned = true;

        setState(() {
          _isVideoInitialized = true;
          _isInitializing = false;
        });
        if (!_userPaused) newController.play();
      } catch (e) {
        debugPrint('Local video init error: $e');
        _releaseActiveSlot();
        if (mounted) setState(() => _isInitializing = false);
      }
    });
  }

  // 🔥 NEW: Destroy videos when scrolled off-screen to free up phone RAM!
  void _disposeLocalVideo() {
    if (_isLocallyOwned && _localVideoController != null) {
      final oldController = _localVideoController;
      _localVideoController = null;
      _isLocallyOwned = false;
      _releaseActiveSlot();

      if (mounted) {
        setState(() {
          _isVideoInitialized = false;
          _isInitializing = false;
        });
      }

      // Small delay before real teardown — disposing the player right
      // after pausing it is what used to crash some Android devices.
      Future.delayed(const Duration(milliseconds: 300), () {
        oldController?.dispose();
      });
    }
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (!mounted) return;

    final visible = info.visibleFraction;
    _isCurrentlyVisible = visible > 0.4;

    if (visible > 0.4) {
      if (_localVideoController == null && !_isInitializing) {
        _initializeLocalVideoIfNeeded();
      } else if (_isVideoInitialized && _localVideoController != null) {
        if (!_localVideoController!.value.isPlaying && !_userPaused) {
          _localVideoController!.play();
        }
      }
    } else if (visible == 0.0) {
      _disposeLocalVideo();
    } else {
      if (_localVideoController != null &&
          _localVideoController!.value.isPlaying) {
        _localVideoController!.pause();
      }
    }
  }

  void _triggerDoubleTapLike() {
    if (!widget.isLiked) {
      widget.onToggleLike();
    }
    setState(() => _showHeartOverlay = true);

    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) setState(() => _showHeartOverlay = false);
    });
  }

  Future<void> _fetchCommentCount() async {
    try {
      final isMoment = widget.gist['is_moment'] == true;
      final table = isMoment ? 'moment_comments' : 'gist_comments';
      final column = isMoment ? 'moment_id' : 'gist_id';

      final res = await Supabase.instance.client
          .from(table)
          .select('id')
          .eq(column, widget.gistId)
          .count(CountOption.exact);
      if (mounted && !_isDisposed) setState(() => _commentCount = res.count);
    } catch (_) {}
  }

  void _expandMedia(String url) {
    showDialog(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: EdgeInsets.zero,
        child: Stack(
          fit: StackFit.expand,
          children: [
            InteractiveViewer(
              panEnabled: true,
              minScale: 1.0,
              maxScale: 4.0,
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
              ),
            ),
            Positioned(
              top: 40,
              right: 20,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 32),
                onPressed: () => Navigator.pop(context),
              ),
            )
          ],
        ),
      ),
    );
  }

  void _routeToMomentViewer() {
    final momentsOnly = widget.allFeedItems
        .where((g) => g['is_moment'] == true)
        .map((g) => {
              'id': g['real_moment_id'],
              'user_id': g['user_id'],
              'media_url': g['image_url'],
              'media_type': g['media_type'],
              'caption': g['title'],
              'created_at': g['created_at'],
              'category': g['category'],
              'profiles': g['profiles'],
              'likes_count': widget.likeCount,
              'comments_count': _commentCount,
            })
        .toList();

    final index =
        momentsOnly.indexWhere((m) => m['id'] == widget.gist['real_moment_id']);
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => MomentViewerScreen(
                  moments: momentsOnly,
                  initialIndex: index == -1 ? 0 : index,
                  userPreferences: widget.prefs,
                )));
  }

  Future<List<dynamic>> _fetchFriends(String myId) async {
    try {
      final res = await Supabase.instance.client
          .from('followers')
          .select('following_id')
          .eq('follower_id', myId);

      final followingIds = res.map((e) => e['following_id']).toList();
      if (followingIds.isEmpty) return [];

      return await Supabase.instance.client
          .from('profiles')
          .select('id, username, avatar_url')
          .inFilter('id', followingIds);
    } catch (e) {
      return [];
    }
  }

  void _showGistOptions() {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    final isMe = myId == widget.gist['user_id'];

    final createdAt = DateTime.parse(widget.gist['created_at']).toLocal();
    final canEdit = DateTime.now().difference(createdAt).inHours < 1;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isMe && canEdit)
              ListTile(
                leading: const Icon(Icons.edit, color: Colors.white),
                title: const Text('Edit Gist',
                    style: TextStyle(color: Colors.white, fontSize: 16)),
                onTap: () {
                  Navigator.pop(ctx);
                  _editGist();
                },
              ),
            if (isMe)
              ListTile(
                leading:
                    const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('Delete Gist',
                    style: TextStyle(color: Colors.redAccent, fontSize: 16)),
                onTap: () async {
                  Navigator.pop(ctx);
                  try {
                    await Supabase.instance.client
                        .from('gists')
                        .delete()
                        .eq('id', widget.gistId);
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Gist deleted')));
                    }
                  } catch (e) {
                    debugPrint('Delete error: $e');
                  }
                },
              ),
            if (!isMe)
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('No options available for this gist.',
                    style: TextStyle(color: Colors.white54)),
              )
          ],
        ),
      ),
    );
  }

  void _editGist() {
    final editController =
        TextEditingController(text: widget.gist['title'] ?? '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Edit Gist', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: editController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
              hintText: 'Enter new title...',
              hintStyle: TextStyle(color: Colors.white54)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.white54))),
          TextButton(
            onPressed: () async {
              final newText = editController.text.trim();
              if (newText.isNotEmpty && newText != widget.gist['title']) {
                Navigator.pop(ctx);
                try {
                  await Supabase.instance.client
                      .from('gists')
                      .update({'title': newText}).eq('id', widget.gistId);
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Gist updated!')));
                } catch (e) {
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Failed to update gist.')));
                }
              }
            },
            child: Text('Save',
                style: TextStyle(
                    color: widget.themeColor, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _shareToStory() async {
    final myId = Supabase.instance.client.auth.currentUser!.id;
    final String title = widget.gist['title'] ?? '';
    final String truncatedTitle =
        title.length > 50 ? '${title.substring(0, 50)}...' : title;
    final imageUrl = widget.gist['image_url'] ?? '';
    final mediaUrlToUse = widget.gist['image_urls'] != null &&
            (widget.gist['image_urls'] as List).isNotEmpty
        ? widget.gist['image_urls'][0]
        : imageUrl;

    // 🔥 FIX: Dynamically check if it's a Moment or Gist
    final isMoment = widget.gist['is_moment'] == true;
    final typeName = isMoment ? 'moment' : 'gist';
    final displayTypeName = isMoment ? 'Moment' : 'Gist';

    // 🔥 FIX: Grab the original creator's username for the caption
    final profileData = widget.gist['profiles'];
    final originalUsername =
        (profileData is Map ? profileData['username']?.toString() : null) ??
            'Someone';

    try {
      await Supabase.instance.client.from('stories').insert({
        'user_id': myId,
        'media_url': mediaUrlToUse,
        'media_type': widget.gist['media_type'] ?? 'image',
        'caption':
            'Check out this $displayTypeName by @$originalUsername!\n$truncatedTitle',
        // 🔥 FIX: Now saves the correct type in the URL so the Story Viewer can find the creator!
        'url':
            'https://www.allowanceapp.org/share?type=$typeName&id=${widget.gistId}',
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Shared to Story!'), backgroundColor: Colors.green));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Failed to share to story'),
            backgroundColor: Colors.red));
      }
    }
  }

  void _showPollSheet() {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    if (myId == null) return;

    final options = List<String>.from(widget.gist['poll_options'] ?? []);
    final allowMultiple = widget.gist['allow_multiple_votes'] == true;

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Poll',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
              if (allowMultiple)
                const Text('You can select multiple options',
                    style: TextStyle(color: Colors.white54, fontSize: 12)),
              const SizedBox(height: 16),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: Supabase.instance.client
                    .from('poll_votes')
                    .stream(primaryKey: ['id']).eq('gist_id', widget.gistId),
                builder: (context, snapshot) {
                  final votes = snapshot.data ?? [];

                  return StatefulBuilder(
                    builder: (BuildContext context, StateSetter setModalState) {
                      final myVotes = votes
                          .where((v) => v['user_id'] == myId)
                          .map((v) => v['option'] as String)
                          .toSet();

                      return Column(
                        children: options.map((opt) {
                          final isSelected = myVotes.contains(opt);
                          final voteCount =
                              votes.where((v) => v['option'] == opt).length;
                          final percent = votes.isEmpty
                              ? 0
                              : (voteCount / votes.length * 100).toInt();

                          return GestureDetector(
                            onTap: () async {
                              setModalState(() {
                                if (isSelected) {
                                  votes.removeWhere((v) =>
                                      v['user_id'] == myId &&
                                      v['option'] == opt);
                                } else {
                                  if (!allowMultiple) {
                                    votes.removeWhere(
                                        (v) => v['user_id'] == myId);
                                  }
                                  votes.add({'user_id': myId, 'option': opt});
                                }
                              });

                              if (isSelected) {
                                await Supabase.instance.client
                                    .from('poll_votes')
                                    .delete()
                                    .match({
                                  'gist_id': widget.gistId,
                                  'user_id': myId,
                                  'option': opt
                                });
                              } else {
                                if (!allowMultiple) {
                                  await Supabase.instance.client
                                      .from('poll_votes')
                                      .delete()
                                      .match({
                                    'gist_id': widget.gistId,
                                    'user_id': myId
                                  });
                                }
                                await Supabase.instance.client
                                    .from('poll_votes')
                                    .insert({
                                  'gist_id': widget.gistId,
                                  'user_id': myId,
                                  'option': opt
                                });
                              }
                            },
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: isSelected
                                      ? widget.themeColor.withOpacity(0.2)
                                      : Colors.white10,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: isSelected
                                          ? widget.themeColor
                                          : Colors.transparent)),
                              child: Row(
                                children: [
                                  Icon(
                                      isSelected
                                          ? Icons.check_circle
                                          : Icons.circle_outlined,
                                      color: isSelected
                                          ? widget.themeColor
                                          : Colors.white54),
                                  const SizedBox(width: 12),
                                  Expanded(
                                      child: Text(opt,
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 16))),
                                  Text('$percent%',
                                      style: TextStyle(
                                          color: isSelected
                                              ? widget.themeColor
                                              : Colors.white54,
                                          fontWeight: FontWeight.bold)),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- NEW: Helper for the colored Tags ---
  Widget _buildTag(String text, Color color) {
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
          color: color.withOpacity(0.2),
          border: Border.all(color: color.withOpacity(0.5)),
          borderRadius: BorderRadius.circular(12)),
      child: Text(text,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.bold)),
    );
  }

  Future<void> _sendGistToFriends(
      Set<String> friendIds, String truncatedTitle, String gistLink) async {
    try {
      final myId = Supabase.instance.client.auth.currentUser!.id;
      final imageUrl = widget.gist['image_url'] ?? '';
      final mediaUrlToUse = widget.gist['image_urls'] != null &&
              (widget.gist['image_urls'] as List).isNotEmpty
          ? widget.gist['image_urls'][0]
          : imageUrl;
      final isMoment = widget.gist['is_moment'] == true;
      final typeName = isMoment ? 'Moment' : 'Gist';

      for (String friendId in friendIds) {
        final response = await Supabase.instance.client.rpc(
            'get_or_create_personal_chat',
            params: {'user_a': myId, 'user_b': friendId});
        await Supabase.instance.client.from('messages').insert({
          'chat_id': response.toString(),
          'sender_id': myId,
          'content':
              'Check out this $typeName on Allowance!\n$truncatedTitle\n$gistLink',
          'media_url': mediaUrlToUse,
          'media_type': widget.gist['media_type'] ?? 'image',
          'is_read': false,
        });
      }
    } catch (e) {
      debugPrint('Failed to batch send gist: $e');
    }
  }

  void _showShipSheet(BuildContext context) {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    if (myId == null) return;

    final String title = widget.gist['title'] ?? '';
    final String truncatedTitle =
        title.length > 50 ? '${title.substring(0, 50)}...' : title;

    final isMoment = widget.gist['is_moment'] == true;
    final String typeName = isMoment ? 'Moment' : 'Gist';
    final String gistLink =
        'https://www.allowanceapp.org/share?type=${typeName.toLowerCase()}&id=${widget.gistId}';

    final friendsFuture = _fetchFriends(myId);

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        Set<String> selectedFriends = {};
        bool isSending = false;

        return StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
            return DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.4,
              maxChildSize: 0.9,
              expand: false,
              builder: (_, scrollController) => Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text('Share $typeName',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                  ),
                  ListTile(
                    leading: Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                            color: Colors.grey[800], shape: BoxShape.circle),
                        child: const Icon(Icons.share, color: Colors.white)),
                    title: const Text('Share to other apps',
                        style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(ctx);
                      Share.share(
                          'Check out this $typeName on Allowance!\n$truncatedTitle\n$gistLink');
                    },
                  ),
                  const Divider(color: Colors.white10),
                  // ... Keep the rest of your Friends grid exactly the same here!
                  const Padding(
                      padding: EdgeInsets.all(8.0),
                      child: Text('Send to friends',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 14))),

                  Expanded(
                    child: FutureBuilder<List<dynamic>>(
                        future: friendsFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting)
                            return Center(
                                child: CircularProgressIndicator(
                                    color: widget.themeColor));
                          final friends = snapshot.data ?? [];
                          if (friends.isEmpty)
                            return const Center(
                                child: Text("Follow people to see them here",
                                    style: TextStyle(color: Colors.white54)));

                          // 🔥 FIX: Render Friends as a cool Instagram-style Grid!
                          return GridView.builder(
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 3,
                                    mainAxisSpacing: 16,
                                    crossAxisSpacing: 10,
                                    childAspectRatio: 0.7),
                            itemCount: friends.length,
                            itemBuilder: (context, index) {
                              final friend = friends[index];
                              final friendId = friend['id'];
                              final isSelected =
                                  selectedFriends.contains(friendId);

                              // Check if friend is a Plus Member
                              final bool isPlus =
                                  friend['subscription_tier'] == 'Membership';

                              return GestureDetector(
                                onTap: () => setModalState(() => isSelected
                                    ? selectedFriends.remove(friendId)
                                    : selectedFriends.add(friendId)),
                                child: Column(
                                  children: [
                                    Stack(
                                      alignment: Alignment.bottomRight,
                                      children: [
                                        CircleAvatar(
                                          radius: 30,
                                          backgroundColor: Colors.grey[800],
                                          backgroundImage:
                                              friend['avatar_url'] != null
                                                  ? CachedNetworkImageProvider(
                                                      friend['avatar_url'])
                                                  : null,
                                          child: friend['avatar_url'] == null
                                              ? const Icon(Icons.person,
                                                  color: Colors.white54,
                                                  size: 28)
                                              : null,
                                        ),
                                        if (isSelected)
                                          const CircleAvatar(
                                              radius: 10,
                                              backgroundColor: Colors.white,
                                              child: Icon(Icons.check_circle,
                                                  color: Color(0xFF4CAF50),
                                                  size: 20)),
                                      ],
                                    ),
                                    const SizedBox(height: 8),
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Flexible(
                                            child: Text(
                                                friend['username'] ?? 'User',
                                                style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 12),
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis)),
                                        if (isPlus) ...[
                                          const SizedBox(width: 2),
                                          const Icon(Icons.star,
                                              color: Colors.amber, size: 10)
                                        ]
                                      ],
                                    ),
                                  ],
                                ),
                              );
                            },
                          );
                        }),
                  ),
                  if (selectedFriends.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: widget.themeColor,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12))),
                          onPressed: isSending
                              ? null
                              : () async {
                                  setModalState(() => isSending = true);
                                  await _sendGistToFriends(selectedFriends,
                                      truncatedTitle, gistLink);

                                  if (mounted) {
                                    Navigator.pop(ctx);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                            content: Text(
                                                'Sent to ${selectedFriends.length} friend(s)!'),
                                            backgroundColor: Colors.green));
                                  }
                                },
                          child: isSending
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                      color: Colors.black, strokeWidth: 2))
                              : Text('Send to ${selectedFriends.length}',
                                  style: const TextStyle(
                                      color: Colors.black,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16)),
                        ),
                      ),
                    ),

                  // 🔥 FIX: Immovable "Share to My Story" Bar at the bottom
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                        color: Colors.black,
                        border: Border(
                            top: BorderSide(
                                color: Colors.white.withOpacity(0.05)))),
                    child: SafeArea(
                      top: false,
                      child: ElevatedButton.icon(
                        icon:
                            const Icon(Icons.amp_stories, color: Colors.black),
                        label: const Text('Add to my Story',
                            style: TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.bold,
                                fontSize: 16)),
                        style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12))),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _shareToStory();
                        },
                      ),
                    ),
                  )
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    final imageUrl = widget.gist['image_url']?.toString() ?? '';
    final imageUrls = (widget.gist['image_urls'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        [];
    final mediaType = widget.gist['media_type']?.toString() ?? 'image';
    final gistUrl = widget.gist['url']?.toString() ?? '';
    final String fullTitle = widget.gist['title']?.toString() ?? '';

    final imagesToShow = imageUrls.isNotEmpty
        ? imageUrls
        : (imageUrl.isNotEmpty ? [imageUrl] : []);
    // FIX: Safely extract all profile data with null checks
    final profileData = widget.gist['profiles'];
    final String userId = widget.gist['user_id']?.toString() ?? '';

    String username = 'User';
    String? avatarUrl;
    String? bio;

    if (profileData is Map) {
      username = profileData['username']?.toString() ?? 'User';
      avatarUrl = profileData['avatar_url']?.toString();
      bio = profileData['bio']?.toString();
    }

    final isLocal = widget.gist['type'] == 'local';
    final hasPoll = widget.gist['has_poll'] == true;
    final isMoment = widget.gist['is_moment'] == true;

    final String createdAtStr = widget.gist['created_at']?.toString() ?? '';
    final datePosted = createdAtStr.isNotEmpty
        ? DateFormat('dd MMM, yyyy')
            .format(DateTime.parse(createdAtStr).toLocal())
        : 'Recently';

    Widget tagsRow = Padding(
      padding: const EdgeInsets.only(left: 16.0, top: 12.0, bottom: 12.0),
      child: Row(
        children: [
          if (!isMoment)
            _buildTag(isLocal ? 'Local' : 'Global', Colors.blueAccent),
          if (widget.gist['category'] != null &&
              widget.gist['category'].toString().isNotEmpty)
            _buildTag(widget.gist['category'].toString(), Colors.orangeAccent),
          if (hasPoll) _buildTag('Poll', Colors.purpleAccent),
          if (isMoment) _buildTag('Moment', Colors.amber),
        ],
      ),
    );

    Widget mediaWidget;
    if (mediaType == 'video') {
      final controller = _localVideoController;

      mediaWidget = VisibilityDetector(
        key: Key('video_vis_${widget.gistId}'),
        onVisibilityChanged: _onVisibilityChanged,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          child: controller != null && _isVideoInitialized
              ? Column(
                  key: const ValueKey('video_player'),
                  children: [
                    AspectRatio(
                      aspectRatio: controller.value.aspectRatio,
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          GestureDetector(
                            onTap: () {
                              if (isMoment) {
                                _routeToMomentViewer();
                              } else {
                                if (controller.value.isPlaying) {
                                  controller.pause();
                                  _userPaused = true;
                                } else {
                                  controller.play();
                                  _userPaused = false;
                                }
                                setState(() {});
                              }
                            },
                            onDoubleTap: _triggerDoubleTapLike,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                VideoPlayer(controller),
                                ValueListenableBuilder(
                                  valueListenable: controller,
                                  builder:
                                      (context, VideoPlayerValue value, child) {
                                    if (value.isPlaying)
                                      return const SizedBox.shrink();
                                    return Container(
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                            color:
                                                Colors.black.withOpacity(0.6),
                                            shape: BoxShape.circle),
                                        child: const Icon(
                                            Icons.play_arrow_rounded,
                                            color: Colors.white,
                                            size: 54));
                                  },
                                ),
                              ],
                            ),
                          ),
                          Positioned(
                            bottom: 12,
                            right: 12,
                            child: GestureDetector(
                              onTap: () {
                                setState(() {
                                  _isMuted = !_isMuted;
                                  controller.setVolume(_isMuted ? 0.0 : 1.0);
                                });
                                widget.onToggleMute(_isMuted);
                              },
                              child: CircleAvatar(
                                  backgroundColor: Colors.black54,
                                  radius: 14,
                                  child: Icon(
                                      _isMuted
                                          ? Icons.volume_off
                                          : Icons.volume_up,
                                      color: Colors.white,
                                      size: 16)),
                            ),
                          ),
                          Center(
                            child: IgnorePointer(
                              child: AnimatedOpacity(
                                opacity: _showHeartOverlay ? 0.9 : 0.0,
                                duration: const Duration(milliseconds: 200),
                                child: AnimatedScale(
                                  scale: _showHeartOverlay ? 1.0 : 0.3,
                                  duration: const Duration(milliseconds: 400),
                                  curve: Curves.elasticOut,
                                  child: const Icon(Icons.favorite,
                                      color: Colors.white, size: 100),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    VideoProgressIndicator(controller,
                        allowScrubbing: true,
                        colors: const VideoProgressColors(
                            playedColor: Color(0xFF4CAF50),
                            bufferedColor: Colors.white24,
                            backgroundColor: Colors.transparent)),
                  ],
                )
              : Container(
                  key: const ValueKey('loading_state'),
                  height: 300,
                  width: double.infinity,
                  color: Colors.black,
                  child: const Center(
                      child:
                          CircularProgressIndicator(color: Color(0xFF4CAF50)))),
        ),
      );
    } else {
      mediaWidget = imagesToShow.isEmpty
          ? Container(height: 300, color: Colors.grey[900])
          : SizedBox(
              width: double.infinity,
              height: MediaQuery.sizeOf(context).width,
              child: Stack(
                children: [
                  PageView.builder(
                    itemCount: imagesToShow.length,
                    onPageChanged: (p) => setState(() => _localPageIndex = p),
                    itemBuilder: (ctx, i) => GestureDetector(
                        onTap: () {
                          if (isMoment) {
                            _routeToMomentViewer();
                          } else {
                            _expandMedia(imagesToShow[i]);
                          }
                        },
                        onDoubleTap: _triggerDoubleTapLike,
                        child: CachedNetworkImage(
                            imageUrl: imagesToShow[i],
                            fit: BoxFit.cover,
                            memCacheWidth:
                                800, // 🔥 CRITICAL FIX: Destroys RAM crashes completely!
                            placeholder: (context, url) => Container(
                                color: Colors.grey[900],
                                child: const Center(
                                    child: CircularProgressIndicator(
                                        color: Color(0xFF4CAF50)))),
                            errorWidget: (context, url, error) => Container(
                                color: Colors.grey[900],
                                child: const Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(Icons.broken_image,
                                          color: Colors.white54, size: 40),
                                      SizedBox(height: 8),
                                      Text("Image unavailable",
                                          style: TextStyle(
                                              color: Colors.white54,
                                              fontSize: 12)),
                                    ],
                                  ),
                                )))),
                  ),
                  Positioned(
                    top: 12,
                    left: 12,
                    child: GestureDetector(
                        onTap: () =>
                            _expandMedia(imagesToShow[_localPageIndex]),
                        child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: const BoxDecoration(
                                color: Colors.black54, shape: BoxShape.circle),
                            child: const Icon(Icons.fullscreen,
                                color: Colors.white, size: 20))),
                  ),
                  if (imagesToShow.length > 1)
                    Positioned(
                      top: 12,
                      right: 12,
                      child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(20)),
                          child: Text(
                              "${_localPageIndex + 1}/${imagesToShow.length}",
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 12))),
                    ),
                  Center(
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: _showHeartOverlay ? 0.9 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: AnimatedScale(
                          scale: _showHeartOverlay ? 1.0 : 0.3,
                          duration: const Duration(milliseconds: 400),
                          curve: Curves.elasticOut,
                          child: const Icon(Icons.favorite,
                              color: Colors.white, size: 100),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
    }

    Widget actionBar = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: widget.onToggleLike,
            child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Icon(
                    widget.isLiked ? Icons.favorite : Icons.favorite_border,
                    color: widget.isLiked ? Colors.red : Colors.white,
                    size: 28)),
          ),
          GestureDetector(
            onTap: () async {
              await widget.onShowComments();
              _fetchCommentCount();
            },
            child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Icon(CupertinoIcons.chat_bubble,
                    color: Colors.white, size: 26)),
          ),
          GestureDetector(
            onTap: () => _showShipSheet(context),
            child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('🚀', style: TextStyle(fontSize: 22))),
          ),
          if (hasPoll)
            GestureDetector(
              onTap: _showPollSheet,
              child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child:
                      Icon(Icons.poll, color: Colors.purpleAccent, size: 28)),
            ),
          GestureDetector(
            onTap: () {
              final target = imagesToShow.isNotEmpty
                  ? imagesToShow[_localPageIndex]
                  : imageUrl;
              if (target.isNotEmpty) widget.onDownload(target);
            },
            child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Icon(Icons.download_for_offline_outlined,
                    color: Colors.white, size: 26)),
          ),
        ],
      ),
    );

    Widget captionArea = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.likeCount > 0 || _commentCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8.0),
              child: Text(
                  '${widget.likeCount} likes${_commentCount > 0 ? ' • $_commentCount replies' : ''}',
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13)),
            ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (userId.isNotEmpty)
                UniversalProfileCard.show(context, userId, widget.prefs);
            },
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: Colors.grey[800],
                  backgroundImage: (avatarUrl != null && avatarUrl.isNotEmpty)
                      ? CachedNetworkImageProvider(
                          avatarUrl,
                          maxWidth: 100,
                          maxHeight: 100,
                        )
                      : null,
                  child: (avatarUrl == null || avatarUrl.isEmpty)
                      ? Text(
                          username.isNotEmpty ? username[0].toUpperCase() : 'U',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        )
                      : null,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RichText(
                        text: TextSpan(
                          style: const TextStyle(
                              color: Colors.white, fontSize: 14, height: 1.3),
                          children: [
                            TextSpan(
                                text: username.isNotEmpty
                                    ? '$username  '
                                    : 'User  ',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold)),
                            TextSpan(
                                text: fullTitle.length > 90
                                    ? "${fullTitle.substring(0, 90)}..."
                                    : fullTitle),
                          ],
                        ),
                      ),
                      if (fullTitle.length > 90)
                        GestureDetector(
                          onTap: () {
                            showModalBottomSheet(
                              context: context,
                              backgroundColor: const Color(0xFF1E1E1E),
                              shape: const RoundedRectangleBorder(
                                  borderRadius: BorderRadius.vertical(
                                      top: Radius.circular(24))),
                              builder: (context) => Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: SingleChildScrollView(
                                      child: Text(fullTitle,
                                          style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 16,
                                              height: 1.5)))),
                            );
                          },
                          child: const Padding(
                              padding: EdgeInsets.only(top: 4),
                              child: Text("see more...",
                                  style: TextStyle(
                                      color: Color(0xFF4CAF50),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13))),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.more_vert, color: Colors.white54),
                  onPressed: _showGistOptions,
                )
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(datePosted,
              style: const TextStyle(color: Colors.white54, fontSize: 11)),
          if (gistUrl.isNotEmpty) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () async {
                final uri = Uri.tryParse(gistUrl);
                if (uri != null && await canLaunchUrl(uri))
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
              },
              child: Row(
                children: [
                  const Icon(Icons.link, color: Colors.blueAccent, size: 18),
                  const SizedBox(width: 4),
                  Expanded(
                      child: Text(gistUrl,
                          style: const TextStyle(
                              color: Colors.blueAccent, fontSize: 13),
                          overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 24.0),
      child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [tagsRow, mediaWidget, actionBar, captionArea]),
    );
  }
} // <--- THIS CLOSING BRACKET FIXES YOUR ERROR

// ========================================================================
// GIST COMMENTS SHEET CLASS
// ========================================================================
// ========================================================================
// GIST COMMENTS SHEET CLASS (HEAVILY OPTIMIZED)
// ========================================================================
class GistCommentsSheet extends StatefulWidget {
  final String gistId;
  final Color themeColor;
  final UserPreferences userPreferences;

  const GistCommentsSheet({
    super.key,
    required this.gistId,
    required this.themeColor,
    required this.userPreferences,
  });

  @override
  State<GistCommentsSheet> createState() => _GistCommentsSheetState();
}

class _GistCommentsSheetState extends State<GistCommentsSheet> {
  final _commentController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final supabase = Supabase.instance.client;
  bool _isPosting = false;

  // 1. OUTSIDE THE BOX FIX: Store stream here so it doesn't recreate on keystrokes
  late final Stream<List<Map<String, dynamic>>> _commentsStream;

  @override
  void initState() {
    super.initState();
    // 2. Initialize the stream ONCE
    _commentsStream = supabase
        .from('gist_comments')
        .stream(primaryKey: ['id'])
        .eq('gist_id', int.parse(widget.gistId))
        .order('created_at', ascending: true);
  }

  @override
  void dispose() {
    _commentController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _postComment() async {
    final text = _commentController.text.trim();
    final user = supabase.auth.currentUser;
    if (text.isEmpty || user == null) return;

    setState(() => _isPosting = true);
    try {
      await supabase.from('gist_comments').insert({
        'gist_id': int.parse(widget.gistId),
        'user_id': user.id,
        'content': text,
      });
      _commentController.clear();
      FocusScope.of(context).unfocus();
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to post comment')),
      );
    } finally {
      if (mounted) setState(() => _isPosting = false);
    }
  }

  void _showCommentOptions(int commentId, String currentContent) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.edit, color: Colors.white),
            title: const Text('Edit', style: TextStyle(color: Colors.white)),
            onTap: () {
              Navigator.pop(ctx);
              _editComment(commentId, currentContent);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete, color: Colors.red),
            title: const Text('Delete', style: TextStyle(color: Colors.red)),
            onTap: () {
              Navigator.pop(ctx);
              _deleteComment(commentId);
            },
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  void _editComment(int commentId, String currentContent) {
    final editController = TextEditingController(text: currentContent);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title:
            const Text('Edit Comment', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: editController,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Update your comment...',
            hintStyle: TextStyle(color: Colors.white54),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () async {
              if (editController.text.trim().isNotEmpty) {
                await supabase
                    .from('gist_comments')
                    .update({'content': editController.text.trim()}).eq(
                        'id', commentId);
                if (mounted) Navigator.pop(ctx);
              }
            },
            child: Text('Save',
                style: TextStyle(
                    color: widget.themeColor, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteComment(int commentId) async {
    try {
      await supabase.from('gist_comments').delete().eq('id', commentId);
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Failed to delete')));
    }
  }

  String _timeAgo(String timestamp) {
    final diff = DateTime.now().difference(DateTime.parse(timestamp).toLocal());
    if (diff.inMinutes < 1) return 'now';
    if (diff.inHours < 1) return '${diff.inMinutes}m';
    if (diff.inDays < 1) return '${diff.inHours}h';
    return '${diff.inDays}d';
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: Color(0xFF111111),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        bottom: false, // <-- FIX: Prevents double-padding constraint crash
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.grey[700],
                  borderRadius: BorderRadius.circular(10)),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 15),
              child: Text(
                'Comments',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
              ),
            ),
            const Divider(color: Colors.white10, height: 1),
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                stream: _commentsStream,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return Center(
                        child: CircularProgressIndicator(
                            color: widget.themeColor));
                  }

                  final comments = snapshot.data ?? [];
                  if (comments.isEmpty) {
                    return const Center(
                        child: Text("No comments yet. Be the first!",
                            style: TextStyle(color: Colors.white54)));
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: comments.length,
                    itemBuilder: (context, index) {
                      final comment = comments[index];
                      final userId = comment['user_id'] as String;
                      final isMyComment =
                          userId == supabase.auth.currentUser?.id;

                      return FutureBuilder<Map<String, dynamic>?>(
                        future: supabase
                            .from('profiles')
                            .select(
                                'username, avatar_url, subscription_tier, school_name')
                            .eq('id', userId)
                            .maybeSingle(),
                        builder: (ctx, profileSnap) {
                          final profile = profileSnap.data;
                          final isPlus =
                              profile?['subscription_tier'] == 'Membership';

                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: Colors.grey[800],
                              backgroundImage: profile?['avatar_url'] != null
                                  ? NetworkImage(profile!['avatar_url'])
                                  : null,
                              child: profile?['avatar_url'] == null
                                  ? const Icon(Icons.person,
                                      color: Colors.white54, size: 20)
                                  : null,
                            ),
                            title: Row(
                              children: [
                                Text('@${profile?['username'] ?? 'User'}',
                                    style: const TextStyle(
                                        color: Colors.white70,
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold)),
                                if (isPlus) ...[
                                  const SizedBox(width: 4),
                                  const Icon(Icons.star,
                                      color: Colors.amber, size: 12),
                                ],
                                const SizedBox(width: 8),
                                Text(_timeAgo(comment['created_at']),
                                    style: const TextStyle(
                                        color: Colors.white38, fontSize: 11)),
                              ],
                            ),
                            subtitle: Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Text(comment['content'] ?? '',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 14)),
                            ),
                            trailing: isMyComment
                                ? IconButton(
                                    icon: const Icon(Icons.more_vert,
                                        color: Colors.white54, size: 18),
                                    onPressed: () {
                                      FocusScope.of(context).unfocus();
                                      _showCommentOptions(
                                          comment['id'], comment['content']);
                                    },
                                  )
                                : null,
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: const BoxDecoration(
                  border: Border(top: BorderSide(color: Colors.white10))),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _commentController,
                      focusNode: _focusNode,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'Add a comment...',
                        hintStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: Colors.grey[900],
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(30),
                            borderSide: BorderSide.none),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _commentController,
                    builder: (context, value, child) {
                      final hasText = value.text.trim().isNotEmpty;
                      return GestureDetector(
                        onTap: (hasText && !_isPosting) ? _postComment : null,
                        child: _isPosting
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    color: widget.themeColor, strokeWidth: 2))
                            : Text(
                                'Post',
                                style: TextStyle(
                                    color: hasText
                                        ? widget.themeColor
                                        : Colors.grey,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16),
                              ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
