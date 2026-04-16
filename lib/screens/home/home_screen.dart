// lib/screens/home/home_screen.dart
import 'dart:async';
import 'package:allowance/widgets/stories_bar.dart';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/home/available_options_screen.dart';
import 'package:allowance/screens/home/favorites_screen.dart';
import 'package:allowance/screens/home/subscription_screen.dart';
import 'package:allowance/screens/profile/profile_screen.dart';
import 'package:allowance/screens/home/ticket_screen.dart';
import 'order_screen.dart';
import 'package:allowance/services/api_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:developer' as developer;
import 'package:gal/gal.dart';
import 'package:video_player/video_player.dart';

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
  final List<Map<String, dynamic>> _colorfulTabs = [
    {"label": "Favorites", "icon": BoxIcons.bxs_heart, "color": Colors.orange},
    {"label": "Tickets", "icon": BoxIcons.bxs_chat, "color": Colors.purple},
    {
      "label": "Order",
      "icon": BoxIcons.bx_food_menu,
      "color": Colors.teal
    }, // ← food icon
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
            id, title, image_url, image_urls, media_type, type, school_id, url, created_at, category,
            profiles:user_id (username, avatar_url, bio)
          ''')
          .eq('paid', true)
          .eq('status', 'active')
          .order('created_at', ascending: false)
          .limit(50);

      if (!mounted) return;

      List<Map<String, dynamic>> list = raw;

      // Filter by school (same as before)
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

      if (!mounted) return;
      setState(() {
        _fetchedGists = list;
        _isGistsLoading = false;
      });

      await _loadGistLikes();
      await _initializeVideoControllers(); // ← NEW

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

  // Initialize video controllers for all video gists
  Future<void> _initializeVideoControllers() async {
    for (var gist in _fetchedGists) {
      final mediaType = gist['media_type'] as String?;
      if (mediaType == 'video') {
        final gistId = gist['id'] as int;
        final videoUrl = (gist['image_url'] as String?) ?? '';

        if (videoUrl.isNotEmpty) {
          final controller =
              VideoPlayerController.networkUrl(Uri.parse(videoUrl));
          await controller.initialize();
          controller.setLooping(true);
          _videoControllers[gistId] = controller;
          _isVideoMuted[gistId] = true; // start muted like Instagram
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

  void _showProfileCard(String username, String? avatarUrl, String? bio) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.45,
        minChildSize: 0.35,
        maxChildSize: 0.75,
        expand: false,
        builder: (_, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Color(0xFF1E1E1E),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.all(24),
            children: [
              Center(
                child: CircleAvatar(
                  radius: 52,
                  backgroundColor: Colors.grey[800],
                  backgroundImage: avatarUrl != null && avatarUrl.isNotEmpty
                      ? NetworkImage(avatarUrl)
                      : null,
                  child: avatarUrl == null || avatarUrl.isEmpty
                      ? Text(
                          username.isNotEmpty ? username[0].toUpperCase() : '?',
                          style: const TextStyle(
                              fontSize: 40, color: Colors.white))
                      : null,
                ),
              ),
              const SizedBox(height: 16),
              Text('@$username',
                  style: const TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: Colors.white),
                  textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(bio?.trim().isNotEmpty == true ? bio! : 'No bio yet',
                  style: TextStyle(
                      fontSize: 16,
                      color: bio?.trim().isNotEmpty == true
                          ? Colors.white70
                          : Colors.white54,
                      height: 1.5),
                  textAlign: TextAlign.center),
              const SizedBox(height: 32),
              Align(
                alignment: Alignment.center,
                child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close',
                        style:
                            TextStyle(color: Color(0xFF4CAF50), fontSize: 18))),
              ),
            ],
          ),
        ),
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

  Widget _buildRectangularTab(Map<String, dynamic> tab) {
    return InkWell(
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
        }
      },
      child: Container(
        width: 130,
        height: 42,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
            color: (tab["color"] as Color).withOpacity(0.65),
            borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(tab["icon"] as IconData?, color: Colors.white, size: 20),
          const SizedBox(width: 6),
          Text(tab["label"] as String,
              style: const TextStyle(
                  fontFamily: 'SanFrancisco',
                  fontSize: 14,
                  color: Colors.white),
              overflow: TextOverflow.ellipsis)
        ]),
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

  // 3. Updated _buildGistSlideshow() – added megaphone icon + tap to open filter sheet
  // 3. Updated _buildGistSlideshow() – longer titles + "...see more"
  Widget _buildGistSlideshow() {
    final filteredGists = _gistFilter == 'All'
        ? _fetchedGists
        : _fetchedGists.where((g) => g['category'] == _gistFilter).toList();

    if (_isGistsLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 40, top: 8),
      itemCount: filteredGists.isEmpty ? 0 : filteredGists.length,
      itemBuilder: (ctx, idx) {
        final gist = filteredGists[idx];

        final imageUrl = (gist['image_url'] as String?) ?? '';
        final imageUrls = (gist['image_urls'] as List?)?.cast<String>() ?? [];
        final mediaType = (gist['media_type'] as String?) ?? 'image';
        final gistUrl = (gist['url'] as String?) ?? '';
        final fullTitle = gist['title'] as String? ?? '';

        final profileData = gist['profiles'];
        final gistId = (gist['id'] is int)
            ? gist['id'] as int
            : int.tryParse(gist['id'].toString()) ?? 0;

        final username =
            (profileData is Map) ? profileData['username'] as String? : null;
        final avatarUrl =
            (profileData is Map) ? profileData['avatar_url'] as String? : null;
        final bio = (profileData is Map) ? profileData['bio'] as String? : null;

        final likeCount = _gistLikeCounts[gistId] ?? 0;
        final isLiked = _likedGistIds.contains(gistId);

        final imagesToShow = imageUrls.isNotEmpty
            ? imageUrls
            : (imageUrl.isNotEmpty ? [imageUrl] : []);

        int currentPage = 0;

        // ====================== VIDEO GIST ======================
        if (mediaType == 'video') {
          final controller = _videoControllers[gistId];
          final isMuted = _isVideoMuted[gistId] ?? true;

          return Padding(
            padding: const EdgeInsets.only(bottom: 32.0),
            child: Column(
              children: [
                SizedBox(
                  height: MediaQuery.of(context).size.height * 0.36,
                  width: MediaQuery.of(context).size.width * 0.85,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(24),
                    child: controller != null && controller.value.isInitialized
                        ? Stack(
                            fit: StackFit.expand,
                            children: [
                              VideoPlayer(controller),

                              // Tap anywhere to play/pause
                              GestureDetector(
                                onTap: () {
                                  if (controller.value.isPlaying) {
                                    controller.pause();
                                  } else {
                                    controller.play();
                                  }
                                  setState(() {});
                                },
                              ),

                              // MUTE BUTTON → MOVED TO BOTTOM LEFT
                              Positioned(
                                bottom: 12,
                                left: 12,
                                child: GestureDetector(
                                  onTap: () {
                                    setState(() {
                                      _isVideoMuted[gistId] = !isMuted;
                                      controller.setVolume(isMuted ? 1.0 : 0.0);
                                    });
                                  },
                                  child: CircleAvatar(
                                    backgroundColor: Colors.black54,
                                    radius: 20,
                                    child: Icon(
                                      isMuted
                                          ? Icons.volume_off
                                          : Icons.volume_up,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                ),
                              ),

                              // PROGRESS BAR
                              Positioned(
                                bottom: 12,
                                left: 52,
                                right: 12,
                                child: VideoProgressIndicator(
                                  controller,
                                  allowScrubbing: true,
                                  colors: const VideoProgressColors(
                                    playedColor: Color(0xFF4CAF50),
                                    bufferedColor: Colors.white24,
                                    backgroundColor: Colors.black26,
                                  ),
                                ),
                              ),

                              // LINK BUTTON (top right) - if URL exists
                              if (gistUrl.isNotEmpty)
                                Positioned(
                                  top: 12,
                                  right: 12,
                                  child: Material(
                                    color: Colors.transparent,
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(30),
                                      onTap: () async {
                                        final uri = Uri.tryParse(gistUrl);
                                        if (uri != null &&
                                            await canLaunchUrl(uri)) {
                                          await launchUrl(uri,
                                              mode: LaunchMode
                                                  .externalApplication);
                                        }
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.all(12),
                                        decoration: const BoxDecoration(
                                            color: Colors.black54,
                                            shape: BoxShape.circle),
                                        child: const Icon(Icons.link,
                                            size: 24, color: Colors.white),
                                      ),
                                    ),
                                  ),
                                ),

                              // LIKE BUTTON (bottom right) - restored
                              Positioned(
                                bottom: 12,
                                right: 12,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 8, horizontal: 8),
                                  decoration: BoxDecoration(
                                      color: Colors.black45,
                                      borderRadius: BorderRadius.circular(20)),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: () =>
                                            _toggleGistLike(gistId),
                                        icon: Icon(
                                            isLiked
                                                ? Icons.favorite
                                                : Icons.favorite_border,
                                            color: isLiked
                                                ? Colors.red
                                                : Colors.white,
                                            size: 28),
                                      ),
                                      Text(likeCount.toString(),
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 15,
                                              fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                              ),

                              // Big play icon when paused
                              if (!controller.value.isPlaying)
                                const Center(
                                  child: Icon(
                                    Icons.play_circle_fill,
                                    size: 80,
                                    color: Colors.white70,
                                  ),
                                ),
                            ],
                          )
                        : const Center(child: CircularProgressIndicator()),
                  ),
                ),
                const SizedBox(height: 12),

                // Username + Title
                GestureDetector(
                  onTap: () => _showProfileCard(username ?? '', avatarUrl, bio),
                  child: RichText(
                    textAlign: TextAlign.center,
                    text: TextSpan(
                      style: const TextStyle(
                          fontFamily: 'SanFrancisco', fontSize: 18),
                      children: [
                        TextSpan(
                            text: username != null ? "@$username" : '',
                            style: TextStyle(
                                color: themeColor,
                                fontWeight: FontWeight.bold)),
                        TextSpan(
                            text: username != null ? ": " : "",
                            style: TextStyle(
                                color: themeColor,
                                fontWeight: FontWeight.bold)),
                        TextSpan(
                          text: fullTitle.length > 100
                              ? "${fullTitle.substring(0, 100)}..."
                              : fullTitle,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),

                if (fullTitle.length > 100)
                  GestureDetector(
                    onTap: () {
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (context) => DraggableScrollableSheet(
                          initialChildSize: 0.55,
                          minChildSize: 0.4,
                          maxChildSize: 0.9,
                          expand: false,
                          builder: (_, scrollController) => Container(
                            decoration: const BoxDecoration(
                              color: Color(0xFF1E1E1E),
                              borderRadius: BorderRadius.vertical(
                                  top: Radius.circular(24)),
                            ),
                            child: ListView(
                              controller: scrollController,
                              padding: const EdgeInsets.all(24),
                              children: [
                                const Text("Full Gist Title",
                                    style: TextStyle(
                                        fontSize: 22,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white),
                                    textAlign: TextAlign.center),
                                const SizedBox(height: 16),
                                Text(
                                  fullTitle.replaceAll('\\n', '\n'),
                                  style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 16,
                                      height: 1.5),
                                ),
                                const SizedBox(height: 32),
                                Align(
                                  alignment: Alignment.center,
                                  child: TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('Close',
                                        style: TextStyle(
                                            color: Color(0xFF4CAF50),
                                            fontSize: 18)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text("...see more",
                          style: TextStyle(
                              color: Color(0xFF4CAF50),
                              fontSize: 15,
                              fontWeight: FontWeight.bold)),
                    ),
                  ),
              ],
            ),
          );
        }

        // ====================== IMAGE GIST (unchanged) ======================
        return Padding(
          padding: const EdgeInsets.only(bottom: 32.0),
          child: Column(
            children: [
              // CAROUSEL IMAGE AREA
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.36,
                width: MediaQuery.of(context).size.width * 0.85,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child: Stack(
                    children: [
                      Positioned.fill(
                          child: Container(
                              color: _isDarkMode
                                  ? Colors.grey[750]
                                  : Colors.grey[300])),
                      imagesToShow.isEmpty
                          ? Container(
                              color: _isDarkMode
                                  ? Colors.grey[750]
                                  : Colors.grey[300])
                          : PageView.builder(
                              itemCount: imagesToShow.length,
                              onPageChanged: (page) {
                                setState(() => currentPage = page);
                              },
                              itemBuilder: (context, i) {
                                return CachedNetworkImage(
                                  imageUrl: imagesToShow[i],
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) => const Center(
                                      child: CircularProgressIndicator()),
                                  errorWidget: (_, __, ___) =>
                                      const Icon(Icons.broken_image, size: 50),
                                );
                              },
                            ),
                      if (imagesToShow.length > 1)
                        Positioned(
                          top: 12,
                          left: 12,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.7),
                                borderRadius: BorderRadius.circular(20)),
                            child: Text(
                              "${currentPage + 1}/${imagesToShow.length}",
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      // Zoom + Download gesture
                      GestureDetector(
                        onTap: () {
                          if (imagesToShow.isNotEmpty) {
                            showDialog(
                              context: context,
                              builder: (context) => Dialog(
                                backgroundColor: Colors.black,
                                insetPadding: EdgeInsets.zero,
                                child: Stack(
                                  children: [
                                    PageView.builder(
                                      itemCount: imagesToShow.length,
                                      itemBuilder: (context, i) =>
                                          InteractiveViewer(
                                        panEnabled: true,
                                        minScale: 0.5,
                                        maxScale: 4.0,
                                        child: CachedNetworkImage(
                                            imageUrl: imagesToShow[i],
                                            fit: BoxFit.contain),
                                      ),
                                    ),
                                    Positioned(
                                      top: 40,
                                      right: 20,
                                      child: IconButton(
                                        icon: const Icon(Icons.close,
                                            color: Colors.white, size: 30),
                                        onPressed: () => Navigator.pop(context),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }
                        },
                        onLongPress: () => _downloadGistImage(
                            imagesToShow.isNotEmpty
                                ? imagesToShow.first
                                : imageUrl),
                      ),
                      // Link button
                      if (gistUrl.isNotEmpty)
                        Positioned(
                          top: 12,
                          right: 12,
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(30),
                              onTap: () async {
                                final uri = Uri.tryParse(gistUrl);
                                if (uri != null && await canLaunchUrl(uri)) {
                                  await launchUrl(uri,
                                      mode: LaunchMode.externalApplication);
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: const BoxDecoration(
                                    color: Colors.black54,
                                    shape: BoxShape.circle),
                                child: const Icon(Icons.link,
                                    size: 24, color: Colors.white),
                              ),
                            ),
                          ),
                        ),
                      // Like button
                      Positioned(
                        bottom: 12,
                        right: 12,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              vertical: 8, horizontal: 8),
                          decoration: BoxDecoration(
                              color: Colors.black45,
                              borderRadius: BorderRadius.circular(20)),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                onPressed: () => _toggleGistLike(gistId),
                                icon: Icon(
                                    isLiked
                                        ? Icons.favorite
                                        : Icons.favorite_border,
                                    color: isLiked ? Colors.red : Colors.white,
                                    size: 28),
                              ),
                              Text(likeCount.toString(),
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Username + Title
              GestureDetector(
                onTap: () => _showProfileCard(username ?? '', avatarUrl, bio),
                child: RichText(
                  textAlign: TextAlign.center,
                  text: TextSpan(
                    style: const TextStyle(
                        fontFamily: 'SanFrancisco', fontSize: 18),
                    children: [
                      TextSpan(
                          text: username != null ? "@$username" : '',
                          style: TextStyle(
                              color: themeColor, fontWeight: FontWeight.bold)),
                      TextSpan(
                          text: username != null ? ": " : "",
                          style: TextStyle(
                              color: themeColor, fontWeight: FontWeight.bold)),
                      TextSpan(
                        text: fullTitle.length > 100
                            ? "${fullTitle.substring(0, 100)}..."
                            : fullTitle,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
              // "...see more"
              if (fullTitle.length > 100)
                GestureDetector(
                  onTap: () {
                    showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (context) => DraggableScrollableSheet(
                        initialChildSize: 0.55,
                        minChildSize: 0.4,
                        maxChildSize: 0.9,
                        expand: false,
                        builder: (_, scrollController) => Container(
                          decoration: const BoxDecoration(
                            color: Color(0xFF1E1E1E),
                            borderRadius:
                                BorderRadius.vertical(top: Radius.circular(24)),
                          ),
                          child: ListView(
                            controller: scrollController,
                            padding: const EdgeInsets.all(24),
                            children: [
                              const Text(
                                "Full Gist Title",
                                style: TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white),
                                textAlign: TextAlign.center,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                fullTitle.replaceAll('\\n', '\n'),
                                style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 16,
                                    height: 1.5),
                              ),
                              const SizedBox(height: 32),
                              Align(
                                alignment: Alignment.center,
                                child: TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('Close',
                                      style: TextStyle(
                                          color: Color(0xFF4CAF50),
                                          fontSize: 18)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                  child: const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text("...see more",
                        style: TextStyle(
                            color: Color(0xFF4CAF50),
                            fontSize: 15,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  // Helper method to download the image
  Future<void> _downloadGistImage(String imageUrl) async {
    try {
      // Check if we have permission to save images
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        await Gal.requestAccess();
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Downloading to gallery...')),
      );

      // This package handles the heavy lifting of downloading and saving
      await Gal.putImage(imageUrl);

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
            content: Text('❌ Could not save image'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final Color bgColor = _isDarkMode ? Colors.grey[900]! : Colors.grey[100]!;
    final horizontalBarWidth = MediaQuery.of(context).size.width * 0.85;
    const vendorBudgetTextSizeFactor = 0.7;

    return Theme(
      data: _isDarkMode
          ? ThemeData.dark().copyWith(scaffoldBackgroundColor: bgColor)
          : ThemeData.light().copyWith(scaffoldBackgroundColor: bgColor),
      child: Scaffold(
        appBar: _selectedIndex == 0 ? _buildAppBar() : null,
        bottomNavigationBar: _buildCustomFooter(bgColor),
        floatingActionButton: FloatingActionButton(
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
            child: const Icon(Icons.chat_bubble_rounded,
                color: Colors.white, size: 30),
          ),
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Message Chatbot coming soon! 💬'),
                backgroundColor: Color(0xFF4CAF50),
              ),
            );
          },
        ),
        body: SafeArea(
          child: Stack(
            children: [
              IndexedStack(
                index: _selectedIndex,
                children: [
                  RefreshIndicator(
                    color: themeColor,
                    // USE THE NEW COMBINED REFRESH HERE
                    onRefresh: _handleRefresh,
                    child: CustomScrollView(
                      controller: _scrollController,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        // --- Section 1: Top bars ---
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
                                    width: horizontalBarWidth,
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
                                                              padding:
                                                                  const EdgeInsets.only(
                                                                      right:
                                                                          12),
                                                              child: Chip(
                                                                  label: Text(v,
                                                                      style: TextStyle(
                                                                          fontFamily:
                                                                              'SanFrancisco',
                                                                          fontSize:
                                                                              18 * vendorBudgetTextSizeFactor,
                                                                          color: Colors.white)),
                                                                  backgroundColor: _isDarkMode ? Colors.grey[700] : Colors.grey[300])))
                                                          .toList()))
                                              : Text("Select Vendor", style: TextStyle(fontFamily: 'SanFrancisco', fontSize: 22 * vendorBudgetTextSizeFactor, color: Colors.white54))),
                                      !_vendorBarTapped
                                          ? Icon(BoxIcons.bxs_chevron_down,
                                              color: themeColor, size: 22)
                                          : const SizedBox(),
                                    ]),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Container(
                                  width: horizontalBarWidth,
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
                                            style: TextStyle(
                                                fontFamily: 'SanFrancisco',
                                                fontSize: 18 *
                                                    vendorBudgetTextSizeFactor,
                                                color: Colors.white),
                                            decoration: InputDecoration(
                                                hintText: "Enter Budget",
                                                hintStyle: TextStyle(
                                                    fontFamily: 'SanFrancisco',
                                                    color: Colors.white54,
                                                    fontSize: 22 *
                                                        vendorBudgetTextSizeFactor),
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
                                    width: horizontalBarWidth,
                                    height: 50,
                                    child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                            children: _colorfulTabs
                                                .map((tab) =>
                                                    _buildRectangularTab(tab))
                                                .toList()))),
                              ],
                            ),
                          ),
                        ),

                        // --- Section 2: STICKY GIST BAR + STORIES ---
                        SliverPersistentHeader(
                          pinned: true,
                          delegate: _GistBarHeaderDelegate(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _buildGistFilterBar(),
                                const SizedBox(height: 10),
                                // ADD THE KEY HERE
                                StoriesBar(key: _storiesBarKey),
                              ],
                            ),
                          ),
                        ),

                        // --- Section 3: Gists list ---
                        SliverToBoxAdapter(child: _buildGistSlideshow()),
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

      // Add avatar from the gist author OR from ticket sender
      final List<Map<String, dynamic>> result = [];
      for (var notif in resp) {
        final data = notif['data'] as Map<String, dynamic>? ?? {};
        final gistId = data['gist_id'];

        String? avatarUrl;
        String? username;

        if (gistId != null) {
          // === FOR GISTS (your old code - unchanged) ===
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
        } else if (data['type'] == 'ticket_transfer' ||
            data['type'] == 'ticket_gift') {
          // === NEW: FOR TICKET TRANSFERS / GIFTS ===
          avatarUrl = data['sender_avatar'] as String?;
          username = data['sender_username'] as String?;
        }

        // Attach to the notification so your UI can show the avatar
        notif['avatar_url'] = avatarUrl;
        notif['username'] = username;
        result.add(notif);
      }

      return result;
    } catch (e) {
      developer.log('Error fetching notifications: $e', name: 'notifications');
      return [];
    }
  }

  // NEW: show slide-up notifications bottom sheet WITH PROFILE PHOTOS
  void _showNotifications() async {
    final notifications = await _fetchNotifications();
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
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
                child: Text(
                  'Notifications',
                  style: TextStyle(
                    fontFamily: 'Montserrat',
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: themeColor,
                  ),
                ),
              ),
              Expanded(
                child: notifications.isEmpty
                    ? Center(
                        child: Text(
                          'No notifications yet.',
                          style: TextStyle(
                            color: _isDarkMode ? Colors.white : Colors.black,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: notifications.length,
                        itemBuilder: (ctx, i) {
                          final notif = notifications[i];
                          final title = notif['title'] ?? 'Notification';
                          final body = notif['body'] ?? '';
                          final data = notif['data'] ?? {};
                          final gistId = data['gist_id']?.toString();
                          final ticketId = data['ticket_id']?.toString();

                          // ────── IMAGE LOGIC ──────
                          // 1. For new tickets → use event poster (photo_url)
                          // 2. For gists / transfers → use avatar (as before)
                          final String? photoUrl = data['photo_url'] as String?;
                          final String? avatarUrl =
                              notif['avatar_url'] as String?;
                          final String? username = notif['username'] as String?;

                          final String? displayImage = photoUrl ?? avatarUrl;

                          final bool isTicketNotification =
                              (data['type'] == 'ticket' ||
                                  data['type'] == 'ticket_transfer');

                          return ListTile(
                            leading: displayImage != null &&
                                    displayImage.isNotEmpty
                                ? ClipRRect(
                                    borderRadius: BorderRadius.circular(8),
                                    child: CachedNetworkImage(
                                      imageUrl: displayImage,
                                      width: 48,
                                      height: 48,
                                      fit: BoxFit.cover,
                                      placeholder: (_, __) => Container(
                                        width: 48,
                                        height: 48,
                                        color: Colors.grey[700],
                                      ),
                                      errorWidget: (_, __, ___) => const Icon(
                                        Icons.broken_image,
                                        size: 48,
                                        color: Colors.white70,
                                      ),
                                    ),
                                  )
                                : CircleAvatar(
                                    radius: 22,
                                    backgroundColor: isTicketNotification
                                        ? const Color(0xFF4CAF50)
                                        : Colors.grey[700],
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
                                                color: Colors.white),
                                          )
                                        : null,
                                  ),
                            title: Text(
                              title,
                              style: TextStyle(
                                color:
                                    _isDarkMode ? Colors.white : Colors.black,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            subtitle: Text(
                              body,
                              style: TextStyle(
                                color: _isDarkMode
                                    ? Colors.white70
                                    : Colors.grey[700],
                              ),
                            ),
                            onTap: () async {
                              try {
                                await supabase.from('notifications').update(
                                    {'read': true}).eq('id', notif['id']);
                              } catch (_) {}
                              if (gistId != null) {
                                Navigator.pushNamed(context, '/gist',
                                    arguments: {'id': gistId});
                              } else if (ticketId != null) {
                                Navigator.pushNamed(context, '/ticket',
                                    arguments: {'id': ticketId});
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
