// lib/screens/home/home_screen.dart
import 'dart:async';
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
  bool _isBudgetEntered = false;
  bool _vendorBarTapped = false;
  final Color themeColor = const Color(0xFF4CAF50);
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
  int _slideshowIndex = 0;
  Timer? _slideshowTimer;
  List<Map<String, dynamic>> _fetchedGists = [];

  // NEW: track loading vs loaded-with-zero-items
  bool _isGistsLoading = true;

  String _gistFilter = 'All';

  // Fallback images (replace with your own public URLs or storage links)
  final List<Map<String, dynamic>> _fallbackGists = [
    {
      'id': 'fallback-1',
      'title': 'Market your brand exclusively on campus',
      'image_url':
          'https://quuazutreaitqoquzolg.supabase.co/storage/v1/object/public/random/InShot_20251114_172942404.jpg'
    },
    {
      'id': 'fallback-2',
      'title': 'Get the best and tastiest food combos',
      'image_url':
          'https://quuazutreaitqoquzolg.supabase.co/storage/v1/object/public/random/InShot_20251114_173051467.jpg'
    },
    {
      'id': 'fallback-3',
      'title': 'Let the world see your new EP!',
      'image_url':
          'https://quuazutreaitqoquzolg.supabase.co/storage/v1/object/public/random/file_00000000da98720ab5cdd39756c77926.png'
    },
  ];

  @override
  void initState() {
    super.initState();
    _prefs = widget.userPreferences ?? UserPreferences();

    _budgetController.addListener(() {
      setState(() {
        _isBudgetEntered = _budgetController.text.isNotEmpty;
      });
    });
    _budgetFocusNode.addListener(() => setState(() {}));
    _pageController = PageController(viewportFraction: 0.85);
    _budgetController.text = _prefs.budget?.toString() ?? "";
    _fetchGistsAndStartSlideshow();
  }

  @override
  void dispose() {
    _slideshowTimer?.cancel();
    _pageController.dispose();
    _budgetController.dispose();
    _budgetFocusNode.dispose();
    _restaurantsController.dispose();
    _restaurantFocusNode.dispose();
    super.dispose();
  }

  Future<void> _fetchGistsAndStartSlideshow() async {
    setState(() {
      _isGistsLoading = true;
    });

    try {
      // Request only paid & active gists from server (server filtering preferred).
      final List<Map<String, dynamic>> raw = await supabase
          .from('gists')
          .select(
              'id, title, image_url, type, school_id, url, created_at, category')
          .eq('paid', true)
          .eq('status', 'active')
          .order('created_at', ascending: false)
          .limit(50);

      if (!mounted) return;

      List<Map<String, dynamic>> list = raw;

      // Apply client-side visibility rules:
      // - if user has selected a school (sid): show global + local for that school
      // - if no school selected: show only global

      final sidStr = _prefs.schoolId; // stored as String or null
      final int? sidInt = sidStr != null ? int.tryParse(sidStr) : null;

      if (sidStr != null && sidStr.isNotEmpty) {
        // Filter list to global OR local matching this sid
        list = list.where((g) {
          final type = (g['type'] ?? '').toString().toLowerCase();
          if (type == 'global') return true;
          if (type == 'local') {
            final gSchool = g['school_id'];
            if (gSchool == null) return false;

            // Normalize DB school id to int if possible
            final int? gsInt = int.tryParse(gSchool.toString());

            // Compare ints if both available, otherwise fall back to string compare
            if (gsInt != null && sidInt != null) {
              return gsInt == sidInt;
            } else {
              return gSchool.toString() == sidStr;
            }
          }
          return false;
        }).toList();
      } else {
        // No school selected -> only global gists
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

      // If nothing to show, use fallback placeholders
      if (_fetchedGists.isEmpty) {
        setState(() {
          _fetchedGists = List<Map<String, dynamic>>.from(_fallbackGists);
        });
      }

      if (_fetchedGists.isNotEmpty) _startSlideshow();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isGistsLoading = false;
        _fetchedGists = List<Map<String, dynamic>>.from(_fallbackGists);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Failed to load gists. Showing defaults instead.')),
      );
      _startSlideshow();
    }
  }

  void _startSlideshow() {
    _slideshowTimer?.cancel();
    if (_fetchedGists.isEmpty) return;
    _slideshowTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_pageController.hasClients && _fetchedGists.isNotEmpty) {
        if (_pageController.page != null) {
          int nextPage = (_pageController.page!.round() + 1);
          _pageController.animateToPage(
            nextPage,
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOut,
          );
        }
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
                child: Text("Please select a school first.",
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
                  builder: (routeContext) =>
                      FavoritesScreen(userPreferences: _prefs)));
        } else if (tab["label"] == "Tickets") {
          Navigator.push(
              context,
              MaterialPageRoute(
                  builder: (routeContext) => const TicketScreen()));
        } else if (tab["label"] == "Order") {
          if (_prefs.subscriptionTier == null ||
              _prefs.subscriptionTier != "Membership") {
            showModalBottomSheet(
              context: context,
              backgroundColor: Colors.grey[850],
              shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
              ),
              builder: (ctx) => Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Subscribe to order custom food – only Plus users can.',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => SubscriptionScreen(
                              userPreferences: _prefs,
                              themeColor: themeColor,
                            ),
                          ),
                        );
                      },
                      style:
                          ElevatedButton.styleFrom(backgroundColor: themeColor),
                      child: const Text('Subscribe Now',
                          style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              ),
            );
          } else {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (routeContext) => OrderScreen(userPreferences: _prefs),
              ),
            );
          }
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

  void _goToAvailableOptions() async {
    final budget = double.tryParse(_budgetController.text) ?? 0;
    if (budget <= 0) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please enter a valid budget.")));
      return;
    }
    if (_selectedRestaurants.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Please select at least one vendor.")));
      return;
    }
    _prefs.budget = budget;
    await _prefs.savePreferences();
    if (!mounted) return;
    Navigator.push(
        context,
        MaterialPageRoute(
            builder: (routeContext) => AvailableOptionsScreen(
                userPreferences: _prefs,
                selectedRestaurants: _selectedRestaurants)));
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

  // 3. Updated _buildGistSlideshow() – added megaphone icon + tap to open filter sheet
  Widget _buildGistSlideshow() {
    final filteredGists = _gistFilter == 'All'
        ? _fetchedGists
        : _fetchedGists.where((g) => g['category'] == _gistFilter).toList();

    // Fixed label: always "Gist" if loading, empty, or no category
    final String label = _isGistsLoading
        ? "Gist"
        : filteredGists.isEmpty
            ? "Gist"
            : (filteredGists[_slideshowIndex < filteredGists.length
                    ? _slideshowIndex
                    : 0]['category'] as String? ??
                "Gist");

    final horizontalBarWidth = MediaQuery.of(context).size.width * 0.85;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(
        child: GestureDetector(
          onTap: _showGistFilterSheet,
          child: Container(
            width: horizontalBarWidth,
            height: 44,
            margin: const EdgeInsets.only(bottom: 8),
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
                    style: TextStyle(
                      fontFamily: 'SanFrancisco',
                      fontSize: 18,
                      color: themeColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Icon(Icons.chevron_right, color: themeColor, size: 24),
              ],
            ),
          ),
        ),
      ),
      // Rest of slideshow unchanged...
      SizedBox(
          height: MediaQuery.of(context).size.height * 0.36,
          child: _isGistsLoading
              ? Center(child: CircularProgressIndicator(color: themeColor))
              : PageView.builder(
                  controller: _pageController,
                  onPageChanged: (i) {
                    if (filteredGists.isNotEmpty) {
                      setState(
                          () => _slideshowIndex = i % filteredGists.length);
                    }
                  },
                  itemCount: filteredGists.isEmpty ? 0 : null,
                  itemBuilder: (ctx, idx) {
                    if (filteredGists.isEmpty) return const SizedBox.shrink();
                    final actualIndex = idx % filteredGists.length;
                    final gist = filteredGists[actualIndex];
                    final imageUrl = (gist['image_url'] as String?) ?? '';
                    final gistUrl = (gist['url'] as String?) ?? '';
                    final scale = _slideshowIndex == actualIndex ? 1.0 : 0.9;

                    return Transform.scale(
                        scale: scale,
                        child: Padding(
                          padding: EdgeInsets.only(
                              right:
                                  actualIndex != _slideshowIndex ? 15.0 : 0.0),
                          child: GestureDetector(
                            onTap: () {},
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: Stack(
                                children: [
                                  Positioned.fill(
                                    child: Container(
                                      color: _isDarkMode
                                          ? Colors.grey[750]
                                          : Colors.grey[300],
                                    ),
                                  ),
                                  Center(
                                    child: CachedNetworkImage(
                                      imageUrl: imageUrl,
                                      fit: BoxFit.contain,
                                      placeholder: (context, url) => Center(
                                        child: CircularProgressIndicator(
                                            color: themeColor),
                                      ),
                                      errorWidget: (context, url, error) =>
                                          Center(
                                        child: Icon(
                                          Icons.broken_image,
                                          color: _isDarkMode
                                              ? Colors.white54
                                              : Colors.black54,
                                          size: 50,
                                        ),
                                      ),
                                    ),
                                  ),
                                  if (gistUrl.isNotEmpty)
                                    Positioned(
                                      top: 12,
                                      right: 12,
                                      child: Material(
                                        color: Colors.transparent,
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(30),
                                          onTap: () async {
                                            final uri = Uri.tryParse(gistUrl);
                                            if (uri != null &&
                                                await canLaunchUrl(uri)) {
                                              await launchUrl(uri,
                                                  mode: LaunchMode
                                                      .externalApplication);
                                            } else {
                                              if (mounted) {
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(
                                                  const SnackBar(
                                                      content: Text(
                                                          "Sorry, we couldn't open this link.")),
                                                );
                                              }
                                            }
                                          },
                                          child: Container(
                                            padding: const EdgeInsets.all(12),
                                            decoration: const BoxDecoration(
                                              color: Colors.black54,
                                              shape: BoxShape.circle,
                                            ),
                                            child: const Icon(Icons.link,
                                                size: 24, color: Colors.white),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ));
                  },
                )),
      const SizedBox(height: 8),
      Center(
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                  filteredGists.isNotEmpty &&
                          _slideshowIndex < filteredGists.length
                      ? filteredGists[_slideshowIndex]['title'] as String? ??
                          'Loading...'
                      : '',
                  style: const TextStyle(
                      fontFamily: 'SanFrancisco',
                      fontSize: 18,
                      color: Colors.white),
                  textAlign: TextAlign.center))),
    ]);
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
        bottomNavigationBar: _buildCustomFooter(bgColor),
        appBar: _selectedIndex == 0 ? _buildAppBar() : null,
        body: SafeArea(
          child: IndexedStack(index: _selectedIndex, children: [
            SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.only(
                    left: 16, top: 70, right: 16, bottom: 8),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisAlignment: MainAxisAlignment.center,
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
                              borderRadius: BorderRadius.circular(25)),
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(children: [
                            Icon(BoxIcons.bxs_store,
                                color: themeColor, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                                child: _selectedRestaurants.isNotEmpty
                                    ? SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                            children: _selectedRestaurants
                                                .map((v) => Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                              right: 12),
                                                      child: Chip(
                                                        label: Text(v,
                                                            style: TextStyle(
                                                                fontFamily:
                                                                    'SanFrancisco',
                                                                fontSize: 18 *
                                                                    vendorBudgetTextSizeFactor,
                                                                color: Colors
                                                                    .white)),
                                                        backgroundColor:
                                                            _isDarkMode
                                                                ? Colors
                                                                    .grey[700]
                                                                : Colors
                                                                    .grey[300],
                                                      ),
                                                    ))
                                                .toList()))
                                    : Text("Select Vendor",
                                        style: TextStyle(
                                            fontFamily: 'SanFrancisco',
                                            fontSize:
                                                22 * vendorBudgetTextSizeFactor,
                                            color: Colors.white54))),
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
                            borderRadius: BorderRadius.circular(25)),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
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
                                      fontSize: 18 * vendorBudgetTextSizeFactor,
                                      color: Colors.white),
                                  decoration: InputDecoration(
                                      hintText: "Enter Budget",
                                      hintStyle: TextStyle(
                                          fontFamily: 'SanFrancisco',
                                          color: Colors.white54,
                                          fontSize:
                                              22 * vendorBudgetTextSizeFactor),
                                      border: InputBorder.none))),
                          _budgetFocusNode.hasFocus || _isBudgetEntered
                              ? InkWell(
                                  onTap: _goToAvailableOptions,
                                  child: Container(
                                      decoration: BoxDecoration(
                                          color: themeColor,
                                          shape: BoxShape.circle),
                                      padding: const EdgeInsets.all(6),
                                      child: const Icon(
                                          BoxIcons.bxs_chevron_right,
                                          color: Colors.white,
                                          size: 22)))
                              : Icon(BoxIcons.bxs_chevron_right,
                                  color: themeColor, size: 22),
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
                                      .map((tab) => _buildRectangularTab(tab))
                                      .toList()))),
                      const SizedBox(height: 16),
                      Align(
                          alignment: Alignment.centerLeft,
                          child: _buildGistSlideshow()),
                    ]),
              ),
            ),
            FavoritesScreen(userPreferences: _prefs),
            SubscriptionScreen(userPreferences: _prefs, themeColor: themeColor),
            ProfileScreen(
                userPreferences: _prefs,
                onSave: () => setState(() => _selectedIndex = 0)),
          ]),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
      elevation: 0,
      centerTitle: true,
      leading: Builder(
          builder: (appBarContext) => IconButton(
              icon: const Icon(Icons.notifications, size: 36),
              onPressed: () {
                _showNotifications();
              })),
      title: Image.asset('assets/images/allowance_logo.png',
          height: 200, width: 200, fit: BoxFit.contain),
      actions: [
        IconButton(
            icon: const Icon(BoxIcons.bxs_map, size: 36),
            color: _prefs.schoolId?.isNotEmpty == true
                ? themeColor
                : (_isDarkMode ? Colors.white54 : Colors.black54),
            onPressed: _chooseUniversity)
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
      return resp;
    } catch (e) {
      developer.log('Error fetching notifications: $e', name: 'notifications');
      return [];
    }
  }

  // NEW: show slide-up notifications bottom sheet
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

                          return ListTile(
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
                                Navigator.pushNamed(
                                  context,
                                  '/gist',
                                  arguments: {'id': gistId},
                                );
                              } else if (ticketId != null) {
                                Navigator.pushNamed(
                                  context,
                                  '/ticket',
                                  arguments: {'id': ticketId},
                                );
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
