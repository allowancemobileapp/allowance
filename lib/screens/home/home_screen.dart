// lib/screens/home/home_screen.dart
import 'dart:async';
import 'package:allowance/screens/chat/chat_list_screen.dart';
import 'package:allowance/screens/home/media_editor_screen.dart';
import 'package:allowance/widgets/stories_bar.dart';
import 'package:allowance/widgets/universal_profile_card.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/home/available_options_screen.dart';
import 'package:allowance/screens/home/favorites_screen.dart';
import 'package:allowance/screens/home/subscription_screen.dart';
import 'package:allowance/screens/profile/profile_screen.dart';
import 'package:allowance/screens/home/ticket_screen.dart';
import 'package:image_picker/image_picker.dart';
import 'package:share_plus/share_plus.dart';
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
    {"label": "Tickets", "icon": BoxIcons.bxs_chat, "color": Colors.purple},
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

  // NEW: track loading vs loaded-with-zero-items
  bool _isGistsLoading = true;

  String _gistFilter = 'All';
  final Map<int, int> _gistLikeCounts = {};
  final Set<int> _likedGistIds = {};
  final ScrollController _scrollController = ScrollController(); // The listener
  bool _showBackToTopButton = false; // The visibility state

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

  @override
  void initState() {
    super.initState();
    _prefs = widget.userPreferences ?? UserPreferences();
    _scrollController.addListener(() {
      setState(() {
        _showBackToTopButton =
            _scrollController.offset > 300; // Show after 300 pixels
      });
    });
    _budgetFocusNode.addListener(() => setState(() {}));
    _pageController = PageController(viewportFraction: 0.85);
    _budgetController.text = _prefs.budget?.toString() ?? "";
    _fetchGistsAndStartSlideshow();
  }

  @override
  void dispose() {
    _disposeVideoControllers(); // ← NEW
    _slideshowTimer?.cancel();
    _pageController.dispose();
    _budgetController.dispose();
    _budgetFocusNode.dispose();
    _restaurantsController.dispose();
    _restaurantFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _fetchGistsAndStartSlideshow() async {
    setState(() => _isGistsLoading = true);
    try {
      final List<Map<String, dynamic>> raw = await supabase
          .from('gists')
          .select('''
            id, user_id, title, image_url, image_urls, media_type, type, school_id, url, created_at, category,
            profiles:user_id (username, avatar_url, bio)
          ''') // <--- FIX: Added 'user_id' to the select query here!
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

      // ==========================================
      // SPEED HACK: PRELOAD IMAGES INTO RAM
      // ==========================================
      if (mounted) {
        for (var i = 0; i < list.length && i < 5; i++) {
          final gist = list[i];
          final mediaType = gist['media_type'] as String?;
          final imageUrl = gist['image_url'] as String?;

          if (mediaType != 'video' && imageUrl != null && imageUrl.isNotEmpty) {
            precacheImage(CachedNetworkImageProvider(imageUrl), context);
          }
        }
      }

      if (!mounted) return;
      setState(() {
        _fetchedGists = list;
        _isGistsLoading = false;
      });

      await _loadGistLikes();
      await _initializeVideoControllers();

      if (_fetchedGists.isEmpty) {
        setState(() => _fetchedGists = List.from(_fallbackGists));
      }
      if (_fetchedGists.isNotEmpty) _startSlideshow();
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
      _startSlideshow();
    }
  }

  // ==========================================
  // SPEED HACK: CACHE VIDEOS TO PHONE STORAGE
  // ==========================================
  Future<void> _initializeVideoControllers() async {
    for (var gist in _fetchedGists) {
      final mediaType = gist['media_type'] as String?;

      if (mediaType == 'video') {
        final gistId = gist['id'] as int;
        final videoUrl = (gist['image_url'] as String?) ?? '';

        if (videoUrl.isNotEmpty) {
          try {
            // 1. Check if the video is already saved in the phone's physical cache
            var fileInfo =
                await DefaultCacheManager().getFileFromCache(videoUrl);
            VideoPlayerController controller;

            if (fileInfo != null) {
              // PLAY FROM LOCAL DISK: Extremely fast, zero network buffering
              controller = VideoPlayerController.file(fileInfo.file);
            } else {
              // PLAY FROM NETWORK: But silently download to the disk cache in the background for next time!
              controller =
                  VideoPlayerController.networkUrl(Uri.parse(videoUrl));
              DefaultCacheManager().downloadFile(videoUrl);
            }

            await controller.initialize();
            controller.setLooping(true);
            _videoControllers[gistId] = controller;
            _isVideoMuted[gistId] = true;
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

  void _startSlideshow() {
    _slideshowTimer?.cancel();
    if (_fetchedGists.isEmpty) return;
    _slideshowTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_pageController.hasClients && _fetchedGists.isNotEmpty) {
        int nextPage = (_pageController.page?.round() ?? 0) + 1;
        _pageController.animateToPage(nextPage,
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOut);
      }
    });
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

  // 3. Updated _buildGistSlideshow() – added megaphone icon + tap to open filter sheet
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
      padding: const EdgeInsets.only(bottom: 40, top: 8),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (ctx, idx) {
            final gist = filteredGists[idx];
            final gistId = (gist['id'] is int)
                ? gist['id'] as int
                : int.tryParse(gist['id'].toString()) ?? 0;

            // Using an isolated StatefulWidget drastically improves scroll performance
            return _GistItemCard(
              key: ValueKey(
                  gistId), // Critical for Flutter to cache the scroll items
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
          childCount: filteredGists.length,
          addAutomaticKeepAlives: true,
          addRepaintBoundaries: true,
        ),
      ),
    );
  }

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
    final Color bgColor = _isDarkMode ? Colors.grey[900]! : Colors.grey[100]!;
    return Theme(
      data: _isDarkMode
          ? ThemeData.dark().copyWith(scaffoldBackgroundColor: bgColor)
          : ThemeData.light().copyWith(scaffoldBackgroundColor: bgColor),
      child: Scaffold(
        appBar: _selectedIndex == 0 ? _buildAppBar() : null,
        bottomNavigationBar: _buildCustomFooter(bgColor),
        floatingActionButton: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_selectedIndex == 3) ...[
              FloatingActionButton(
                heroTag: 'add_memory_btn',
                mini: true,
                backgroundColor: themeColor,
                onPressed: () => _pickMemoryFlow(context),
                child: const Icon(Icons.add, color: Colors.white, size: 24),
              ),
              const SizedBox(height: 12),
            ],
            FloatingActionButton(
              heroTag: 'chat_btn',
              backgroundColor: Colors.transparent,
              elevation: 0,
              child: Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: const Color(0xFF4CAF50),
                  borderRadius: BorderRadius.circular(18),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    )
                  ],
                ),
                child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: supabase.auth.currentUser == null
                      ? const Stream.empty()
                      : supabase
                          .from('messages')
                          .stream(primaryKey: ['id']).eq('is_read', false),
                  builder: (context, snapshot) {
                    final myId = supabase.auth.currentUser?.id;
                    final allUnread = snapshot.data ?? [];

                    final unreadCount = allUnread
                        .where((msg) => msg['sender_id'] != myId)
                        .length;

                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        const Center(
                          child: Icon(
                            Icons.chat_bubble_rounded,
                            color: Colors.white,
                            size: 28,
                          ),
                        ),
                        if (unreadCount > 0)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 2),
                              constraints: const BoxConstraints(
                                minWidth: 18,
                                minHeight: 18,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.redAccent,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: const Color(0xFF4CAF50),
                                  width: 1.5,
                                ),
                              ),
                              child: Center(
                                child: Text(
                                  unreadCount > 99
                                      ? '99+'
                                      : unreadCount.toString(),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ChatListScreen(userPreferences: _prefs),
                  ),
                );
              },
            ),
          ],
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
                                    width: MediaQuery.of(context).size.width *
                                        0.85,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      color: _isDarkMode
                                          ? Colors.grey[800]
                                          : Colors.grey[200],
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
                                                                      _isDarkMode ? Colors.grey[700] : Colors.grey[300])))
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
                                    color: _isDarkMode
                                        ? Colors.grey[800]
                                        : Colors.grey[200],
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
                                // ==========================================
                                // CHANGED to spaceBetween to align perfectly with the edges!
                                // ==========================================
                                SizedBox(
                                  width:
                                      MediaQuery.of(context).size.width * 0.85,
                                  height: 60,
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment
                                        .spaceBetween, // <-- Fixes the spacing
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
                  FavoritesScreen(userPreferences: _prefs),
                  SubscriptionScreen(
                      userPreferences: _prefs, themeColor: themeColor),
                  ProfileScreen(
                      userPreferences: _prefs,
                      onSave: () => setState(() => _selectedIndex = 0)),
                ],
              ),
              if (_showBackToTopButton)
                Positioned(
                  bottom: 20,
                  left: 0,
                  right: 0,
                  child: Center(
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
      // These two lines fix the color-changing issue:
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,

      backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
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
      BoxIcons.bxs_credit_card,
      BoxIcons.bxs_user
    ];
    // Indices that map to your IndexedStack order (keep these as you had them)
    final idxs = [0, 2, 3];
    final acts = [
      () => setState(() => _selectedIndex = 0),
      () => setState(() => _selectedIndex = 2),
      () => setState(() => _selectedIndex = 3)
    ];

    return Container(
      height: 56,
      decoration: BoxDecoration(color: screenBgColor),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(icons.length, (i) {
          final sel = _selectedIndex == idxs[i];
          final isProfileTab = idxs[i] == 3;

          // Use avatar if this is profile tab and avatar exists
          Widget iconWidget;
          if (isProfileTab &&
              _prefs.avatarUrl != null &&
              _prefs.avatarUrl!.isNotEmpty) {
            iconWidget = CircleAvatar(
              radius: 14,
              backgroundColor: Colors.grey[800],
              backgroundImage: NetworkImage(_prefs.avatarUrl!),
            );
          } else {
            iconWidget = Icon(
              icons[i],
              size: 28,
              color: sel
                  ? themeColor
                  : (_isDarkMode ? Colors.white70 : Colors.black54),
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
  final Future<void> Function() onShowComments; // <-- Changed to Future
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

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _isMuted = widget.isMutedInitial;
    _fetchCommentCount();
  }

  Future<void> _fetchCommentCount() async {
    try {
      final res = await Supabase.instance.client
          .from('gist_comments')
          .select('id')
          .eq('gist_id', widget.gistId)
          .count(CountOption.exact);
      if (mounted) setState(() => _commentCount = res.count);
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

  // --- NEW: Fetch friends for shipping ---
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

  // --- NEW: Send Gist to a friend's DM ---
  // --- UPDATED: Send Gist to MULTIPLE friends' DMs ---
  Future<void> _sendGistToFriends(
      Set<String> friendIds, String truncatedTitle, String gistLink) async {
    try {
      final myId = Supabase.instance.client.auth.currentUser!.id;

      final imageUrl = widget.gist['image_url'] ?? '';
      final mediaUrlToUse = widget.gist['image_urls'] != null &&
              (widget.gist['image_urls'] as List).isNotEmpty
          ? widget.gist['image_urls'][0]
          : imageUrl;

      // Loop through selected friends and send the message to each
      for (String friendId in friendIds) {
        final response = await Supabase.instance.client.rpc(
            'get_or_create_personal_chat',
            params: {'user_a': myId, 'user_b': friendId});
        final chatId = response.toString();

        await Supabase.instance.client.from('messages').insert({
          'chat_id': chatId,
          'sender_id': myId,
          'content':
              'Check out this Gist: $truncatedTitle\n$gistLink', // Deep link format!
          'media_url': mediaUrlToUse,
          'media_type': widget.gist['media_type'] ?? 'image',
          'is_read': false,
        });
      }
    } catch (e) {
      debugPrint('Failed to batch send gist: $e');
    }
  }

  // --- UPDATED: Show Ship (Share) Sheet with Multi-Select ---
  // --- UPDATED: Show Ship (Share) Sheet with Multi-Select ---
  // --- UPDATED: Show Ship (Share) Sheet with Multi-Select ---
  void _showShipSheet(BuildContext context) {
    final myId = Supabase.instance.client.auth.currentUser?.id;
    if (myId == null) return;

    // 1. Truncate title to 50 characters with an ellipsis
    final String title = widget.gist['title'] ?? '';
    final String truncatedTitle =
        title.length > 50 ? '${title.substring(0, 50)}...' : title;

    // 2. Use your ACTUAL domain!
    final String gistLink =
        'https://www.allowanceapp.org/gist/${widget.gistId}';

    // FIX THE LAG: Cache the future outside the StatefulBuilder so it only loads ONCE!
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

                  // External Share (WhatsApp, Twitter, etc.)
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
                      Share.share('$truncatedTitle\n$gistLink');
                    },
                  ),
                  const Divider(color: Colors.white10),

                  const Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Text('Send to friends',
                        style: TextStyle(color: Colors.white54, fontSize: 14)),
                  ),

                  // In-App Share (Multi-Select List)
                  Expanded(
                    child: FutureBuilder<List<dynamic>>(
                        future:
                            friendsFuture, // <-- We now use the cached future!
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
                                      if (value == true)
                                        selectedFriends.add(friendId);
                                      else
                                        selectedFriends.remove(friendId);
                                    });
                                  },
                                ),
                                onTap: () {
                                  setModalState(() {
                                    if (isSelected)
                                      selectedFriends.remove(friendId);
                                    else
                                      selectedFriends.add(friendId);
                                  });
                                },
                              );
                            },
                          );
                        }),
                  ),

                  // Send Button
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
    super.build(context);

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
                        onTap: () => setState(() {
                          controller.value.isPlaying
                              ? controller.pause()
                              : controller.play();
                        }),
                        child: VideoPlayer(controller),
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
                    itemBuilder: (ctx, i) => CachedNetworkImage(
                      imageUrl: imagesToShow[i],
                      fit: BoxFit.cover,
                      memCacheWidth: 800,
                      memCacheHeight: 800,
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
                ],
              ),
            );
    }

    // --- 2. ACTION BAR (Centered with tight spacing, no text underneath) ---
    Widget actionBar = Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center, // Centered!
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: Icon(widget.isLiked ? Icons.favorite : Icons.favorite_border,
                color: widget.isLiked ? Colors.red : Colors.white, size: 28),
            onPressed: widget.onToggleLike,
          ),
          const SizedBox(width: 16),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(CupertinoIcons.chat_bubble,
                color: Colors.white, size: 26),
            onPressed: () async {
              await widget.onShowComments();
              _fetchCommentCount(); // Refresh count
            },
          ),
          const SizedBox(width: 16),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Text('🚀', style: TextStyle(fontSize: 22)),
            onPressed: () => _showShipSheet(context), // <--- FIRED UP
          ),
          const SizedBox(width: 16),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.download_for_offline_outlined,
                color: Colors.white, size: 26),
            onPressed: () {
              final target = imagesToShow.isNotEmpty
                  ? imagesToShow[_localPageIndex]
                  : imageUrl;
              if (target.isNotEmpty) widget.onDownload(target);
            },
          ),
        ],
      ),
    );

    // --- 3. CAPTION AREA (Counts restored to the left side) ---
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
                      ? Text(username[0].toUpperCase(),
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
          const SizedBox(height: 30),
        ],
      ),
    );

    return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [mediaWidget, actionBar, captionArea]);
  }
} // <--- THIS CLOSING BRACKET FIXES YOUR ERROR

// ========================================================================
// GIST COMMENTS SHEET CLASS
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
  final FocusNode _focusNode =
      FocusNode(); // NEW: Focus node to pop open keyboard
  final supabase = Supabase.instance.client;
  bool _isPosting = false;

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
    return Padding(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: FractionallySizedBox(
        heightFactor: 0.7,
        child: Column(
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
              child: Text('Comments',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ),
            const Divider(color: Colors.white10, height: 1),
            Expanded(
              child: StreamBuilder<List<Map<String, dynamic>>>(
                  stream: supabase
                      .from('gist_comments')
                      .stream(primaryKey: ['id'])
                      .eq('gist_id', int.parse(widget.gistId))
                      .order('created_at', ascending: true),
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
                            // FIX: Added 'school_name' to the select query!
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
                                leading: GestureDetector(
                                  onTap: () => UniversalProfileCard.show(
                                      context, userId, widget.userPreferences),
                                  child: CircleAvatar(
                                    backgroundColor: Colors.grey[800],
                                    backgroundImage:
                                        profile?['avatar_url'] != null
                                            ? CachedNetworkImageProvider(
                                                profile!['avatar_url'])
                                            : null,
                                    child: profile?['avatar_url'] == null
                                        ? const Icon(Icons.person,
                                            color: Colors.white54, size: 20)
                                        : null,
                                  ),
                                ),
                                title: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () => UniversalProfileCard.show(
                                      context, userId, widget.userPreferences),
                                  child: Row(
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
                                      // NEW: Show School Name safely without overflowing
                                      if (profile?['school_name'] != null &&
                                          profile!['school_name']
                                              .toString()
                                              .isNotEmpty) ...[
                                        const Text(' • ',
                                            style: TextStyle(
                                                color: Colors.white38,
                                                fontSize: 11)),
                                        Expanded(
                                          child: Text(
                                            profile['school_name'],
                                            style: const TextStyle(
                                                color: Colors.white54,
                                                fontSize: 11),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(width: 8),
                                      Text(_timeAgo(comment['created_at']),
                                          style: const TextStyle(
                                              color: Colors.white38,
                                              fontSize: 11)),
                                    ],
                                  ),
                                ),
                                // NEW: Adding the Reply Button underneath the text
                                subtitle: Padding(
                                  padding: const EdgeInsets.only(top: 4.0),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(comment['content'] ?? '',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 14)),
                                      const SizedBox(height: 6),
                                      GestureDetector(
                                        onTap: () {
                                          _commentController.text =
                                              '@${profile?['username']} ';
                                          FocusScope.of(context)
                                              .requestFocus(_focusNode);
                                        },
                                        child: const Text('Reply',
                                            style: TextStyle(
                                                color: Colors.white54,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold)),
                                      ),
                                    ],
                                  ),
                                ),
                                trailing: isMyComment
                                    ? IconButton(
                                        icon: const Icon(Icons.more_vert,
                                            color: Colors.white54, size: 18),
                                        onPressed: () => _showCommentOptions(
                                            comment['id'], comment['content']),
                                      )
                                    : null,
                              );
                            });
                      },
                    );
                  }),
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
                      focusNode: _focusNode, // Hooked up focus node here
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
                  GestureDetector(
                    onTap: _isPosting ? null : _postComment,
                    child: _isPosting
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                color: widget.themeColor, strokeWidth: 2))
                        : Text('Post',
                            style: TextStyle(
                                color: widget.themeColor,
                                fontWeight: FontWeight.bold,
                                fontSize: 16)),
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
