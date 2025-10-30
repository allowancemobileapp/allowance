// lib/screens/home/favorites_screen.dart

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/services/api_service.dart';

class FavoritesScreen extends StatefulWidget {
  final UserPreferences userPreferences;

  const FavoritesScreen({
    super.key,
    required this.userPreferences,
  });

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  final Color themeColor = const Color(0xFF4CAF50);
  late Future<List<dynamic>> _optionsFuture;
  late Future<List<dynamic>> _foodGroupsFuture;
  late Future<List<dynamic>> _deliveryPersonnelFuture;
  List<dynamic> _groups = [];
  String _selectedGroup = 'All';

  // Favorite IDs
  late Set<String> _favoritedOptionIds;
  // All options fetched
  List<dynamic> _allOptions = [];

  // Filter state
  final List<Map<String, dynamic>> _foodSections = [];
  final Set<String> _selectedFoodItems = {};

  @override
  void initState() {
    super.initState();
    _optionsFuture = ApiService.fetchOptions();
    _foodGroupsFuture = ApiService.fetchFoodGroups();
    _deliveryPersonnelFuture = ApiService.fetchDeliveryPersonnel(
      widget.userPreferences.schoolId.toString(),
    );

    _favoritedOptionIds = widget.userPreferences.favoritedOptions
        .map((e) => e.toString())
        .toSet();

    _foodGroupsFuture.then((foodGroups) {
      final groupsSet = <Map<String, dynamic>>[
        {'id': 'all', 'name': 'All'}
      ];
      for (var group in foodGroups) {
        groupsSet.add({
          'id': group['id'].toString(),
          'name': group['name'].toString(),
        });
      }
      setState(() => _groups = groupsSet);
    });

    _optionsFuture.then((opts) {
      _allOptions = opts;
      setState(() {});
    });
  }

  // --- DELIVERY POPUP ---
  void _showDeliveryPicker(Map<String, dynamic> selectedOption) {
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
      backgroundColor: Colors.grey[900],
      builder: (_) => FutureBuilder<List<dynamic>>(
        future: _deliveryPersonnelFuture,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const SizedBox(
              height: 200,
              child:
                  Center(child: CircularProgressIndicator(color: Colors.white)),
            );
          }

          final list = snap.data ?? [];
          if (list.isEmpty) {
            return const SizedBox(
              height: 200,
              child: Center(
                child: Text('No delivery personnel available.',
                    style: TextStyle(color: Colors.white70)),
              ),
            );
          }

          list.shuffle(Random());
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Select your delivery personnel',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: themeColor,
                  ),
                ),
                const SizedBox(height: 8),
                for (var person in list)
                  ListTile(
                    title: Text('${person['name']} (${person['gender']})',
                        style: const TextStyle(color: Colors.white)),
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

  // --- FILTER POPUP ---
  void _showFilterPopup(BuildContext context) {
    _foodSections.clear();
    final Map<String, Set<String>> categories = {};
    for (var option in _allOptions) {
      final items = option['items'] is List<dynamic>
          ? option['items'] as List<dynamic>
          : [];
      for (var it in items) {
        final cat = it['category']?.toString() ?? 'Uncategorized';
        final name = it['name']?.toString() ?? 'Unknown';
        if (cat != 'Uncategorized') {
          categories.putIfAbsent(cat, () => <String>{}).add(name);
        }
      }
    }
    categories.forEach((cat, names) {
      _foodSections.add({'name': cat, 'items': names.toList()});
    });
    setState(() {});

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.grey[900],
      builder: (_) => StatefulBuilder(
        builder: (ctx, setState) => SingleChildScrollView(
          child: Container(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Filter Options',
                    style: TextStyle(
                        color: themeColor,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),
                ..._foodSections.map((section) => ExpansionTile(
                      collapsedIconColor: themeColor,
                      title: Text(section['name'],
                          style: const TextStyle(color: Colors.white)),
                      children: (section['items'] as List<String>)
                          .map((item) => CheckboxListTile(
                                title: Text(item,
                                    style:
                                        const TextStyle(color: Colors.white)),
                                activeColor: themeColor,
                                value: !_selectedFoodItems.contains(item),
                                onChanged: (v) => setState(() {
                                  if (v == false) {
                                    _selectedFoodItems.add(item);
                                  } else {
                                    _selectedFoodItems.remove(item);
                                  }
                                }),
                              ))
                          .toList(),
                    )),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('Close', style: TextStyle(color: themeColor)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ).then((_) => setState(() {}));
  }

  // --- HELPERS ---
  List<dynamic> _filteredOptions(List<dynamic> options) {
    return options.where((option) {
      final idStr = option['id'].toString();
      if (!_favoritedOptionIds.contains(idStr)) return false;

      final groupId = option['group_id']?.toString() ?? '';
      if (_selectedGroup != 'All') {
        final selectedGroup = _groups
            .firstWhere((g) => g['name'] == _selectedGroup)['id']
            .toString();
        if (groupId != selectedGroup) return false;
      }

      final items = option['items'] is List<dynamic>
          ? option['items'] as List<dynamic>
          : [];
      if (items.any((i) {
        return _selectedFoodItems.contains(i['name'].toString());
      })) {
        return false;
      }

      return true;
    }).toList();
  }

  String getItemName(dynamic item) => item['name'].toString();

  double getAdjustedPrice(dynamic item) {
    final price = (item['price'] as num?)?.toDouble() ?? 0.0;
    switch (item['portion']) {
      case 'Half':
        return price / 2;
      case 'Three-Quarter':
        return price * 0.75;
      default:
        return price;
    }
  }

  // --- UI ---
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
            'assets/images/favorites.png',
            height: 130,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list, color: Colors.white),
            onPressed: () => _showFilterPopup(context),
          ),
        ],
      ),
      body: FutureBuilder<List<dynamic>>(
        future: _optionsFuture,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snap.hasError) {
            return Center(child: Text('Error: ${snap.error}'));
          } else if (!snap.hasData) {
            return const Center(child: Text('No data available.'));
          }

          final options = snap.data!;
          final displayed = _filteredOptions(options);

          return Column(
            children: [
              if (_groups.isNotEmpty) ...[
                const SizedBox(height: 16),
                SizedBox(
                  height: 40,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _groups.length,
                    itemBuilder: (c, i) {
                      final name = _groups[i]['name'];
                      final sel = name == _selectedGroup;
                      return GestureDetector(
                        onTap: () => setState(() => _selectedGroup = name),
                        child: Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: sel ? themeColor : Colors.grey[800],
                            borderRadius: BorderRadius.circular(20),
                          ),
                          alignment: Alignment.center,
                          child: Text(name,
                              style: const TextStyle(
                                  fontFamily: 'SanFrancisco',
                                  fontSize: 14,
                                  color: Colors.white)),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: displayed.length,
                  itemBuilder: (c, i) {
                    final option = displayed[i] as Map<String, dynamic>;
                    final vendor = option['vendors']['name'] ?? 'Unknown';
                    final items = option['items'] is List<dynamic>
                        ? option['items'] as List<dynamic>
                        : [];
                    final total = items.fold<double>(
                        0, (sum, it) => sum + getAdjustedPrice(it));
                    final idStr = option['id'].toString();
                    final isFav = _favoritedOptionIds.contains(idStr);

                    return TweenAnimationBuilder<Offset>(
                      tween:
                          Tween(begin: const Offset(0, 0.1), end: Offset.zero),
                      duration: const Duration(milliseconds: 500),
                      builder: (context, off, child) =>
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
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(vendor,
                                          style: const TextStyle(
                                              fontFamily: 'SanFrancisco',
                                              fontSize: 20,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white)),
                                      Row(
                                        children: [
                                          IconButton(
                                            icon: const Icon(
                                              Icons.delivery_dining,
                                              color: Colors.white,
                                              size: 26,
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
                                                    _favoritedOptionIds
                                                        .toList();
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
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: items.map((itm) {
                                      return Padding(
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
                                      );
                                    }).toList(),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              width: double.infinity,
                              decoration: BoxDecoration(
                                color: themeColor,
                                borderRadius: const BorderRadius.vertical(
                                    bottom: Radius.circular(8)),
                              ),
                              padding: const EdgeInsets.symmetric(
                                  vertical: 8, horizontal: 12),
                              child: Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      const Text('Total: ₦',
                                          style: TextStyle(
                                              fontFamily: 'SanFrancisco',
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white)),
                                      Text(total.toStringAsFixed(0),
                                          style: const TextStyle(
                                              fontFamily: 'SanFrancisco',
                                              fontSize: 16,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white)),
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
        },
      ),
    );
  }
}
