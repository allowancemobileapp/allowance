// lib/screens/home/available_options_screen.dart

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/services/api_service.dart';
import 'package:url_launcher/url_launcher.dart';

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
  late Future<List<dynamic>> _foodGroupsFuture;
  late Future<List<dynamic>> _deliveryPersonnelFuture;

  List<dynamic> _groups = [];
  String _selectedGroup = 'All';
  List<dynamic> _allOptions = [];
  late Set<String> _favoritedOptionIds;

  // Filter state
  final List<Map<String, dynamic>> _foodSections = [];
  final Set<String> _selectedFoodItems = {};

  @override
  void initState() {
    super.initState();

    _favoritedOptionIds = widget.userPreferences.favoritedOptions
        .map((e) => e.toString())
        .toSet();

    _foodGroupsFuture = ApiService.fetchFoodGroups();
    _optionsFuture = ApiService.fetchOptions();
    _deliveryPersonnelFuture = ApiService.fetchDeliveryPersonnel(
        widget.userPreferences.schoolId.toString());

    _foodGroupsFuture.then((foodGroups) {
      final groupsList = <Map<String, dynamic>>[
        {"id": "all", "name": "All"}
      ];
      for (var group in foodGroups) {
        groupsList.add({
          "id": group['id'].toString(),
          "name": group['name'].toString(),
        });
      }
      setState(() => _groups = groupsList);
    });

    _optionsFuture.then((value) {
      _allOptions = value;
      setState(() {});
    });
  }

  int getItemPrice(dynamic item) {
    final priceValue = item["price"];
    if (priceValue is num) return priceValue.toInt();
    return int.tryParse(priceValue.toString()) ?? 0;
  }

  String getItemName(dynamic item) => item["name"].toString();

  double getAdjustedPrice(dynamic item) {
    final price = (item['price'] as num?)?.toDouble() ?? 0;
    switch (item['portion']) {
      case 'Half':
        return price / 2;
      case 'Three-Quarter':
        return price * 0.75;
      default:
        return price;
    }
  }

  List<dynamic> _filteredOptions(List<dynamic> options) {
    final budget = widget.userPreferences.budget?.toDouble() ?? double.infinity;
    return options.where((option) {
      final groupId = option["group_id"]?.toString() ?? "";
      final vendorName = option["vendors"]?["name"]?.toString() ?? "";
      if (!widget.selectedRestaurants.contains(vendorName)) return false;

      var selGroup = _groups.firstWhere(
        (g) => g["name"] == _selectedGroup,
        orElse: () => {"id": "all"},
      )["id"];
      selGroup = selGroup.toString();

      final items = (option["items"] as List<dynamic>? ?? []);
      if (items.any((i) => _selectedFoodItems.contains(i["name"]))) {
        return false;
      }

      final total = items.fold<double>(
        0,
        (sum, i) => sum + getAdjustedPrice(i),
      );
      return (selGroup == "all" || groupId == selGroup) && total <= budget;
    }).toList();
  }

  void _showFilterPopup() {
    _foodSections.clear();
    final categories = <String, Set<String>>{};
    for (var option in _allOptions) {
      final items = option['items'] as List<dynamic>? ?? [];
      for (var item in items) {
        final cat = item['category']?.toString() ?? "Uncategorized";
        final name = item['name']?.toString() ?? "Unknown";
        if (cat != "Uncategorized") {
          categories.putIfAbsent(cat, () => <String>{}).add(name);
        }
      }
    }
    categories.forEach((cat, names) {
      _foodSections.add({"name": cat, "items": names});
    });
    setState(() {});
  }

  void _showDeliveryPicker(Map<String, dynamic> selectedOption) {
    // build a text summary of the selected option
    final vendorName = selectedOption['vendors']['name'].toString();
    final items = (selectedOption['items'] as List<dynamic>);
    final itemList = items.map((i) => i['name'].toString()).join(', ');
    final total = items
        .fold<double>(0, (sum, i) => sum + getAdjustedPrice(i))
        .toStringAsFixed(0);

    final message = Uri.encodeComponent(
      'Hello! I\'d like to order from $vendorName:\n'
      'Items: $itemList\n'
      'Total: ₦$total',
    );

    showModalBottomSheet(
      context: context,
      builder: (_) => FutureBuilder<List<dynamic>>(
        future: _deliveryPersonnelFuture,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const SizedBox(
              height: 200,
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final list = snap.data ?? [];
          if (list.isEmpty) {
            return const SizedBox(
              height: 200,
              child: Center(child: Text('No delivery personnel available.')),
            );
          }
          list.shuffle(Random());
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Select your guy/gal',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: themeColor,
                  ),
                ),
                const SizedBox(height: 8),
                for (var person in list)
                  ListTile(
                    title: Text('${person['name']} (${person['gender']})'),
                    trailing: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: themeColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: () async {
                        final urlBase =
                            person['whatsapp_url']?.toString() ?? '';
                        final uri = Uri.parse('$urlBase?text=$message');
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri);
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content:
                                  Text('WhatsApp not available on this device'),
                            ),
                          );
                        }
                      },
                      child: const Text('Contact'),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
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
          child: Image.asset('assets/images/options.png', height: 130),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list, color: Colors.white),
            onPressed: () {
              _showFilterPopup();
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                builder: (ctx) => StatefulBuilder(
                  builder: (ctx, setState) => SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Filter Options',
                            style: TextStyle(
                              color: themeColor,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          for (var section in _foodSections)
                            ExpansionTile(
                              collapsedIconColor: themeColor,
                              title: Text(section['name']),
                              children: [
                                for (var item in section['items'])
                                  CheckboxListTile(
                                    title: Text(item),
                                    activeColor: themeColor,
                                    value: !_selectedFoodItems.contains(item),
                                    onChanged: (v) => setState(() {
                                      if (v == true) {
                                        _selectedFoodItems.remove(item);
                                      } else {
                                        _selectedFoodItems.add(item);
                                      }
                                    }),
                                  ),
                              ],
                            ),
                          const SizedBox(height: 16),
                          Align(
                            alignment: Alignment.bottomRight,
                            child: TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: Text('Close',
                                  style: TextStyle(color: themeColor)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ).then((_) => setState(() {}));
            },
          ),
        ],
      ),
      body: FutureBuilder<List<dynamic>>(
        future: _optionsFuture,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          } else if (snap.hasData) {
            final options = snap.data!;
            return Column(
              children: [
                if (_groups.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: SizedBox(
                      height: 40,
                      child: ListView.builder(
                        scrollDirection: Axis.horizontal,
                        itemCount: _groups.length,
                        itemBuilder: (ctx, i) {
                          final name = _groups[i]['name'];
                          final selected = name == _selectedGroup;
                          return GestureDetector(
                            onTap: () => setState(() => _selectedGroup = name),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 8),
                              margin: const EdgeInsets.only(right: 8),
                              decoration: BoxDecoration(
                                color: selected ? themeColor : Colors.grey[800],
                                borderRadius: BorderRadius.circular(20),
                              ),
                              alignment: Alignment.center,
                              child: Text(
                                name,
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
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _filteredOptions(options).length,
                    itemBuilder: (ctx, i) {
                      final option = _filteredOptions(options)[i];
                      final vendor = option['vendors']['name'] ?? '';
                      final items = option['items'] as List<dynamic>? ?? [];
                      final total = items.fold<double>(
                          0, (sum, itm) => sum + getAdjustedPrice(itm));
                      final idStr = option['id'].toString();
                      final isFav = _favoritedOptionIds.contains(idStr);

                      return TweenAnimationBuilder<Offset>(
                        tween: Tween(
                            begin: const Offset(0, 0.1), end: Offset.zero),
                        duration: const Duration(milliseconds: 500),
                        builder: (c, off, child) =>
                            Transform.translate(offset: off, child: child),
                        child: Card(
                          color: Colors.grey[800]!.withOpacity(0.7),
                          elevation: 4,
                          margin: const EdgeInsets.symmetric(vertical: 5),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
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
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          vendor,
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
                                                size: 26,
                                                color: Colors.white,
                                              ),
                                              onPressed: () =>
                                                  _showDeliveryPicker(option),
                                            ),
                                            IconButton(
                                              icon: Icon(
                                                isFav
                                                    ? Icons.favorite
                                                    : Icons.favorite_border,
                                                color: isFav
                                                    ? Colors.red
                                                    : Colors.white,
                                                size: 26,
                                              ),
                                              onPressed: () {
                                                setState(() {
                                                  if (isFav) {
                                                    _favoritedOptionIds
                                                        .remove(idStr);
                                                  } else {
                                                    _favoritedOptionIds
                                                        .add(idStr);
                                                  }
                                                  widget.userPreferences
                                                          .favoritedOptions =
                                                      _favoritedOptionIds;
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
                                        color: Colors.white38, thickness: 1),
                                    const SizedBox(height: 8),
                                    for (var itm in items)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 4),
                                        child: Text(
                                          '${getItemName(itm)} - ₦${getAdjustedPrice(itm).toStringAsFixed(0)}',
                                          style: const TextStyle(
                                            fontFamily: 'SanFrancisco',
                                            fontSize: 16,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              Container(
                                width: double.infinity,
                                color: themeColor,
                                padding: const EdgeInsets.symmetric(
                                    vertical: 8, horizontal: 12),
                                child: Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Row(
                                      children: [
                                        const Text(
                                          'Total: ₦',
                                          style: TextStyle(
                                            fontFamily: 'SanFrancisco',
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                        Text(
                                          total.toStringAsFixed(0),
                                          style: const TextStyle(
                                            fontFamily: 'SanFrancisco',
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ],
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
                ),
              ],
            );
          }
          return const Center(child: Text("No data available."));
        },
      ),
    );
  }
}
