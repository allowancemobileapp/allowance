// lib/screens/home/home_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/home/available_options_screen.dart';
import 'package:allowance/screens/home/favorites_screen.dart';
import 'package:allowance/screens/home/subscription_screen.dart';
import 'package:allowance/screens/profile/profile_screen.dart';
import 'package:allowance/screens/home/diet_screen.dart';
import 'package:allowance/services/api_service.dart';

class HomeScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  const HomeScreen({super.key, required this.userPreferences});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
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

  final List<String> _slideshowImages = [
    'assets/images/top_combo.jpg',
    'assets/images/test_image_1.jpg',
    'assets/images/test_image_2.jpg',
    'assets/images/test_image_3.jpg',
  ];

  final List<String> _slideshowCaptions = [
    "Enter the rave for tonight",
    "Feel the rhythm",
    "Dance like nobody's watching",
    "Tonight's vibe is lit",
  ];

  late PageController _pageController;
  int _slideshowIndex = 0;
  Timer? _slideshowTimer;

  @override
  void initState() {
    super.initState();
    _budgetController.addListener(() {
      setState(() {
        _isBudgetEntered = _budgetController.text.isNotEmpty;
      });
    });

    _budgetFocusNode.addListener(() {
      setState(() {});
    });

    _pageController = PageController(viewportFraction: 0.85);
    _startSlideshow();

    _budgetController.text = widget.userPreferences.budget?.toString() ?? "";
  }

  @override
  void dispose() {
    _slideshowTimer?.cancel();
    _pageController.dispose();
    _budgetController.dispose();
    _restaurantsController.dispose();
    _restaurantFocusNode.dispose();
    _budgetFocusNode.dispose();
    super.dispose();
  }

  void _startSlideshow() {
    _slideshowTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_pageController.hasClients && _slideshowImages.isNotEmpty) {
        _pageController.nextPage(
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
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
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (BuildContext context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.5,
          maxChildSize: 0.9,
          minChildSize: 0.3,
          builder: (context, scrollController) {
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 16),
              decoration: BoxDecoration(
                color: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: schools.isNotEmpty
                  ? ListView.builder(
                      controller: scrollController,
                      itemCount: schools.length,
                      itemBuilder: (context, index) {
                        final school = schools[index];
                        final schoolName = school["name"] is String
                            ? school["name"] as String
                            : "Unnamed School";
                        // Dynamically access school Id
                        return ListTile(
                          title: Text(
                            schoolName,
                            style: const TextStyle(
                                fontFamily: 'Montserrat', fontSize: 18),
                          ),
                          onTap: () async {
                            final schoolId = school["id"] is int
                                ? school["id"].toString()
                                : (school["id"] is String
                                    ? school["id"]
                                    : "defaultSchoolId");
                            widget.userPreferences.schoolId = schoolId;
                            widget.userPreferences.schoolName = schoolName;
                            widget.userPreferences.savePreferences();
                            Navigator.pop(context);
                            setState(() {
                              _selectedRestaurants.clear();
                            });
                          },
                        );
                      },
                    )
                  : const Center(child: Text("No schools available")),
            );
          },
        );
      },
    );
  }

  void _showRestaurantSelection() async {
    final selectedSchoolId = widget.userPreferences.schoolId;
    List<dynamic> vendors = [];
    String? errorMsg;
    setState(() {
      _vendorBarTapped = true;
    });

    if (selectedSchoolId != null && selectedSchoolId.isNotEmpty) {
      try {
        vendors = await ApiService.fetchVendors(selectedSchoolId);
        _restaurants = vendors.map<String>((vendor) {
          // Find the first key that holds a string value (the vendor name)
          final vendorNameKey = vendor.keys.firstWhere(
            (key) => vendor[key] is String,
            orElse: () => "vendor", // Default key if no string key is found
          );

          return vendor[vendorNameKey] as String? ?? "Unnamed Vendor";
        }).toList();
      } catch (e) {
        errorMsg = "Error loading vendors: $e";
      }

      if (!mounted) return;

      if (vendors.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text("No vendors found for this school.")));
      } else if (errorMsg != null) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(errorMsg)));
        return; // Exit early if there's an error
      }

      showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (BuildContext context) {
            return StatefulBuilder(builder: (context, setModalState) {
              return DraggableScrollableSheet(
                expand: false,
                initialChildSize: 0.6,
                maxChildSize: 0.9,
                minChildSize: 0.3,
                builder: (context, scrollController) {
                  return Container(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    decoration: BoxDecoration(
                      color: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
                      borderRadius:
                          const BorderRadius.vertical(top: Radius.circular(16)),
                    ),
                    child: ListView(
                      controller: scrollController,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          child: Text(
                            "Select Vendors",
                            style: TextStyle(
                              fontFamily: 'Montserrat',
                              color: themeColor,
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        if (_restaurants.isNotEmpty) ...[
                          CheckboxListTile(
                            title: const Text(
                              "Select all vendors",
                              style: TextStyle(
                                  fontFamily: 'Montserrat', fontSize: 16),
                            ),
                            value: _selectAll,
                            onChanged: (value) {
                              setModalState(() {
                                _selectAll = value ?? false;
                                if (_selectAll) {
                                  _selectedRestaurants =
                                      List.from(_restaurants);
                                } else {
                                  _selectedRestaurants.clear();
                                }
                              });
                              setState(() {});
                            },
                            activeColor: Colors.amber[700],
                            checkColor: Colors.white,
                            controlAffinity: ListTileControlAffinity.leading,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                          ListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            itemCount: _restaurants.length,
                            itemBuilder: (context, index) {
                              final restaurant = _restaurants[index];
                              return CheckboxListTile(
                                title: Text(
                                  restaurant,
                                  style: const TextStyle(
                                      fontFamily: 'Montserrat', fontSize: 16),
                                ),
                                value:
                                    _selectedRestaurants.contains(restaurant),
                                onChanged: (value) {
                                  setModalState(() {
                                    if (value ?? false) {
                                      _selectedRestaurants.add(restaurant);
                                    } else {
                                      _selectedRestaurants.remove(restaurant);
                                    }
                                    _selectAll = _selectedRestaurants.length ==
                                        _restaurants.length;
                                  });
                                  setState(() {});
                                },
                                activeColor: Colors.amber[700],
                                checkColor: Colors.white,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              );
                            },
                          ),
                        ] else ...[
                          const Center(
                            child: Padding(
                              padding: EdgeInsets.all(16.0),
                              child: Text(
                                "No vendors available for this school",
                                style: TextStyle(
                                    fontFamily: 'Montserrat', fontSize: 16),
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () {
                                _restaurantFocusNode.unfocus();
                                Navigator.pop(context);
                                setState(() {});
                              },
                              child: Text(
                                "Done",
                                style: TextStyle(
                                    fontFamily: 'Montserrat',
                                    color: themeColor),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            });
          });
    } else {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (BuildContext context) {
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.4,
            maxChildSize: 0.9,
            minChildSize: 0.3,
            builder: (context, scrollController) {
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(16)),
                ),
                child: ListView(
                  controller: scrollController,
                  children: [
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Text(
                        "Select Restaurant",
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                      child: Text(
                        "Please select a school first.",
                        style:
                            TextStyle(fontFamily: 'Montserrat', fontSize: 16),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text(
                            "Ok",
                            style: TextStyle(fontFamily: 'Montserrat'),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      );
    }
  }

  Widget _buildRectangularTab(Map<String, dynamic> tab) {
    return InkWell(
      onTap: () {
        if (tab["label"] == "Favorites") {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => FavoritesScreen(
                userPreferences: widget.userPreferences,
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                '${tab["label"]} tapped (Placeholder)',
                style: const TextStyle(fontFamily: 'SanFrancisco'),
              ),
            ),
          );
        }
      },
      child: Container(
        width: 130,
        height: 42,
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          color: tab["color"].withOpacity(0.65),
          borderRadius: BorderRadius.circular(12),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(tab["icon"], color: Colors.white, size: 20),
            const SizedBox(width: 6),
            Text(
              tab["label"],
              style: const TextStyle(
                fontFamily: 'SanFrancisco',
                fontSize: 14,
                fontWeight: FontWeight.normal,
                color: Colors.white,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopComboImage() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: _isDarkMode ? Colors.grey[850] : Colors.grey[300],
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(8),
              topRight: Radius.circular(8),
              bottomRight: Radius.circular(8),
              bottomLeft: Radius.circular(0),
            ),
          ),
          child: Text(
            "Gist",
            style: TextStyle(
              fontFamily: 'SanFrancisco',
              fontSize: 16,
              color: themeColor,
              fontWeight: FontWeight.normal,
            ),
          ),
        ),
        SizedBox(
          height: MediaQuery.of(context).size.height * 0.36,
          child: PageView.builder(
            controller: _pageController,
            onPageChanged: (index) {
              setState(() {
                _slideshowIndex = index % _slideshowImages.length;
              });
            },
            itemCount: _slideshowImages.length * 100,
            itemBuilder: (context, index) {
              final actualIndex = index % _slideshowImages.length;
              final scale = _slideshowIndex == actualIndex ? 1.0 : 0.9;
              return TweenAnimationBuilder(
                duration: const Duration(milliseconds: 300),
                tween: Tween(begin: scale, end: scale),
                builder: (context, value, child) {
                  return Transform.scale(
                    scale: value,
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: actualIndex != _slideshowIndex ? 15.0 : 0.0,
                      ),
                      child: child,
                    ),
                  );
                },
                child: Image.asset(
                  _slideshowImages[actualIndex],
                  fit: BoxFit.contain,
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              _slideshowCaptions[_slideshowIndex],
              style: const TextStyle(
                fontFamily: 'SanFrancisco',
                fontSize: 18,
                fontWeight: FontWeight.normal,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildCustomFooter() {
    final List<IconData> iconItems = [
      BoxIcons.bxs_home,
      BoxIcons.bxs_leaf,
      BoxIcons.bxs_credit_card,
      BoxIcons.bxs_user,
    ];
    final List<int> navIndexes = [0, 1, 3, 4];
    final List<VoidCallback> navActions = [
      () => setState(() => _selectedIndex = 0),
      () => setState(() => _selectedIndex = 1),
      () => setState(() => _selectedIndex = 3),
      () => setState(() => _selectedIndex = 4),
    ];
    return Container(
      height: 56,
      color: Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(iconItems.length, (index) {
          final bool isSelected = _selectedIndex == navIndexes[index];
          return GestureDetector(
            onTap: navActions[index],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Icon(
                iconItems[index],
                size: 28,
                color: isSelected
                    ? themeColor
                    : (_isDarkMode ? Colors.white : Colors.black87),
              ),
            ),
          );
        }),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      backgroundColor: _isDarkMode ? Colors.grey[900] : Colors.grey[100],
      elevation: 0,
      centerTitle: true,
      leading: Builder(
        builder: (context) => IconButton(
          icon: const Icon(Icons.notifications, size: 36),
          onPressed: () {
            // TODO: Implement notification functionality
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
          color: widget.userPreferences.schoolId?.isNotEmpty == true
              ? themeColor
              : Colors.white,
          onPressed: _chooseUniversity,
        ),
      ],
    );
  }

  void _goToAvailableOptions() async {
    final budget = double.tryParse(_budgetController.text) ?? 0;
    if (budget <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter a valid budget.")),
      );
      return;
    }

    if (_selectedRestaurants.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please select at least one vendor.")),
      );
      return;
    }

    widget.userPreferences.budget = budget;
    await widget.userPreferences.savePreferences();

    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AvailableOptionsScreen(
          userPreferences: widget.userPreferences,
          selectedRestaurants: _selectedRestaurants,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = _isDarkMode ? Colors.grey[900] : Colors.grey[100];
    final double horizontalBarWidth = MediaQuery.of(context).size.width * 0.85;
    const vendorBudgetTextSizeFactor = 0.7;

    return Theme(
      data: _isDarkMode
          ? ThemeData.dark().copyWith(scaffoldBackgroundColor: bgColor)
          : ThemeData.light().copyWith(scaffoldBackgroundColor: bgColor),
      child: Scaffold(
        bottomNavigationBar: _buildCustomFooter(),
        appBar: _selectedIndex == 0 ? _buildAppBar() : null,
        body: SafeArea(
          child: IndexedStack(
            index: _selectedIndex,
            children: [
              Padding(
                padding: const EdgeInsets.only(
                    left: 16, top: 16, right: 16, bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const SizedBox(height: 30),
                    const Spacer(),
                    GestureDetector(
                      onTap: () {
                        setState(() {
                          _vendorBarTapped = true;
                        });
                        _showRestaurantSelection();
                      },
                      child: Container(
                        width: horizontalBarWidth,
                        height: 44,
                        decoration: BoxDecoration(
                          color:
                              _isDarkMode ? Colors.grey[800] : Colors.grey[200],
                          borderRadius: BorderRadius.circular(25),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Icon(BoxIcons.bxs_store,
                                color: themeColor, size: 20),
                            const SizedBox(width: 8),
                            Expanded(
                              child: _selectedRestaurants.isNotEmpty
                                  ? SingleChildScrollView(
                                      scrollDirection: Axis.horizontal,
                                      child: Row(
                                        children: _selectedRestaurants
                                            .map(
                                              (vendor) => Padding(
                                                padding: const EdgeInsets.only(
                                                    right: 12),
                                                child: Chip(
                                                  label: Text(
                                                    vendor,
                                                    style: TextStyle(
                                                      fontFamily:
                                                          'SanFrancisco',
                                                      fontSize: 18 *
                                                          vendorBudgetTextSizeFactor,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                  backgroundColor: _isDarkMode
                                                      ? Colors.grey[700]
                                                      : Colors.grey[300],
                                                ),
                                              ),
                                            )
                                            .toList(),
                                      ),
                                    )
                                  : Text(
                                      "Select Vendor",
                                      style: TextStyle(
                                        fontFamily: 'SanFrancisco',
                                        fontSize:
                                            22 * vendorBudgetTextSizeFactor,
                                        color: Colors.white54,
                                      ),
                                    ),
                            ),
                            !_vendorBarTapped
                                ? Icon(BoxIcons.bxs_chevron_down,
                                    color: themeColor, size: 22)
                                : const SizedBox.shrink(),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Container(
                      width: horizontalBarWidth,
                      height: 44,
                      decoration: BoxDecoration(
                        color:
                            _isDarkMode ? Colors.grey[800] : Colors.grey[200],
                        borderRadius: BorderRadius.circular(25),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
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
                                color: Colors.white,
                              ),
                              decoration: InputDecoration(
                                hintText: "Enter Budget",
                                hintStyle: TextStyle(
                                  fontFamily: 'SanFrancisco',
                                  color: Colors.white54,
                                  fontSize: 22 * vendorBudgetTextSizeFactor,
                                ),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                          _budgetFocusNode.hasFocus || _isBudgetEntered
                              ? InkWell(
                                  onTap: _goToAvailableOptions,
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: themeColor,
                                      shape: BoxShape.circle,
                                    ),
                                    padding: const EdgeInsets.all(6),
                                    child: const Icon(
                                      BoxIcons.bxs_chevron_right,
                                      color: Colors.white,
                                      size: 22,
                                    ),
                                  ),
                                )
                              : Icon(BoxIcons.bxs_chevron_right,
                                  color: themeColor, size: 22),
                        ],
                      ),
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
                              .toList(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _buildTopComboImage(),
                    ),
                  ],
                ),
              ),
              DietScreen(),
              FavoritesScreen(userPreferences: widget.userPreferences),
              SubscriptionScreen(
                userPreferences: widget.userPreferences,
                themeColor: themeColor,
              ),
              ProfileScreen(
                userPreferences: widget.userPreferences,
                onSave: () {
                  setState(() {
                    _selectedIndex = 0;
                  });
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}
