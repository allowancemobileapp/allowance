// lib/screens/home/available_options_screen.dart

import 'package:flutter/material.dart';
import 'dart:async';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/services/api_service.dart';

class AvailableOptionsScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  final List<String> selectedRestaurants;

  const AvailableOptionsScreen({
    super.key,
    required this.userPreferences,
    required this.selectedRestaurants,
  });

  @override
  State<AvailableOptionsScreen> createState() => _AvailableOptionsScreenState();
}

class _AvailableOptionsScreenState extends State<AvailableOptionsScreen> {
  final Color themeColor = const Color(0xFF4CAF50);
  late Future<List<dynamic>> _optionsFuture;
  List<dynamic> _groups = [];
  late Future<List<dynamic>> _foodGroupsFuture;
  String _selectedGroup = 'All';
  List<dynamic> _allOptions = [];

  // Filter state
  final List<Map<String, dynamic>> _foodSections =
      []; // List to store food sections and their items
  final Set<String> _selectedFoodItems = {}; // Set to track selected food items
  @override
  void initState() {
    super.initState();

    _foodGroupsFuture = ApiService.fetchFoodGroups();

    // Fetch and store all options
    _optionsFuture = ApiService.fetchOptions();

    _foodGroupsFuture.then((foodGroups) {
      final groupsList = <Map<String, dynamic>>[];
      final groupsSet = <Map<String, dynamic>>[
        {"id": "all", "name": "All"}
      ];
      for (var group in foodGroups) {
        groupsSet.add({
          "id": int.parse(group['id'].toString()),
          "name": group['name'].toString()
        });
      }

      // Convert to a list
      groupsList.addAll(groupsSet);
      setState(() {
        _groups = groupsList;
      });
    });
    _optionsFuture.then((value) {
      _allOptions = value;
      setState(() {});
    });
  }

  // Helper: Extract price from an item
  int getItemPrice(dynamic item) {
    final priceValue = item["price"];
    if (priceValue is num) return priceValue.toInt();
    return int.tryParse(priceValue.toString()) ?? 0;
  }

  // Helper: Extract name from an item
  String getItemName(dynamic item) {
    return item["name"].toString();
  }

  // Helper: Calculate the adjusted price based on portion
  double getAdjustedPrice(dynamic item) {
    final priceValue = item['price'];
    if (priceValue == null) {
      return 0; // Return 0 if price is null
    }
    final price = (priceValue as num).toDouble();
    final portion = item['portion'];
    switch (portion) {
      case 'Half':
        return price / 2;
      case 'Three-Quarter':
        return price * 0.75;
      default:
        return price;
    }
  }

  // Filter options based on selected restaurants and (if applicable) group filter
  List<dynamic> _filteredOptions(List<dynamic> options) {
    double budget =
        widget.userPreferences.budget?.toDouble() ?? double.infinity;
    return options.where((option) {
      final groupId = option["group_id"]?.toString() ?? "";
      final vendorName = option["vendors"]?["name"]?.toString() ?? "";
      final isRestaurantSelected =
          widget.selectedRestaurants.contains(vendorName);
      dynamic selectedGroupId = "all";

      double calculatedTotalPrice = 0;

      if (_groups.any((element) => element["name"] == _selectedGroup)) {
        selectedGroupId = _groups
            .firstWhere((element) => element["name"] == _selectedGroup)["id"];
      }

      // Check if any of the option's items are in the _selectedFoodItems set
      bool containsFilteredItem = option["items"]?.any(
              (item) => _selectedFoodItems.contains(item["name"].toString())) ??
          false;

      if (selectedGroupId is int) selectedGroupId = selectedGroupId.toString();
      final List<dynamic> items =
          option["items"] is List ? option["items"] : [];

      for (var item in items) {
        calculatedTotalPrice += getAdjustedPrice(item);
      }
      // Budget
      final isWithinBudget = calculatedTotalPrice <= budget;

      // If any of the option's items are in the selectedFoodItems, then dont show the item
      return (selectedGroupId == "all" || groupId == selectedGroupId) &&
          isWithinBudget &&
          isRestaurantSelected &&
          !containsFilteredItem;
    }).toList();
  }

  void _showFilterPopupForTesting(BuildContext context) {
    _foodSections.clear();
    final Map<String, Set<String>> categories = {};
    for (var option in _allOptions) {
      final List<dynamic> items =
          option["items"] is List ? option["items"] : [];
      for (var item in items) {
        final String category = item["category"]?.toString() ?? "Uncategorized";
        final String itemName = item["name"]?.toString() ?? "Unknown";
        if (category != "Uncategorized") {
          // Add this condition to filter out "Uncategorized"
          categories.putIfAbsent(
              category, () => <String>{}); // Use Set to store item names
          categories[category]!
              .add(itemName); // Use add to Set to avoid duplicates
        }
      }
    }

    categories.forEach((category, items) {
      _foodSections.add({"name": category, "items": items.toList()});
    });

    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        iconTheme: const IconThemeData(color: Colors.white),
        scrolledUnderElevation: 0,
        title: Center(
          child: Image.asset(
            'assets/images/options.png',
            height: 130,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list, color: Colors.white),
            onPressed: () {
              _showFilterPopupForTesting(context);
              showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  builder: (BuildContext context) {
                    return StatefulBuilder(
                        builder: (BuildContext context, StateSetter setState) {
                      return SingleChildScrollView(
                        child: Container(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              DefaultTextStyle(
                                style: TextStyle(
                                    color: themeColor,
                                    fontSize: 18,
                                    fontWeight: FontWeight
                                        .bold), // Set the desired color here
                                child: const Text(
                                  'Filter Options',
                                ),
                              ),
                              const SizedBox(height: 16),
                              ..._foodSections.map((section) {
                                return ExpansionTile(
                                  collapsedIconColor: themeColor,
                                  title: Text(section["name"]),
                                  children:
                                      (section["items"] as List).map((item) {
                                    return CheckboxListTile(
                                      title: Text(item),
                                      activeColor: themeColor,
                                      value: !_selectedFoodItems.contains(item),
                                      onChanged: (bool? value) {
                                        setState(() {
                                          if (value == false) {
                                            _selectedFoodItems.add(item);
                                          } else {
                                            _selectedFoodItems.remove(item);
                                          }
                                        });
                                      },
                                    );
                                  }).toList(),
                                );
                              }),
                              const SizedBox(height: 16),
                              Align(
                                alignment: Alignment.bottomRight,
                                child: TextButton(
                                    onPressed: () {
                                      Navigator.of(context).pop();
                                    },
                                    child: DefaultTextStyle(
                                        style: TextStyle(color: themeColor),
                                        child: const Text('Close'))),
                              ),
                            ],
                          ),
                        ),
                      );
                    });
                  }).then((_) {
                setState(() {}); //Rebuild main widget to apply the filters
              });
            },
          ),
        ],
      ),
      body: FutureBuilder<List<dynamic>>(
        future: _optionsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text("Error: ${snapshot.error}"));
          } else if (snapshot.hasData) {
            final List<dynamic> options = snapshot.data!;

            return Column(
              children: [
                // Groups section (if food_groups is provided in the record)

                if (_groups.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: SizedBox(
                      height: 40,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: _groups.length,
                        itemBuilder: (ctx, index) {
                          final groupName = _groups[index]["name"];
                          final isSelected = groupName == _selectedGroup;
                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                _selectedGroup = groupName;
                                //recalculate displayedOptions only when you tap on the group
                              });
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color:
                                    isSelected ? themeColor : Colors.grey[800],
                                borderRadius: BorderRadius.circular(20),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                groupName,
                                style: const TextStyle(
                                  fontFamily: 'SanFrancisco',
                                  fontSize: 14,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Builder(
                  builder: (context) {
                    List<dynamic> displayedOptions = _filteredOptions(options);
                    return Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: displayedOptions.length,
                        itemBuilder: (context, index) {
                          final option =
                              displayedOptions[index] as Map<String, dynamic>;
                          // For display, first try using combo_description;
                          final vendorName =
                              option["vendors"]["name"] ?? "Unknown Vendor";
                          // final title = option["combo_description"] ?? option["vendor_name"] ?? "";
                          final calories =
                              option["total_calories"]?.toString() ?? "0 kcal";
                          // Parse the list of items from the JSONB field.
                          final List<dynamic> items =
                              option["items"] is List ? option["items"] : [];
                          double calculatedTotalPrice = 0;
                          for (var item in items) {
                            calculatedTotalPrice += getAdjustedPrice(item);
                          }

                          return TweenAnimationBuilder(
                            tween: Tween<Offset>(
                              begin: const Offset(0, 0.1),
                              end: Offset.zero,
                            ),
                            duration: const Duration(milliseconds: 500),
                            builder: (context, Offset offset, child) {
                              return Transform.translate(
                                offset: offset,
                                child: child,
                              );
                            },
                            child: Card(
                              color: Colors.grey[800]!.withOpacity(0.7),
                              elevation: 4,
                              margin: const EdgeInsets.symmetric(vertical: 5),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 8),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        // Display the vendor name and icons for delivery and favorites
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              vendorName,
                                              style: const TextStyle(
                                                fontFamily: 'SanFrancisco',
                                                fontSize: 20,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                            Row(
                                              children: [
                                                IconButton(
                                                  icon: const Icon(
                                                    Icons.delivery_dining,
                                                    color: Colors.white,
                                                    size: 26,
                                                  ),
                                                  onPressed: () {
                                                    // Implement your delivery logic here.
                                                  },
                                                ),
                                                IconButton(
                                                  icon: Icon(
                                                    widget.userPreferences
                                                            .favoritedOptions
                                                            .contains(
                                                                option["id"])
                                                        ? Icons.favorite
                                                        : Icons.favorite_border,
                                                    color: widget
                                                            .userPreferences
                                                            .favoritedOptions
                                                            .contains(
                                                                option["id"])
                                                        ? Colors.red
                                                        : null,
                                                    size: 26,
                                                  ),
                                                  onPressed: () {
                                                    setState(() {
                                                      if (widget.userPreferences
                                                          .favoritedOptions
                                                          .contains(
                                                              option["id"])) {
                                                        widget.userPreferences
                                                            .favoritedOptions
                                                            .remove(
                                                                option["id"]);
                                                      } else {
                                                        widget.userPreferences
                                                            .favoritedOptions
                                                            .add(option["id"]);
                                                      }
                                                      widget.userPreferences
                                                          .savePreferences();
                                                    });
                                                  },
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        const Divider(
                                          color: Colors.white38,
                                          thickness: 1,
                                        ),
                                        const SizedBox(height: 8),
                                        // List each meal/item within the combo
                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: items.map((item) {
                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                  bottom: 4),
                                              child: Text(
                                                '${getItemName(item)} - ₦${getAdjustedPrice(item).toStringAsFixed(0)}',
                                                style: const TextStyle(
                                                  fontFamily: 'SanFrancisco',
                                                  fontSize: 16,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Bottom row with the total price and calorie count
                                  Container(
                                    width: double.infinity,
                                    decoration: BoxDecoration(
                                      color: themeColor,
                                      borderRadius: BorderRadius.zero,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 8, horizontal: 12),
                                    child: Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Row(
                                          children: [
                                            const Text(
                                              "Total: ₦",
                                              style: TextStyle(
                                                fontFamily: 'SanFrancisco',
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                            Text(
                                              calculatedTotalPrice
                                                  .toStringAsFixed(0),
                                              style: const TextStyle(
                                                fontFamily: 'SanFrancisco',
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Text(
                                          "Calories: $calories",
                                          style: const TextStyle(
                                            fontFamily: 'SanFrancisco',
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    );
                  },
                ),
              ],
            );
          } else {
            return const Center(child: Text("No data available."));
          }
        },
      ),
    );
  }
}
