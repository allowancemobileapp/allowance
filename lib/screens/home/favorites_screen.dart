// lib/screens/home/favorites_screen.dart
import 'dart:convert';

import 'package:allowance/screens/chat/individual_chat_screen.dart';
import 'package:allowance/screens/home/subscription_screen.dart';
import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/services/api_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
  List<dynamic> _groups = [];
  String _selectedGroup = 'All';
  // Favorite IDs
  Set<String> _favoritedOptionIds = <String>{};
  // All options fetched
  List<dynamic> _allOptions = [];
  // Filter state
  final List<Map<String, dynamic>> _foodSections = [];
  final Set<String> _selectedFoodItems = {};

  // Likes data
  Map<int, int> _likeCounts = {};
  Set<int> _likedOptionIds = {};

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
          setState(() {
            _favoritedOptionIds = likedIds.map((e) => e.toString()).toSet();
          });
        }
      }
    } catch (e) {
      debugPrint('Failed to load likes: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    print(widget.userPreferences.schoolId);
    _favoritedOptionIds = widget.userPreferences.favoritedOptions
        .map((e) => e.toString())
        .toSet();
    _optionsFuture =
        ApiService.fetchOptions(widget.userPreferences.schoolId ?? '');
    _foodGroupsFuture = ApiService.fetchFoodGroups();
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
    _loadLikesData();
  }

  // --- DELIVERY POPUP ---
  // --- DELIVERY POPUP (with real paywall) ---
  // --- UPDATED: Pass Order as JSON ---
  void _showDeliveryPicker(Map<String, dynamic> selectedOption) {
    final isPremium = widget.userPreferences.subscriptionTier == 'Membership';

    if (!isPremium) {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.grey[900],
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
        builder: (ctx) => Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_rounded, size: 64, color: Colors.amber),
              const SizedBox(height: 16),
              const Text('Subscribe to Allowance Plus',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
              const SizedBox(height: 12),
              const Text(
                  'to get access to our trusted and verified delivery agents',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.white70)),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => SubscriptionScreen(
                                userPreferences: widget.userPreferences,
                                themeColor: themeColor)));
                  },
                  style: ElevatedButton.styleFrom(
                      backgroundColor: themeColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: const Text('Subscribe to Allowance Plus',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Maybe later',
                      style: TextStyle(color: Colors.white70))),
            ],
          ),
        ),
      );
      return;
    }

    final vendorName =
        selectedOption['vendors']?['name']?.toString() ?? 'Vendor';
    final items = selectedOption['items'] as List<dynamic>;
    final total = items.fold<double>(0, (sum, i) => sum + getAdjustedPrice(i));

    // Formatted strictly as JSON map
    final orderData = {
      'vendor': vendorName,
      'items': items
          .map((i) => {
                'name': i['name'],
                'price': getAdjustedPrice(i).toStringAsFixed(0),
                'qty': i['quantity'] ?? 1,
              })
          .toList(),
      'total': total.toStringAsFixed(0)
    };

    _openDeliveryAgentGrid(orderData);
  }

  // --- UPDATED: Fixes overflow & removes "Contact" button ---
  // --- UPDATED: Fixes overflow & removes "Contact" button ---
  void _openDeliveryAgentGrid(Map<String, dynamic> orderData) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Container(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Select a Runner 🏃‍♂️',
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: themeColor)),
            ),
            const Divider(height: 1, color: Colors.white24),
            Expanded(
              child: FutureBuilder<List<dynamic>>(
                future: supabase
                    .from('profiles')
                    .select('id, username, avatar_url, gender')
                    .eq('is_delivery_agent', true)
                    .eq('is_available_for_delivery', true)
                    .eq('school_id', widget.userPreferences.schoolId ?? ''),
                builder: (ctx, snap) {
                  if (snap.connectionState == ConnectionState.waiting)
                    return const Center(child: CircularProgressIndicator());
                  final list = snap.data ?? [];

                  if (list.isEmpty)
                    return const Center(
                        child: Text('No agents available right now 😴',
                            style: TextStyle(color: Colors.white70)));

                  list.shuffle();

                  return GridView.builder(
                    padding: const EdgeInsets.all(16),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 10,
                      mainAxisSpacing: 16,
                      childAspectRatio: 0.85,
                    ),
                    itemCount: list.length,
                    itemBuilder: (ctx, i) {
                      final person = list[i];
                      return GestureDetector(
                        onTap: () => _sendOrderToAppChat(person, orderData),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            CircleAvatar(
                              radius: 36,
                              backgroundColor: Colors.grey[800],
                              backgroundImage: person['avatar_url'] != null
                                  ? NetworkImage(person['avatar_url'])
                                  : null,
                              child: person['avatar_url'] == null
                                  ? const Icon(Icons.delivery_dining,
                                      color: Colors.white54, size: 30)
                                  : null,
                            ),
                            const SizedBox(height: 8),
                            Text(person['username'] ?? 'Agent',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            if (person['gender'] != null)
                              Text(person['gender'],
                                  style: const TextStyle(
                                      color: Colors.white54, fontSize: 11)),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- UPDATED: Does NOT auto-send. Simply passes the order JSON! ---
  // --- UPDATED: Safe version for non-cart screens ---
  Future<void> _sendOrderToAppChat(
      Map<String, dynamic> person, Map<String, dynamic> orderData) async {
    try {
      final myId = supabase.auth.currentUser!.id;
      final agentId = person['id'];

      showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const Center(
              child: CircularProgressIndicator(color: Color(0xFF4CAF50))));

      final response = await supabase.rpc('get_or_create_personal_chat',
          params: {'user_a': myId, 'user_b': agentId});
      final chatId = response.toString();

      final String orderJson = jsonEncode(orderData);

      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        Navigator.pop(context); // Close bottom sheet

        // Passes the order into the chat screen as a pending order!
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => IndividualChatScreen(
              chatId: chatId,
              recipientProfile: {
                'id': agentId,
                'username': person['username'] ?? 'Delivery Agent',
                'avatar_url': person['avatar_url'],
                'school_name': widget.userPreferences.schoolName,
                'is_group': false,
                'pending_order': orderJson,
              },
              userPreferences: widget.userPreferences,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to route order.')));
      }
    }
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
            return Center(
              child: Text(
                'Could not load menu: ${snap.error}\nMake sure your school is selected.',
                style: TextStyle(color: Colors.red),
              ),
            );
          } else if (!snap.hasData) {
            return const Center(
                child:
                    Text('No favorites available right now. Try adding some!'));
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
                    final optionId = int.tryParse(idStr) ?? 0;
                    final isFav = _favoritedOptionIds.contains(idStr);
                    final likeCount = _likeCounts[optionId] ?? 0;
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
                                          Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
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
                                                  final user =
                                                      supabase.auth.currentUser;
                                                  if (!isFav) {
                                                    // Like
                                                    if (user == null) {
                                                      ScaffoldMessenger.of(
                                                              context)
                                                          .showSnackBar(
                                                        const SnackBar(
                                                          content: Text(
                                                              'Please log in to like items.'),
                                                        ),
                                                      );
                                                      return;
                                                    }
                                                    _handleLike(optionId);
                                                  } else {
                                                    // Unlike with confirmation
                                                    showModalBottomSheet(
                                                      context: context,
                                                      backgroundColor:
                                                          Colors.grey[900],
                                                      builder: (_) => Container(
                                                        padding:
                                                            const EdgeInsets
                                                                .all(16),
                                                        child: Column(
                                                          mainAxisSize:
                                                              MainAxisSize.min,
                                                          children: [
                                                            const Text(
                                                              'Are you sure you want to remove this from favorites?',
                                                              style: TextStyle(
                                                                color: Colors
                                                                    .white,
                                                                fontSize: 18,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                                height: 20),
                                                            Row(
                                                              mainAxisAlignment:
                                                                  MainAxisAlignment
                                                                      .spaceEvenly,
                                                              children: [
                                                                TextButton(
                                                                  onPressed: () =>
                                                                      Navigator.pop(
                                                                          context),
                                                                  child: Text(
                                                                      'Cancel',
                                                                      style: TextStyle(
                                                                          color:
                                                                              themeColor)),
                                                                ),
                                                                ElevatedButton(
                                                                  style: ElevatedButton
                                                                      .styleFrom(
                                                                    backgroundColor:
                                                                        themeColor,
                                                                    foregroundColor:
                                                                        Colors
                                                                            .white,
                                                                  ),
                                                                  onPressed:
                                                                      () {
                                                                    Navigator.pop(
                                                                        context);
                                                                    _handleUnlike(
                                                                        optionId);
                                                                  },
                                                                  child: const Text(
                                                                      'Confirm'),
                                                                ),
                                                              ],
                                                            ),
                                                          ],
                                                        ),
                                                      ),
                                                    );
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

  Future<void> _handleLike(int optionId) async {
    final user = supabase.auth.currentUser;
    if (user == null) return; // Should not reach here, but safety
    try {
      await supabase.from('option_likes').insert({
        'option_id': optionId,
        'user_id': user.id,
      });
      if (mounted) {
        setState(() {
          _likedOptionIds.add(optionId);
          _likeCounts[optionId] = (_likeCounts[optionId] ?? 0) + 1;
          _favoritedOptionIds.add(optionId.toString());
        });
        widget.userPreferences.favoritedOptions = _favoritedOptionIds.toList();
        await widget.userPreferences.savePreferences();
      }
    } catch (e) {
      debugPrint('Like insert error (ignored if duplicate): $e');
    }
  }

  Future<void> _handleUnlike(int optionId) async {
    final user = supabase.auth.currentUser;
    try {
      if (user != null) {
        await supabase
            .from('option_likes')
            .delete()
            .eq('option_id', optionId)
            .eq('user_id', user.id);
        if (mounted) {
          setState(() {
            _likedOptionIds.remove(optionId);
            final newCount = (_likeCounts[optionId] ?? 1) - 1;
            _likeCounts[optionId] = newCount < 0 ? 0 : newCount;
            _favoritedOptionIds.remove(optionId.toString());
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _favoritedOptionIds.remove(optionId.toString());
          });
        }
      }
      widget.userPreferences.favoritedOptions = _favoritedOptionIds.toList();
      await widget.userPreferences.savePreferences();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unlike failed: $e')),
        );
      }
    }
  }
}
