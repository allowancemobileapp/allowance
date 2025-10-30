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
import 'package:allowance/services/api_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';

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
  final List<Map<String, dynamic>> _colorfulTabs = [
    {"label": "Favorites", "icon": BoxIcons.bxs_heart, "color": Colors.orange},
    {"label": "Tickets", "icon": BoxIcons.bxs_chat, "color": Colors.purple},
    {"label": "Delivery", "icon": BoxIcons.bxs_truck, "color": Colors.teal},
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

  // Fallback images (replace with your own public URLs or storage links)
  final List<Map<String, dynamic>> _fallbackGists = [
    {
      'id': 'fallback-1',
      'title': 'Welcome to Allowance — discover local gists',
      'image_url': 'https://picsum.photos/1200/800?seed=allowance1'
    },
    {
      'id': 'fallback-2',
      'title': 'Share news, offers and updates with your campus',
      'image_url': 'https://picsum.photos/1200/800?seed=allowance2'
    },
    {
      'id': 'fallback-3',
      'title': 'Create Local or Global gists with an image',
      'image_url': 'https://picsum.photos/1200/800?seed=allowance3'
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
      final response = await supabase
          .from('gists')
          .select('id, title, image_url')
          .order('created_at', ascending: false)
          .limit(10);

      if (!mounted) return;

      final list = (response is List)
          ? List<Map<String, dynamic>>.from(response)
          : <Map<String, dynamic>>[];

      setState(() {
        _fetchedGists = list;
        _isGistsLoading = false;
      });

      // If there are no gists, use fallback images
      if (_fetchedGists.isEmpty) {
        setState(() {
          _fetchedGists = List<Map<String, dynamic>>.from(_fallbackGists);
        });
      }

      if (_fetchedGists.isNotEmpty) {
        _startSlideshow();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isGistsLoading = false;
          _fetchedGists = List<Map<String, dynamic>>.from(_fallbackGists);
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error fetching gists: $e')),
        );
        _startSlideshow();
      }
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
      errorMsg = "Error loading schools: $e";
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
                    return ListTile(
                      title: Text(name,
                          style: TextStyle(
                              fontFamily: 'Montserrat',
                              fontSize: 18,
                              color: textColor)),
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
                  child: Text("No schools available",
                      style: TextStyle(color: textColor)),
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
        errorMsg = "Error loading vendors: $e";
      }
      if (!mounted) return;
      if (errorMsg != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(errorMsg)));
        return;
      }
      if (_restaurants.isEmpty) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text("No vendors found.")));
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
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('${tab["label"]} tapped (Placeholder)',
                  style: const TextStyle(fontFamily: 'SanFrancisco'))));
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

  Widget _buildGistSlideshow() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
              color: _isDarkMode ? Colors.grey[850] : Colors.grey[300],
              borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                  bottomRight: Radius.circular(8))),
          child: Text("Gist",
              style: TextStyle(
                  fontFamily: 'SanFrancisco',
                  fontSize: 16,
                  color: themeColor))),
      SizedBox(
          height: MediaQuery.of(context).size.height * 0.36,
          child: _isGistsLoading
              ? Center(child: CircularProgressIndicator(color: themeColor))
              : PageView.builder(
                  controller: _pageController,
                  onPageChanged: (i) {
                    if (_fetchedGists.isNotEmpty) {
                      setState(
                          () => _slideshowIndex = i % _fetchedGists.length);
                    }
                  },
                  // If there are fetched items use the infinite illusion (unbounded)
                  itemCount: _fetchedGists.isEmpty ? 0 : null,
                  itemBuilder: (ctx, idx) {
                    if (_fetchedGists.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    final actualIndex = idx % _fetchedGists.length;
                    final gist = _fetchedGists[actualIndex];
                    final imageUrl = gist['image_url'] as String?;
                    final scale = _slideshowIndex == actualIndex ? 1.0 : 0.9;
                    return Transform.scale(
                        scale: scale,
                        child: Padding(
                            padding: EdgeInsets.only(
                                right: actualIndex != _slideshowIndex
                                    ? 15.0
                                    : 0.0),
                            child: GestureDetector(
                              onTap: () {
                                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                    content: Text(
                                        'Tapped on gist: ${gist['title']} (ID: ${gist['id']})')));
                              },
                              child: imageUrl != null && imageUrl.isNotEmpty
                                  ? CachedNetworkImage(
                                      imageUrl: imageUrl,
                                      fit: BoxFit.contain,
                                      placeholder: (context, url) => Container(
                                        color: _isDarkMode
                                            ? Colors.grey[700]
                                            : Colors.grey[200],
                                        child: Center(
                                            child: CircularProgressIndicator(
                                                color: themeColor)),
                                      ),
                                      errorWidget: (context, url, error) =>
                                          Container(
                                        color: _isDarkMode
                                            ? Colors.grey[700]
                                            : Colors.grey[200],
                                        child: Icon(Icons.broken_image,
                                            color: _isDarkMode
                                                ? Colors.white54
                                                : Colors.black54,
                                            size: 40),
                                      ),
                                    )
                                  : Container(
                                      decoration: BoxDecoration(
                                        color: _isDarkMode
                                            ? Colors.grey[700]
                                            : Colors.grey[200],
                                      ),
                                      child: Icon(Icons.image_not_supported,
                                          color: _isDarkMode
                                              ? Colors.white54
                                              : Colors.black54,
                                          size: 40),
                                    ),
                            )));
                  })),
      const SizedBox(height: 8),
      Center(
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                  _fetchedGists.isNotEmpty &&
                          _slideshowIndex < _fetchedGists.length
                      ? _fetchedGists[_slideshowIndex]['title'] as String? ??
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
            Padding(
              padding: const EdgeInsets.only(
                  left: 16, top: 16, right: 16, bottom: 8),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Spacer(),
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
                          Icon(BoxIcons.bxs_store, color: themeColor, size: 20),
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
                                                              ? Colors.grey[700]
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
                          color:
                              _isDarkMode ? Colors.grey[800] : Colors.grey[200],
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
              onPressed: () {})),
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
}
