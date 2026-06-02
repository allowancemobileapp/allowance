// lib/screens/home/home_screen.dart
import 'dart:async';
import 'dart:convert';
import 'package:allowance/screens/chat/chat_list_screen.dart';
import 'package:allowance/screens/chat/create_group_screen.dart';
import 'package:allowance/screens/chat/explore_screen.dart';
import 'package:allowance/screens/home/create_story_screen.dart';
import 'package:allowance/screens/home/gist_submission_screen.dart';
import 'package:allowance/screens/home/media_editor_screen.dart';
import 'package:allowance/screens/home/ticket_submission_screen.dart';
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
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';

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
  List<Map<String, dynamic>> _fetchedGists = [];
  final ValueNotifier<bool> _showBackToTopButton = ValueNotifier(false);

  // NEW: track loading vs loaded-with-zero-items
  bool _isGistsLoading = true;
  RealtimeChannel? _globalChatChannel;
  bool _isProcessingSubscription = false;

  String _gistFilter = 'All';
  final Map<int, int> _gistLikeCounts = {};
  final Set<int> _likedGistIds = {};
  final ScrollController _scrollController = ScrollController(); // The listener
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
      // Updates ONLY the button, skipping the global build method entirely.
      if (_scrollController.offset > 300 && !_showBackToTopButton.value) {
        _showBackToTopButton.value = true;
      } else if (_scrollController.offset <= 300 &&
          _showBackToTopButton.value) {
        _showBackToTopButton.value = false;
      }
    });

    _budgetFocusNode.addListener(() => setState(() {}));
    _pageController = PageController(viewportFraction: 0.85);
    _budgetController.text = _prefs.budget?.toString() ?? "";
    _fetchGistsAndStartSlideshow();
    _setupGlobalChatListener();
    _recoverPendingSubscription();
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
    super.dispose();
  }

  // --- NEW: LISTENS FOR MESSAGES ANYWHERE IN THE APP ---
  void _setupGlobalChatListener() {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) return;

    _globalChatChannel = supabase
        .channel('global-messages')
        .onPostgresChanges(
            event: PostgresChangeEvent.insert,
            schema: 'public',
            table: 'messages',
            callback: (payload) async {
              final newMsg = payload.newRecord;
              final senderId = newMsg['sender_id'];
              final chatId = newMsg['chat_id'];

              // If someone else sent it, AND we are NOT currently inside that specific chat screen
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
            })
        .subscribe();
  }

  // --- NEW: THE COOL ROUNDED TOP BANNER ---
  void _showInAppNotification(
      String senderName, String message, String avatarUrl) {
    final overlay = Overlay.of(context);
    late OverlayEntry entry;

    entry = OverlayEntry(
      builder: (context) => Positioned(
        top: MediaQuery.of(context).padding.top + 10,
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

  // ==========================================
  // SPEED HACK: CACHE VIDEOS TO PHONE STORAGE
  // ==========================================
  Future<void> _initializeVideoControllers() async {
    int count = 0;
    for (var gist in _fetchedGists) {
      if (count >= 2)
        break; // <--- FIX: Limit to 2 videos to prevent Memory Crash on startup!
      final mediaType = gist['media_type'] as String?;

      if (mediaType == 'video') {
        final gistId = gist['id'] as int;
        final videoUrl = (gist['image_url'] as String?) ?? '';

        if (videoUrl.isNotEmpty) {
          try {
            var fileInfo =
                await DefaultCacheManager().getFileFromCache(videoUrl);
            VideoPlayerController controller;

            if (fileInfo != null) {
              controller = VideoPlayerController.file(fileInfo.file);
            } else {
              controller =
                  VideoPlayerController.networkUrl(Uri.parse(videoUrl));
              // Removed the aggressive background download here to save memory
            }

            await controller.initialize();
            controller.setLooping(true);
            _videoControllers[gistId] = controller;
            _isVideoMuted[gistId] = true;
            count++;
          } catch (e) {
            debugPrint("Video caching error: $e");
          }
        }
      }
    }
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
    await _fetchGistsAndStartSlideshow(); // Refreshes Gists
    _storiesBarKey.currentState?.refresh(); // Refreshes Stories
  }

  // ── NEW: Load like counts and whether current user liked each gist ──
  // ── NEW: Load like counts and whether current user liked each gist ──
  Future<void> _loadGistLikes() async {
    final user = supabase.auth.currentUser;
    if (user == null) return;

    try {
      final gistIds = _fetchedGists.map((g) => g['id'] as int).toList();
      if (gistIds.isEmpty) return;

      final likesResponse = await supabase
          .from('gist_likes')
          .select('gist_id, user_id')
          .inFilter('gist_id', gistIds);

      _likedGistIds.clear();
      _gistLikeCounts.clear();

      final Map<int, int> countsMap = {};
      for (var like in likesResponse) {
        final gid = like['gist_id'] as int;
        countsMap[gid] = (countsMap[gid] ?? 0) + 1;
        if (like['user_id'] == user.id) {
          _likedGistIds.add(gid);
        }
      }
      _gistLikeCounts.addAll(countsMap);
    } catch (_) {}
  }

  // ── NEW: Toggle like ──
  Future<void> _toggleGistLike(int gistId) async {
    final user = supabase.auth.currentUser;
    if (user == null) return;

    final isLiked = _likedGistIds.contains(gistId);

    try {
      if (isLiked) {
        await supabase
            .from('gist_likes')
            .delete()
            .eq('gist_id', gistId)
            .eq('user_id', user.id);
        _likedGistIds.remove(gistId);
        _gistLikeCounts[gistId] = (_gistLikeCounts[gistId] ?? 1) - 1;
      } else {
        await supabase
            .from('gist_likes')
            .insert({'gist_id': gistId, 'user_id': user.id});
        _likedGistIds.add(gistId);
        _gistLikeCounts[gistId] = (_gistLikeCounts[gistId] ?? 0) + 1;
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Like error: $e');
    }
  }

  Future<void> _fetchGistsAndStartSlideshow() async {
    setState(() => _isGistsLoading = true);
    try {
      final List<Map<String, dynamic>> raw = await supabase
          .from('gists')
          .select('''
            id, user_id, title, image_url, image_urls, media_type, type, school_id, url, created_at, category,
            profiles:user_id (username, avatar_url, bio)
          ''')
          .eq('paid', true)
          .eq('status', 'active')
          .order('created_at', ascending: false)
          .limit(50);

      if (!mounted) return;

      List<Map<String, dynamic>> list = raw;

      final sidStr = _prefs.schoolId;
      final int? sidInt = sidStr != null ? int.tryParse(sidStr) : null;
      if (sidStr != null && sidStr.isNotEmpty) {
        list = list.where((g) {
          final type = (g['type'] ?? '').toString().toLowerCase();
          if (type == 'global') return true;
          if (type == 'local') {
            final gSchool = g['school_id'];
            if (gSchool == null) return false;
            final int? gsInt = int.tryParse(gSchool.toString());
            return gsInt != null && sidInt != null
                ? gsInt == sidInt
                : gSchool.toString() == sidStr;
          }
          return false;
        }).toList();
      } else {
        list = list
            .where(
                (g) => (g['type'] ?? '').toString().toLowerCase() == 'global')
            .toList();
      }

      if (mounted) {
        setState(() {
          _fetchedGists = list;
          _isGistsLoading = false;
        });
      }

      await _loadGistLikes();
      await _initializeVideoControllers();

      if (_fetchedGists.isEmpty) {
        setState(() => _fetchedGists = List.from(_fallbackGists));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isGistsLoading = false;
        _fetchedGists = List.from(_fallbackGists);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Failed to load gists. Showing defaults instead.')),
      );
    }
  }

  // 3. ULTIMATE PERFORMANCE SLIDESHOW
  Widget _buildGistSlideshow() {
    final filteredGists = _gistFilter == 'All'
        ? _fetchedGists
        : _fetchedGists.where((g) => g['category'] == _gistFilter).toList();

    if (_isGistsLoading) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.only(top: 40.0),
          child: Center(
              child: CircularProgressIndicator(color: Color(0xFF4CAF50))),
        ),
      );
    }

    if (filteredGists.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox());
    }

    return SliverPadding(
      padding: const EdgeInsets.only(bottom: 40, top: 0),
      sliver: SliverList.builder(
        itemCount: filteredGists.length,
        itemBuilder: (ctx, idx) {
          final gist = filteredGists[idx];
          final gistId = (gist['id'] is int)
              ? gist['id'] as int
              : int.tryParse(gist['id'].toString()) ?? 0;

          // FIX: RepaintBoundary REMOVED. Let Flutter handle rendering natively.
          return _GistItemCard(
            key: ValueKey(gistId),
            gist: gist,
            gistId: gistId,
            videoController: _videoControllers[gistId],
            isMutedInitial: _isVideoMuted[gistId] ?? true,
            likeCount: _gistLikeCounts[gistId] ?? 0,
            isLiked: _likedGistIds.contains(gistId),
            onToggleLike: () => _toggleGistLike(gistId),
            onShowComments: () => _showCommentsSheet(gistId.toString()),
            onDownload: _downloadGistImage,
            onToggleMute: (muted) => _isVideoMuted[gistId] = muted,
            themeColor: themeColor,
            prefs: _prefs,
          );
        },
      ),
    );
  }

  void _chooseUniversity() async {
    List<dynamic> schools = [];
    String? errorMsg;
    try {
      schools = await ApiService.fetchSchools();
    } catch (e) {
      errorMsg = "Couldn't load schools right now. Please try again later.";
    }
    if (!mounted) return;
    if (errorMsg != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(errorMsg)));
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetContext) => _buildSchoolPicker(sheetContext, schools),
    );
  }

  Widget _buildSchoolPicker(BuildContext modalContext, List<dynamic> schools) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.5,
      maxChildSize: 0.9,
      minChildSize: 0.3,
      builder: (BuildContext draggableSheetContext,
          ScrollController scrollController) {
        final textColor = _isDarkMode ? Colors.white : Colors.black87;
        return Container(
          padding: const EdgeInsets.symmetric(vertical: 16),
          decoration: BoxDecoration(
            color: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: schools.isNotEmpty
              ? ListView.builder(
                  controller: scrollController,
                  itemCount: schools.length,
                  itemBuilder: (ctx, index) {
                    final school = schools[index];
                    final name = school["name"] as String? ?? "Unnamed School";
                    final isSelected =
                        _prefs.schoolId == school["id"].toString();

                    return ListTile(
                      title: Text(
                        name,
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontSize: 18,
                          color: textColor,
                        ),
                      ),
                      trailing: isSelected
                          ? Icon(Icons.check, color: themeColor)
                          : null,
                      onTap: () async {
                        _prefs.schoolId = school["id"].toString();
                        _prefs.schoolName = name;
                        await _prefs.savePreferences();

                        if (!mounted) return;

                        Navigator.pop(context);

                        setState(() {
                          _selectedRestaurants.clear();
                        });
                      },
                    );
                  },
                )
              : Center(
                  child: Text(
                    "No schools available",
                    style: TextStyle(color: textColor),
                  ),
                ),
        );
      },
    );
  }

  void _showRestaurantSelection() async {
    final sid = _prefs.schoolId;
    setState(() => _vendorBarTapped = true);
    if (sid != null && sid.isNotEmpty) {
      List<dynamic> vendors = [];
      String? errorMsg;
      try {
        vendors = await ApiService.fetchVendors(sid);
        _restaurants = vendors
            .map<String>((v) => v['name'] as String? ?? "Unnamed Vendor")
            .toList();
      } catch (e) {
        errorMsg = "Couldn't load vendors right now. Please try again later.";
      }
      if (!mounted) return;
      if (errorMsg != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(errorMsg)));
        return;
      }
      if (_restaurants.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text("No vendors available for this school.")));
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
          // Placeholder for the upcoming Library feature!
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Library feature coming soon! 📚')),
          );
        }
      },
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: (tab["color"] as Color).withOpacity(0.65),
          shape: BoxShape.circle, // Made perfectly round!
        ),
        child: Center(
          child: Icon(tab["icon"] as IconData?, color: Colors.white, size: 24),
        ),
      ),
    );
  }

  // 2. New method: _showGistFilterSheet()
  void _showGistFilterSheet() {
    final categories = [
      'All',
      'Sports',
      'Entertainment',
      'Official',
      'Religion'
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
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
                child: Text(
                  'Filter Gists',
                  style: TextStyle(
                    color: themeColor,
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: controller,
                  itemCount: categories.length,
                  itemBuilder: (_, i) {
                    final cat = categories[i];
                    return RadioListTile<String>(
                      title: Text(
                        cat,
                        style:
                            const TextStyle(color: Colors.white, fontSize: 18),
                      ),
                      value: cat,
                      groupValue: _gistFilter,
                      activeColor: themeColor,
                      onChanged: (val) {
                        setState(() => _gistFilter = val!);
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

  // ── NEW: Sticky Gist Filter Bar (used by the SliverPersistentHeader) ──
  Widget _buildGistFilterBar() {
    final filteredGists = _gistFilter == 'All'
        ? _fetchedGists
        : _fetchedGists.where((g) => g['category'] == _gistFilter).toList();

    final String label = _isGistsLoading
        ? "Gist"
        : filteredGists.isEmpty
            ? "Gist"
            : (_gistFilter == 'All' ? "All Gists" : "$_gistFilter Gists");

    final horizontalBarWidth = MediaQuery.of(context).size.width * 0.85;

    return GestureDetector(
      onTap: _showGistFilterSheet,
      child: Container(
        width: horizontalBarWidth,
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.grey[800],
          borderRadius: BorderRadius.circular(25),
        ),
        child: Row(
          children: [
            Icon(BoxIcons.bxs_megaphone, color: themeColor, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontFamily: 'SanFrancisco',
                  fontSize: 18,
                  color: Color(0xFF4CAF50), // themeColor
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            Icon(Icons.chevron_right, color: themeColor, size: 24),
          ],
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

  @override
  Widget build(BuildContext context) {
    final Color bgColor =
        _isDarkMode ? const Color(0xFF121212) : Colors.grey[100]!;

    return Theme(
      data: _isDarkMode
          ? ThemeData.dark().copyWith(scaffoldBackgroundColor: bgColor)
          : ThemeData.light().copyWith(scaffoldBackgroundColor: bgColor),
      child: Scaffold(
        appBar: _selectedIndex == 0 ? _buildAppBar() : null,
        bottomNavigationBar: _buildCustomFooter(bgColor),

        // --- NEW: UNIVERSAL PLUS BUTTON ---
        floatingActionButton: FloatingActionButton(
          heroTag: 'universal_plus_btn',
          backgroundColor: themeColor,
          elevation: 4,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          onPressed: () => _showUniversalPlusMenu(context),
          child: const Icon(Icons.add, color: Colors.white, size: 32),
        ),

        body: SafeArea(
          child: Stack(
            children: [
              IndexedStack(
                index: _selectedIndex,
                children: [
                  // INDEX 0: HOME
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
                                    width: MediaQuery.of(context).size.width *
                                        0.85,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF1E1E1E),
                                      borderRadius: BorderRadius.circular(25),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16),
                                    child: Row(children: [
                                      Icon(BoxIcons.bxs_store,
                                          color: themeColor, size: 20),
                                      const SizedBox(width: 8),
                                      Expanded(
                                          child: _selectedRestaurants.isNotEmpty
                                              ? SingleChildScrollView(
                                                  scrollDirection:
                                                      Axis.horizontal,
                                                  child: Row(
                                                      children: _selectedRestaurants
                                                          .map((v) => Padding(
                                                              padding: const EdgeInsets.only(
                                                                  right: 12),
                                                              child: Chip(
                                                                  label: Text(v,
                                                                      style: const TextStyle(
                                                                          fontSize:
                                                                              12.6,
                                                                          color: Colors
                                                                              .white)),
                                                                  backgroundColor:
                                                                      const Color(0xFF2A2A2A))))
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
                                  width:
                                      MediaQuery.of(context).size.width * 0.85,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E1E1E),
                                    borderRadius: BorderRadius.circular(25),
                                  ),
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
                                            keyboardType: TextInputType.number,
                                            style: const TextStyle(
                                                fontSize: 12.6,
                                                color: Colors.white),
                                            decoration: const InputDecoration(
                                                hintText: "Enter Budget",
                                                hintStyle: TextStyle(
                                                    color: Colors.white54,
                                                    fontSize: 15.4),
                                                border: InputBorder.none))),
                                    InkWell(
                                        onTap: () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                                builder: (_) =>
                                                    AvailableOptionsScreen(
                                                        userPreferences: _prefs,
                                                        selectedRestaurants:
                                                            _selectedRestaurants))),
                                        child: Container(
                                            decoration: BoxDecoration(
                                                color: themeColor,
                                                shape: BoxShape.circle),
                                            padding: const EdgeInsets.all(6),
                                            child: const Icon(
                                                BoxIcons.bxs_chevron_right,
                                                color: Colors.white,
                                                size: 22))),
                                  ]),
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  width:
                                      MediaQuery.of(context).size.width * 0.85,
                                  height: 60,
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: _colorfulTabs
                                        .map((tab) => _buildCircularTab(tab))
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

                  // INDEX 1: EXPLORE
                  ExploreScreen(userPreferences: _prefs),

                  // INDEX 2: CHATS
                  ChatListScreen(userPreferences: _prefs),

                  // INDEX 3: PROFILE
                  ProfileScreen(
                      userPreferences: _prefs,
                      onSave: () => setState(() => _selectedIndex = 0)),
                ],
              ),
              // --- OUTSIDE THE BOX: Listens silently without rebuilding the whole screen ---
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
                            onTap: () {
                              _scrollController.animateTo(0,
                                  duration: const Duration(milliseconds: 600),
                                  curve: Curves.easeInOut);
                            },
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                  color: themeColor, shape: BoxShape.circle),
                              child: const Icon(Icons.arrow_upward,
                                  color: Colors.white, size: 28),
                            ),
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
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      // These two lines fix the color-changing issue on scroll:
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,

      // --- FIX: Updated to match the new Profile Screen global color! ---
      backgroundColor: _isDarkMode ? const Color(0xFF121212) : Colors.grey[100],
      elevation: 0,
      centerTitle: true,
      leading: Builder(
        builder: (appBarContext) => IconButton(
          icon: const Icon(Icons.notifications, size: 36),
          onPressed: () {
            _showNotifications();
          },
        ),
      ),
      title: Image.asset(
        'assets/images/allowance_logo.png',
        height: 200,
        width: 200,
        fit: BoxFit.contain,
      ),
      actions: [
        IconButton(
          icon: const Icon(BoxIcons.bxs_map, size: 36),
          color: _prefs.schoolId?.isNotEmpty == true
              ? themeColor
              : (_isDarkMode ? Colors.white54 : Colors.black54),
          onPressed: _chooseUniversity,
        )
      ],
    );
  }

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

    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: const Color(0xFF121212),
        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.05))),
      ),
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
                border: sel ? Border.all(color: themeColor, width: 2) : null,
              ),
              child: CircleAvatar(
                radius: 13,
                backgroundColor: const Color(0xFF1E1E1E),
                backgroundImage: NetworkImage(_prefs.avatarUrl!),
              ),
            );
          } else if (isChatTab) {
            // --- CHAT BADGE MOVED TO TASKBAR ---
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
                              color: Colors.redAccent, shape: BoxShape.circle),
                          child: Text(
                            unreadCount > 99 ? '99+' : unreadCount.toString(),
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          } else {
            iconWidget = Icon(
              icons[i],
              size: 28,
              color: sel ? themeColor : Colors.white54,
            );
          }

          return GestureDetector(
            onTap: acts[i],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: iconWidget,
            ),
          );
        }),
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
  void _showNotifications() async {
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
                                        color: Colors.white, size: 26),
                                  )
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
                              // Mark as read silently
                              try {
                                await supabase.from('notifications').update(
                                    {'read': true}).eq('id', notif['id']);
                              } catch (_) {}

                              // Route to correct screen based on type!
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
  // --- 1. UNIVERSAL PLUS MENU (ROW-BY-ROW) ---
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
        initialChildSize: 0.8, // Opens to 80% of screen height
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
                textInputAction: TextInputAction
                    .search, // Puts a "Search" button on keyboard
                onSubmitted: (query) {
                  if (query.trim().isNotEmpty) {
                    Navigator.pop(ctx); // Close the bottom sheet
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ExploreScreen(
                          userPreferences: _prefs,
                          initialQuery: query.trim(), // Passes the typed word
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

            // --- ROW-BY-ROW LAYOUT WITH DESCRIPTIONS ---
            Expanded(
              child: ListView(
                controller: scrollController,
                children: [
                  _buildActionRowItem(
                    icon: Icons.amp_stories,
                    color: Colors.purpleAccent,
                    title: 'Create Story',
                    subtitle: 'Share updates that disappear after 24h',
                    onTap: () async {
                      Navigator.pop(ctx);
                      // ENFORCE 1 ACTIVE STORY FOR FREE USERS
                      if (!isPlus) {
                        final myId = supabase.auth.currentUser?.id;
                        final countResp = await supabase
                            .from('stories')
                            .select('*')
                            .eq('user_id', myId!)
                            .gt('expires_at',
                                DateTime.now().toUtc().toIso8601String())
                            .count(CountOption.exact);
                        if ((countResp.count ?? 0) >= 1) {
                          _showUniversalSubscriptionSheet(
                              customMessage:
                                  "Free users can only have 1 active story at a time. Upgrade to post unlimited 10-day stories!");
                          return;
                        }
                      }
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
                      // ENFORCE 3 MOMENTS MAX FOR FREE USERS
                      if (!isPlus) {
                        final myId = supabase.auth.currentUser?.id;
                        final countResp = await supabase
                            .from('moments')
                            .select('*')
                            .eq('user_id', myId!)
                            .count(CountOption.exact);
                        if ((countResp.count ?? 0) >= 3) {
                          _showUniversalSubscriptionSheet(
                              customMessage:
                                  "Free users can only post a maximum of 3 moments. Upgrade to post unlimited memories!");
                          return;
                        }
                      }
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
                  // --- NEW: REFERRALS WITH LIVE STATS ---
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

            // --- SUBSCRIPTION STATUS FOOTER ---
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
                          _confirmCancelSubscription(); // Opens the cancel dialog
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

  // --- 2. UNIVERSAL SUBSCRIPTION POPUP ---
  void _showUniversalSubscriptionSheet({String? customMessage}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
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

              // CANDY CRUSH STYLE COUNTDOWN / CUSTOM MESSAGES
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

              _buildPerkRow(Icons.block, 'Ad-free experience across the app'),
              _buildPerkRow(Icons.photo_library,
                  'Post unlimited Moments (Free max is 3)'),
              _buildPerkRow(Icons.history,
                  'Save & Backup Chats (Free chats delete in 24h)'),
              _buildPerkRow(Icons.group_add, 'Create custom Campus Groups'),
              _buildPerkRow(
                  Icons.timer, 'Post Stories that last up to 10 days'),
              _buildPerkRow(
                  BoxIcons.bxs_coupon, 'Create & Sell Tickets for events'),
              _buildPerkRow(BoxIcons.bx_food_menu,
                  'Unlimited food orders (No 5-hour wait)'),

              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isProcessingSubscription
                      ? null
                      : () => _subscribeToMembership(context, setModalState),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: themeColor,
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
        );
      }),
    );
  }

  // --- NEW: REFERRAL LEADERBOARD ---
  // --- 1. REPLACE: _showReferralLeaderboard ---
  void _showReferralLeaderboard() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF121212), // Match profile BG
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) {
        int localSegment = 0; // 0 for Users, 1 for Subs
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

                // --- NEW: LEADERBOARD TITLE ADDED HERE ---
                const Text('LEADERBOARD 🏆',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.5)),
                const SizedBox(height: 4),
                Text('Your Code: ${_prefs.username ?? ''}',
                    style: TextStyle(
                        color: themeColor,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),

                // --- UPDATED SEGMENTED CONTROL (Matches Profile Screen exactly) ---
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 60), // Match Profile Screen padding
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                        color: const Color(0xFF1E1E1E), // _card color
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white10)),
                    child: Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => setModalState(() => localSegment = 0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 8), // Reduced height
                              decoration: BoxDecoration(
                                color: localSegment == 0
                                    ? themeColor
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
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
                              padding: const EdgeInsets.symmetric(
                                  vertical: 8), // Reduced height
                              decoration: BoxDecoration(
                                color: localSegment == 1
                                    ? themeColor
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
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
                          final avatarUrl =
                              row['referrer_avatar_url']; // <-- NEW: AVATAR
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
                            // --- UPDATED: ADDED AVATAR TO LEADING ---
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

                // Fixed Bottom Bar for Benefits
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

    final reference = 'sub_${DateTime.now().millisecondsSinceEpoch}';
    final int amountNaira = 700;
    String gateway = 'paystack';
    String? authUrlString;

    try {
      // === ATTEMPT PAYSTACK FIRST ===
      final paystackPayload = {
        'amount': amountNaira * 100, // Paystack uses Kobo
        'email': user.email ?? 'user@allowance.com',
        'reference': reference,
        'plan': 'PLN_2tgtzyaurt8qz0d',
        'metadata': {'plan_code': 'PLN_2tgtzyaurt8qz0d', 'user_id': user.id}
      };

      final resp = await http
          .post(
            Uri.parse('https://api.paystack.co/transaction/initialize'),
            headers: {
              'Authorization': 'Bearer ${dotenv.env['PAYSTACK_SECRET_KEY']}',
              'Content-Type': 'application/json'
            },
            body: jsonEncode(paystackPayload),
          )
          .timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        authUrlString = jsonDecode(resp.body)['data']['authorization_url'];
      } else {
        throw 'Paystack unavailable';
      }
    } catch (e) {
      // === FAILOVER TO FLUTTERWAVE ===
      debugPrint('Paystack failed. Rerouting to Flutterwave... Error: $e');
      gateway = 'flutterwave';

      final flwPayload = {
        'tx_ref': reference,
        'amount': amountNaira.toString(),
        'currency': 'NGN',
        'redirect_url': 'https://allowanceapp.org',
        'customer': {'email': user.email ?? 'user@allowance.com'},
        'payment_plan': dotenv.env['FLW_PLAN_ID'] ?? '',
        // 🔥 FIX: Added 'plan_code' so the Webhook knows to upgrade the user!
        'meta': {
          'user_id': user.id,
          'plan_code': dotenv.env['FLW_PLAN_ID'] ?? 'Allowance_Plus'
        },
        'customizations': {
          'title': 'Allowance Plus',
          'description': 'Subscription payment'
        }
      };

      try {
        final flwResp = await http.post(
          Uri.parse('https://api.flutterwave.com/v3/payments'),
          headers: {
            'Authorization': 'Bearer ${dotenv.env['FLW_SECRET_KEY']}',
            'Content-Type': 'application/json'
          },
          body: jsonEncode(flwPayload),
        );

        if (flwResp.statusCode == 200) {
          authUrlString = jsonDecode(flwResp.body)['data']['link'];
        } else {
          debugPrint('Flutterwave Error Body: ${flwResp.body}');
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
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not launch payment page')));
        }
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

  Future<bool> _pollAndProcessVerification(String reference, String gateway,
      {int maxAttempts = 10,
      Duration interval = const Duration(seconds: 3)}) async {
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        if (gateway == 'paystack') {
          final response = await http.get(
            Uri.parse('https://api.paystack.co/transaction/verify/$reference'),
            headers: {
              'Authorization': 'Bearer ${dotenv.env['PAYSTACK_SECRET_KEY']}'
            },
          );
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            if (data['status'] == true &&
                data['data']?['status'] == 'success') {
              await _activateSubscriptionDb(
                  data['data']['customer']?['customer_code'],
                  data['data']['subscription_code']);
              return true;
            }
          }
        } else if (gateway == 'flutterwave') {
          final response = await http.get(
            Uri.parse(
                'https://api.flutterwave.com/v3/transactions/verify_by_txref?tx_ref=$reference'),
            headers: {
              'Authorization': 'Bearer ${dotenv.env['FLW_SECRET_KEY']}'
            },
          );
          if (response.statusCode == 200) {
            final data = jsonDecode(response.body);
            if (data['status'] == 'success' &&
                data['data']?['status'] == 'successful') {
              await _activateSubscriptionDb('FLW_NATIVE', 'FLW_SUB');
              return true;
            }
          }
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
          width: MediaQuery.of(context).size.width,
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

  // --- NEW: THIS FIXES THE SCROLLING LAG! ---
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _isMuted = widget.isMutedInitial;

    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted && !_isDisposed) _fetchCommentCount();
    });
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
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
      final res = await Supabase.instance.client
          .from('gist_comments')
          .select('id')
          .eq('gist_id', widget.gistId)
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

  Future<List<dynamic>> _fetchFriends(String myId) async {
    try {
      final res = await Supabase.instance.client
          .from('followers')
          .select('following_id')
          .eq('follower_id', myId);

      final followingIds = res.map((e) => e['following_id']).toList();
      if (followingIds.isEmpty) return [];

      final profilesRes = await Supabase.instance.client
          .from('profiles')
          .select('id, username, avatar_url')
          .inFilter('id', followingIds);

      return profilesRes;
    } catch (e) {
      return [];
    }
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

      for (String friendId in friendIds) {
        final response = await Supabase.instance.client.rpc(
            'get_or_create_personal_chat',
            params: {'user_a': myId, 'user_b': friendId});
        final chatId = response.toString();

        await Supabase.instance.client.from('messages').insert({
          'chat_id': chatId,
          'sender_id': myId,
          // --- UPDATED GIST SHARE TEXT ---
          'content':
              'Check out this Gist on Allowance!\n$truncatedTitle\n$gistLink',
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
    final String gistLink =
        'https://www.allowanceapp.org/gist/${widget.gistId}';

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
                  const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text('Share Gist',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                  ),
                  ListTile(
                    leading: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: Colors.grey[800], shape: BoxShape.circle),
                      child: const Icon(Icons.share, color: Colors.white),
                    ),
                    title: const Text('Share to other apps',
                        style: TextStyle(color: Colors.white)),
                    onTap: () {
                      Navigator.pop(ctx);
                      // --- UPDATED GIST SHARE TEXT ---
                      Share.share(
                          'Check out this Gist on Allowance!\n$truncatedTitle\n$gistLink');
                    },
                  ),
                  const Divider(color: Colors.white10),
                  const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Text('Send to friends',
                        style: TextStyle(color: Colors.white54, fontSize: 14)),
                  ),
                  Expanded(
                    child: FutureBuilder<List<dynamic>>(
                        future: friendsFuture,
                        builder: (context, snapshot) {
                          if (snapshot.connectionState ==
                              ConnectionState.waiting) {
                            return Center(
                                child: CircularProgressIndicator(
                                    color: widget.themeColor));
                          }
                          final friends = snapshot.data ?? [];
                          if (friends.isEmpty) {
                            return const Center(
                                child: Text("Follow people to see them here",
                                    style: TextStyle(color: Colors.white54)));
                          }
                          return ListView.builder(
                            controller: scrollController,
                            itemCount: friends.length,
                            itemBuilder: (context, index) {
                              final friend = friends[index];
                              final friendId = friend['id'];
                              final isSelected =
                                  selectedFriends.contains(friendId);

                              return ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: Colors.grey[800],
                                  backgroundImage: friend['avatar_url'] != null
                                      ? CachedNetworkImageProvider(
                                          friend['avatar_url'])
                                      : null,
                                  child: friend['avatar_url'] == null
                                      ? const Icon(Icons.person,
                                          color: Colors.white54)
                                      : null,
                                ),
                                title: Text(friend['username'] ?? 'User',
                                    style:
                                        const TextStyle(color: Colors.white)),
                                trailing: Checkbox(
                                  value: isSelected,
                                  activeColor: widget.themeColor,
                                  checkColor: Colors.black,
                                  onChanged: (bool? value) {
                                    setModalState(() {
                                      if (value == true) {
                                        selectedFriends.add(friendId);
                                      } else {
                                        selectedFriends.remove(friendId);
                                      }
                                    });
                                  },
                                ),
                                onTap: () {
                                  setModalState(() {
                                    if (isSelected) {
                                      selectedFriends.remove(friendId);
                                    } else {
                                      selectedFriends.add(friendId);
                                    }
                                  });
                                },
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
                                borderRadius: BorderRadius.circular(12)),
                          ),
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
                                          backgroundColor: Colors.green),
                                    );
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
    super.build(context); // <-- REQUIRED BY KEEPALIVE MIXIN

    final imageUrl = (widget.gist['image_url'] as String?) ?? '';
    final imageUrls =
        (widget.gist['image_urls'] as List?)?.cast<String>() ?? [];
    final mediaType = (widget.gist['media_type'] as String?) ?? 'image';
    final gistUrl = (widget.gist['url'] as String?) ?? '';
    final String fullTitle = widget.gist['title'] as String? ?? '';
    final imagesToShow = imageUrls.isNotEmpty
        ? imageUrls
        : (imageUrl.isNotEmpty ? [imageUrl] : []);

    final profileData = widget.gist['profiles'];
    final userId = widget.gist['user_id']?.toString() ?? '';
    final String username =
        (profileData is Map ? profileData['username']?.toString() : null) ??
            'User';
    final avatarUrl =
        (profileData is Map) ? profileData['avatar_url'] as String? : null;

    // --- 1. MEDIA WIDGET ---
    Widget mediaWidget;
    if (mediaType == 'video') {
      final controller = widget.videoController;
      mediaWidget = controller != null && controller.value.isInitialized
          ? Column(
              children: [
                AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      GestureDetector(
                        onTap: () {
                          controller.value.isPlaying
                              ? controller.pause()
                              : controller.play();
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
                                    color: Colors.black.withOpacity(0.6),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.play_arrow_rounded,
                                      color: Colors.white, size: 54),
                                );
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
                                _isMuted ? Icons.volume_off : Icons.volume_up,
                                color: Colors.white,
                                size: 16),
                          ),
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
                        bufferedColor: Colors.white24)),
              ],
            )
          : Container(
              height: 300,
              color: Colors.black,
              child: const Center(
                  child: CircularProgressIndicator(color: Color(0xFF4CAF50))));
    } else {
      mediaWidget = imagesToShow.isEmpty
          ? Container(height: 300, color: Colors.grey[900])
          : SizedBox(
              width: double.infinity,
              height: MediaQuery.of(context).size.width,
              child: Stack(
                children: [
                  PageView.builder(
                    itemCount: imagesToShow.length,
                    onPageChanged: (p) => setState(() => _localPageIndex = p),
                    itemBuilder: (ctx, i) => GestureDetector(
                      onTap: () => _expandMedia(imagesToShow[i]),
                      onDoubleTap: _triggerDoubleTapLike,
                      child: CachedNetworkImage(
                        imageUrl: imagesToShow[i],
                        fit: BoxFit.cover,
                        // FIX: Limits the image size in RAM, drastically reducing OOM crashes!
                        memCacheWidth: 600,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 12,
                    left: 12,
                    child: GestureDetector(
                      onTap: () => _expandMedia(imagesToShow[_localPageIndex]),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: const BoxDecoration(
                            color: Colors.black54, shape: BoxShape.circle),
                        child: const Icon(Icons.fullscreen,
                            color: Colors.white, size: 20),
                      ),
                    ),
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
                                color: Colors.white, fontSize: 12)),
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
            );
    }

    // --- 2. ACTION BAR ---
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
                  size: 28),
            ),
          ),
          GestureDetector(
            onTap: () async {
              await widget.onShowComments();
              _fetchCommentCount();
            },
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Icon(CupertinoIcons.chat_bubble,
                  color: Colors.white, size: 26),
            ),
          ),
          GestureDetector(
            onTap: () => _showShipSheet(context),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('🚀', style: TextStyle(fontSize: 22)),
            ),
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
                  color: Colors.white, size: 26),
            ),
          ),
        ],
      ),
    );

    // --- 3. CAPTION AREA ---
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
                    fontSize: 13),
              ),
            ),
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              if (userId.isNotEmpty) {
                UniversalProfileCard.show(context, userId, widget.prefs);
              }
            },
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: Colors.grey[800],
                  backgroundImage: avatarUrl != null
                      ? CachedNetworkImageProvider(avatarUrl,
                          maxWidth: 100, maxHeight: 100)
                      : null,
                  child: avatarUrl == null
                      ? Text(
                          username.isNotEmpty ? username[0].toUpperCase() : 'U',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold))
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
                                text: '$username  ',
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
                                          height: 1.5)),
                                ),
                              ),
                            );
                          },
                          child: const Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Text("see more...",
                                style: TextStyle(
                                    color: Color(0xFF4CAF50),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13)),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (gistUrl.isNotEmpty) ...[
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () async {
                final uri = Uri.tryParse(gistUrl);
                if (uri != null && await canLaunchUrl(uri)) {
                  await launchUrl(uri, mode: LaunchMode.externalApplication);
                }
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
        children: [mediaWidget, actionBar, captionArea],
      ),
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
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

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
