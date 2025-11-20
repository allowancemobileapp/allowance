// lib/screens/home/available_options_screen.dart

import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/services/api_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
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

  // New: real likes from server
  Map<int, int> _likeCounts = {};
  Set<int> _likedOptionIds = {};

  // Filter state
  final List<Map<String, dynamic>> _foodSections = [];
  final Set<String> _selectedFoodItems = {};

  final supabase = Supabase.instance.client;

  Future<void> _loadLikesData() async {
    try {
      // 1) Load all like rows and compute counts (works for signed-out users too)
      final countsResponse =
          await supabase.from('option_likes').select('option_id');

      final Map<int, int> counts = {};
      for (var row in countsResponse) {
        // defensive parsing
        final dynamic val = row['option_id'];
        if (val == null) continue;
        final id = val is int ? val : int.tryParse(val.toString());
        if (id == null) continue;
        counts[id] = (counts[id] ?? 0) + 1;
      }

      // 2) If signed in, load which options this user liked
      final user = supabase.auth.currentUser;
      final Set<int> likedIds = <int>{};
      if (user != null) {
        try {
          final userLikesResponse = await supabase
              .from('option_likes')
              .select('option_id')
              .eq('user_id', user.id);

          for (var row in userLikesResponse) {
            final dynamic val = row['option_id'];
            final id = val is int ? val : int.tryParse(val.toString());
            if (id != null) likedIds.add(id);
          }
        } catch (e) {
          debugPrint('Failed to load user likes: $e');
        }
      }

      // 3) Update UI and local favorites
      if (mounted) {
        setState(() {
          _likeCounts = counts;
          _likedOptionIds = likedIds;
        });

        // keep local favorites in sync when user is logged in
        if (user != null) {
          widget.userPreferences.favoritedOptions =
              likedIds.map((e) => e.toString()).toList();
          await widget.userPreferences.savePreferences();
        }
      }
    } catch (e) {
      debugPrint('Failed to load likes: $e');
    }
  }

  @override
  void initState() {
    super.initState();

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
      _loadLikesData(); // Load likes once options are ready
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
    final vendorName = selectedOption['vendors']['name'].toString();
    final items = (selectedOption['items'] as List<dynamic>);

    // 🧮 Calculate total
    final total = items
        .fold<double>(0, (sum, i) => sum + getAdjustedPrice(i))
        .toStringAsFixed(0);

    // 📝 Build detailed message
    final message = StringBuffer();
    message.writeln("Hello! I'd like to order from $vendorName:");
    message.writeln("Items:");

    for (var i in items) {
      final name = i['name'];
      final price = getAdjustedPrice(i).toStringAsFixed(0);
      final qty = i['quantity'] ?? 1;
      message.writeln("- $name (₦$price × $qty)");
    }

    message.writeln("Total: ₦$total");

    // 🧾 Show delivery picker modal
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
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
            return Container(
              decoration: BoxDecoration(
                color: Colors.grey[900],
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              padding: const EdgeInsets.all(16),
              height: 200,
              child: const Center(
                child: Text(
                  'Sorry, no delivery personnel are available right now.',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            );
          }

          list.shuffle(Random());

          return Container(
            decoration: BoxDecoration(
              color: Colors.grey[900],
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
            ),
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
                    title: Text(
                      '${person['name']} (${person['gender']})',
                      style: const TextStyle(color: Colors.white),
                    ),
                    trailing: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: themeColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: () => _openWhatsAppContact(
                        person,
                        message.toString(),
                      ),
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

  Future<void> _openWhatsAppContact(
      Map<String, dynamic> person, String rawMessage) async {
    try {
      final stored =
          (person['whatsapp_url'] ?? person['phone'] ?? person['mobile'] ?? '')
              .toString();
      String phoneOnly = stored.replaceAll(RegExp(r'[^0-9]'), '');

      if (phoneOnly.isEmpty) {
        final alt = (person['phone'] ?? person['mobile'] ?? '').toString();
        phoneOnly = alt.replaceAll(RegExp(r'[^0-9]'), '');
      }

      final encodedMessage = Uri.encodeComponent(rawMessage);

      // ✅ Directly use the native WhatsApp URI first (works best on Android/iOS)
      final whatsappUri =
          Uri.parse('whatsapp://send?phone=$phoneOnly&text=$encodedMessage');

      // ✅ Try WhatsApp Business fallback (for users with both installed)
      final whatsappBusinessUri = Uri.parse(
          'whatsapp-business://send?phone=$phoneOnly&text=$encodedMessage');

      // ✅ Web fallback (for browsers or desktop)
      final waWebUri =
          Uri.parse('https://wa.me/$phoneOnly?text=$encodedMessage');

      if (await canLaunchUrl(whatsappUri)) {
        await launchUrl(whatsappUri, mode: LaunchMode.externalApplication);
        return;
      } else if (await canLaunchUrl(whatsappBusinessUri)) {
        await launchUrl(whatsappBusinessUri,
            mode: LaunchMode.externalApplication);
        return;
      } else if (await canLaunchUrl(waWebUri)) {
        await launchUrl(waWebUri, mode: LaunchMode.externalApplication);
        return;
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Unable to open WhatsApp. Please make sure WhatsApp or WhatsApp Business is installed.',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Oops! Something went wrong while trying to open WhatsApp: $e')),
        );
      }
    }
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
                backgroundColor: Colors.grey[900],
                builder: (ctx) => Theme(
                  data: Theme.of(ctx).copyWith(
                    textTheme: Theme.of(ctx).textTheme.apply(
                          bodyColor: Colors.white,
                          displayColor: Colors.white,
                        ),
                    iconTheme: const IconThemeData(color: Colors.white70),
                  ),
                  child: StatefulBuilder(
                    builder: (ctx, modalSetState) => SingleChildScrollView(
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
                                title: Text(section['name'],
                                    style:
                                        const TextStyle(color: Colors.white)),
                                children: [
                                  for (var item in section['items'])
                                    CheckboxListTile(
                                      title: Text(item,
                                          style: const TextStyle(
                                              color: Colors.white)),
                                      activeColor: themeColor,
                                      checkColor: Colors.white,
                                      value: !_selectedFoodItems.contains(item),
                                      onChanged: (v) => modalSetState(() {
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
            return Center(
                child: Text(
                    'Oops! An error occurred while loading options: ${snap.error}. Please try again later.'));
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
                      final int optionId = option['id'] as int;
                      final bool isLiked = _likedOptionIds.contains(optionId);
                      final int likeCount = _likeCounts[optionId] ?? 0;

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

                                            // ❤️ Like button + like count
                                            Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                IconButton(
                                                  icon: Icon(
                                                    isLiked
                                                        ? Icons.favorite
                                                        : Icons.favorite_border,
                                                    color: isLiked
                                                        ? Colors.red
                                                        : Colors.white,
                                                    size: 26,
                                                  ),
                                                  onPressed: () async {
                                                    final user = supabase
                                                        .auth.currentUser;
                                                    if (user == null) {
                                                      if (mounted) {
                                                        ScaffoldMessenger.of(
                                                                context)
                                                            .showSnackBar(
                                                          const SnackBar(
                                                            content: Text(
                                                                'Please log in to like items.'),
                                                          ),
                                                        );
                                                      }
                                                      return;
                                                    }

                                                    try {
                                                      if (isLiked) {
                                                        // Unlike
                                                        await supabase
                                                            .from(
                                                                'option_likes')
                                                            .delete()
                                                            .eq('option_id',
                                                                optionId)
                                                            .eq('user_id',
                                                                user.id);

                                                        if (mounted) {
                                                          setState(() {
                                                            _likedOptionIds
                                                                .remove(
                                                                    optionId);
                                                            final newCount =
                                                                (_likeCounts[
                                                                            optionId] ??
                                                                        1) -
                                                                    1;
                                                            _likeCounts[
                                                                    optionId] =
                                                                newCount < 0
                                                                    ? 0
                                                                    : newCount;
                                                          });
                                                        }
                                                      } else {
                                                        // Like
                                                        try {
                                                          await supabase
                                                              .from(
                                                                  'option_likes')
                                                              .insert({
                                                            'option_id':
                                                                optionId,
                                                            'user_id': user.id,
                                                          });
                                                        } catch (e) {
                                                          // If duplicate like error, ignore it safely
                                                          debugPrint(
                                                              'Like insert error (ignored if duplicate): $e');
                                                        }

                                                        if (mounted) {
                                                          setState(() {
                                                            _likedOptionIds
                                                                .add(optionId);
                                                            _likeCounts[
                                                                    optionId] =
                                                                (_likeCounts[
                                                                            optionId] ??
                                                                        0) +
                                                                    1;
                                                          });
                                                        }
                                                      }

                                                      // Sync favorites for Favorites screen
                                                      widget.userPreferences
                                                              .favoritedOptions =
                                                          _likedOptionIds
                                                              .map((e) =>
                                                                  e.toString())
                                                              .toList();
                                                      await widget
                                                          .userPreferences
                                                          .savePreferences();
                                                    } catch (e) {
                                                      if (mounted) {
                                                        ScaffoldMessenger.of(
                                                                context)
                                                            .showSnackBar(
                                                          SnackBar(
                                                              content: Text(
                                                                  'Like failed: $e')),
                                                        );
                                                      }
                                                    }
                                                  },
                                                ),
                                                Text(
                                                  likeCount.toString(),
                                                  style: const TextStyle(
                                                    color: Colors.white70,
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w500,
                                                  ),
                                                ),
                                              ],
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
          return const Center(
              child: Text(
                  'No options available right now. Try adjusting your preferences!'));
        },
      ),
    );
  }
}
