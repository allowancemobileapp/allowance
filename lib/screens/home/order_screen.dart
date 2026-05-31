// lib/screens/home/order_screen.dart
// ignore_for_file: use_build_context_synchronously

import 'dart:convert';

import 'package:allowance/screens/chat/individual_chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:allowance/models/user_preferences.dart';

class OrderScreen extends StatefulWidget {
  final UserPreferences userPreferences;

  const OrderScreen({super.key, required this.userPreferences});

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  final supabase = Supabase.instance.client;
  final Color themeColor = const Color(0xFF4CAF50);

  List<Map<String, dynamic>> _vendors = [];
  Map<String, dynamic>? _selectedVendor;
  List<Map<String, dynamic>> _sections = [];
  List<Map<String, dynamic>> _meals = [];
  final List<Map<String, dynamic>> _cart = [];
  bool _isLoading = true;
  String? _error;
  double _cartTotal = 0.0;

  String _selectedSection = 'All';

  @override
  void initState() {
    super.initState();
    _fetchVendors();
  }

  Future<void> _fetchVendors() async {
    try {
      final schoolIdStr = widget.userPreferences.schoolId ?? '';
      final schoolIdInt = int.tryParse(schoolIdStr);

      if (schoolIdInt == null) {
        setState(() {
          _error = "Please select a school in your profile first.";
          _isLoading = false;
        });
        return;
      }

      final vendorsRaw =
          await supabase.from('vendors').select().eq('school_id', schoolIdInt);

      setState(() {
        _vendors = List<Map<String, dynamic>>.from(vendorsRaw);
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load vendors: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _fetchSectionsAndMeals(int vendorId) async {
    setState(() => _isLoading = true);
    try {
      debugPrint('Fetching menu for vendorId=$vendorId');

      // Fetch sections/categories
      final sectionsRaw = await supabase
          .from('sections')
          .select('id, name')
          .order('name', ascending: true);

      final Map<int, String> sectionMap = {};
      for (var s in sectionsRaw) {
        final id = s['id'] as int?;
        final name = s['name'] as String?;
        if (id != null && name != null) {
          sectionMap[id] = name;
        }
      }

      // Fetch vendor_menus flat
      final vendorMenusRaw = await supabase
          .from('vendor_menus')
          .select('id, meal_id, price')
          .eq('vendor_id', vendorId);

      if (vendorMenusRaw.isEmpty) {
        setState(() {
          _sections = List<Map<String, dynamic>>.from(sectionsRaw);
          _meals = [];
          _selectedSection = 'All';
          _isLoading = false;
          _error = null;
        });
        return;
      }

      // Get unique meal_ids
      final Set<int> mealIds = vendorMenusRaw
          .map((vm) => vm['meal_id'] as int?)
          .whereType<int>()
          .toSet();

      // Fetch meals
      final mealsRaw = await supabase
          .from('meals')
          .select('id, name, section_id')
          .inFilter('id', mealIds.toList());

      final Map<int, Map<String, dynamic>> mealMap = {
        for (var m in mealsRaw) m['id'] as int: m
      };

      // Build meals list with attached section name
      final List<Map<String, dynamic>> mealsList = [];
      for (var vm in vendorMenusRaw) {
        final mealId = vm['meal_id'] as int?;
        if (mealId == null) continue;

        final meal = mealMap[mealId];
        if (meal == null) continue;

        final sectionId = meal['section_id'] as int?;
        final sectionName = sectionMap[sectionId] ?? 'Other';

        mealsList.add({
          'id': vm['id'],
          'price': vm['price'],
          'meals': {
            'id': meal['id'],
            'name': meal['name'],
            'sections': {'name': sectionName},
          }
        });
      }

      // Sort alphabetically
      mealsList.sort((a, b) {
        final nameA = a['meals']['name'] ?? '';
        final nameB = b['meals']['name'] ?? '';
        return nameA.compareTo(nameB);
      });

      setState(() {
        _sections = List<Map<String, dynamic>>.from(sectionsRaw);
        _meals = mealsList;
        _selectedSection = 'All';
        _isLoading = false;
        _error = null;
      });
    } catch (e, st) {
      debugPrint('Error fetching menu: $e');
      debugPrint('$st');
      setState(() {
        _error = 'Failed to load menu for this vendor.';
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> get _filteredMeals {
    if (_selectedSection == 'All') return _meals;
    return _meals.where((m) {
      final sectionName = m['meals']?['sections']?['name'];
      return sectionName == _selectedSection;
    }).toList();
  }

  void _addToCart(Map<String, dynamic> meal, int quantity) {
    final mealId = meal['meals']['id'];
    final idx = _cart.indexWhere((item) => item['meal_id'] == mealId);
    if (idx != -1) {
      _cart[idx]['quantity'] += quantity;
    } else {
      _cart.add({
        'meal_id': mealId,
        'name': meal['meals']['name'] ?? 'Unnamed',
        'price': meal['price'] as num,
        'quantity': quantity,
      });
    }
    _updateCartTotal();
  }

  void _removeFromCart(int index) {
    _cart.removeAt(index);
    _updateCartTotal();
  }

  void _updateCartTotal() {
    _cartTotal = _cart.fold(
        0.0, (sum, item) => sum + (item['price'] * item['quantity']));
    setState(() {});
  }

  void _showAddItemSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Color(0xFF121212),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        minChildSize: 0.4,
        expand: false,
        builder: (_, controller) {
          return StatefulBuilder(
            builder: (sheetCtx, setSheetState) {
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Add Item',
                      style: TextStyle(
                        color: themeColor,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 50,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: _sections.length + 1,
                      itemBuilder: (_, i) {
                        final isAll = i == 0;
                        final name = isAll ? 'All' : _sections[i - 1]['name'];
                        final selected = name == _selectedSection;
                        return GestureDetector(
                          onTap: () {
                            setSheetState(() => _selectedSection = name);
                          },
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 20, vertical: 8),
                            decoration: BoxDecoration(
                              color: selected ? themeColor : Color(0xFF1E1E1E),
                              borderRadius: BorderRadius.circular(30),
                            ),
                            alignment: Alignment.center,
                            child: Text(
                              name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: _filteredMeals.isEmpty
                        ? const Center(
                            child: Text(
                              'No items in this category',
                              style: TextStyle(
                                  color: Colors.white70, fontSize: 16),
                            ),
                          )
                        : ListView.builder(
                            controller: controller,
                            padding: const EdgeInsets.all(16),
                            itemCount: _filteredMeals.length,
                            itemBuilder: (_, i) {
                              final meal = _filteredMeals[i];
                              final name = meal['meals']['name'] ?? 'Unnamed';
                              final price = meal['price'] ?? 0;
                              return Card(
                                color: Color(0xFF1E1E1E),
                                margin: const EdgeInsets.symmetric(vertical: 6),
                                child: ListTile(
                                  title: Text(
                                    name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '₦$price',
                                    style:
                                        const TextStyle(color: Colors.white70),
                                  ),
                                  trailing: IconButton(
                                    icon: Icon(Icons.add_circle,
                                        color: themeColor, size: 32),
                                    onPressed: () {
                                      _addToCart(meal, 1);
                                    },
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              );
            },
          );
        },
      ),
    ).then((_) => setState(() {}));
  }

  // --- UPDATED: DELIVERY PICKER ---
  Future<void> _showDeliveryPersonnel() async {
    if (_cart.isEmpty) return;

    final isPlus = widget.userPreferences.subscriptionTier == 'Membership';

    // ENFORCE 5-HOUR LIMIT FOR FREE USERS (Candy Crush style)
    if (!isPlus) {
      final prefs = await SharedPreferences.getInstance();
      final myId = supabase.auth.currentUser?.id;
      final lastOrderStr = prefs.getString('last_order_time_$myId');

      if (lastOrderStr != null) {
        final lastOrder = DateTime.parse(lastOrderStr);
        final diff = DateTime.now().difference(lastOrder);

        if (diff.inHours < 5) {
          final timeLeft = const Duration(hours: 5) - diff;
          final timeString = "${timeLeft.inHours}h ${timeLeft.inMinutes % 60}m";

          showModalBottomSheet(
            context: context,
            backgroundColor: const Color(0xFF1E1E1E),
            isScrollControlled: true,
            builder: (ctx) => Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.timer, color: Colors.orangeAccent, size: 60),
                  const SizedBox(height: 16),
                  const Text("Out of Energy!",
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 24,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  Text(
                      "Free users can order food once every 5 hours.\n\nNext order available in: $timeString",
                      textAlign: TextAlign.center,
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 16)),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(ctx),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4CAF50)),
                      child: const Text("Got it",
                          style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold)),
                    ),
                  )
                ],
              ),
            ),
          );
          return;
        }
      }
      // Save new order time
      await prefs.setString(
          'last_order_time_$myId', DateTime.now().toIso8601String());
    }

    final orderLines = _cart
        .map((item) => {
              'name': item['name'],
              'price': item['price'].toString(),
              'qty': item['quantity'].toString(),
            })
        .toList();

    orderLines.add({'name': 'Pack', 'price': '200', 'qty': '1'});
    final totalWithPack = _cartTotal + 200;

    final orderData = {
      'vendor': _selectedVendor?['name'] ?? 'Vendor',
      'items': orderLines,
      'total': totalWithPack.toStringAsFixed(0)
    };

    _openDeliveryAgentGrid(orderData);
  }

  // --- UPDATED: Fixes overflow & removes "Contact" button ---
  // --- UPDATED: Fixes overflow & removes "Contact" button ---
  void _openDeliveryAgentGrid(Map<String, dynamic> orderData) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Color(0xFF121212),
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
                              backgroundColor: Color(0xFF1E1E1E),
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

  // --- UPDATED: Does NOT auto-send, and clears cart safely! ---
  // --- UPDATED: Removes 'last_message' to prevent database error ---
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

      await supabase.from('messages').insert({
        'chat_id': chatId,
        'sender_id': myId,
        'content': orderJson,
        'media_type': 'order', // Ensure the initial message is an order type
        'is_read': false,
      });

      // FIX: Only update 'updated_at'. The 'last_message' column doesn't exist!
      await supabase.from('chats').update({
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', chatId);

      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        Navigator.pop(context); // Close bottom sheet

        // This is safe because _cart only exists in OrderScreen, not Options/Favorites
        try {
          setState(() {
            _cart.clear();
            _updateCartTotal();
          });
        } catch (_) {}

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: Color(0xFF121212),
        iconTheme: const IconThemeData(color: Colors.white),
        scrolledUnderElevation: 0,
        title: Center(
          child: Image.asset(
            'assets/images/order.png',
            height: 90,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFF4CAF50)))
          : _error != null
              ? Center(
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    textAlign: TextAlign.center,
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: DropdownButtonFormField<Map<String, dynamic>>(
                        hint: const Text('Select Vendor',
                            style: TextStyle(color: Colors.white70)),
                        initialValue: _selectedVendor,
                        dropdownColor: Color(0xFF1E1E1E),
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          fillColor: Color(0xFF1E1E1E),
                          filled: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        items: _vendors
                            .map((v) => DropdownMenuItem(
                                value: v,
                                child: Text(v['name'] ?? '',
                                    style:
                                        const TextStyle(color: Colors.white))))
                            .toList(),
                        onChanged: (v) {
                          setState(() {
                            _selectedVendor = v;
                            _cart.clear();
                            _updateCartTotal();
                          });
                          if (v != null) {
                            _fetchSectionsAndMeals(v['id']);
                          }
                        },
                      ),
                    ),
                    if (_selectedVendor != null) ...[
                      Expanded(
                        child: _meals.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text(
                                      'No menu items available for this vendor',
                                      style: TextStyle(
                                          color: Colors.white70, fontSize: 18),
                                    ),
                                    const SizedBox(height: 16),
                                    ElevatedButton.icon(
                                      icon: const Icon(Icons.add),
                                      label: const Text('Add Item'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: themeColor,
                                      ),
                                      onPressed: _showAddItemSheet,
                                    ),
                                  ],
                                ),
                              )
                            : ListView(
                                padding: const EdgeInsets.all(16),
                                children: [
                                  Card(
                                    color: Color(0xFF1E1E1E).withOpacity(0.7),
                                    elevation: 4,
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 16, vertical: 12),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Text(
                                                _selectedVendor?['name'] ??
                                                    'Vendor',
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 20,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                              ),
                                              IconButton(
                                                icon: const Icon(
                                                  Icons.delivery_dining,
                                                  color: Colors.white,
                                                  size: 30,
                                                ),
                                                onPressed: _cart.isNotEmpty
                                                    ? _showDeliveryPersonnel
                                                    : null,
                                              ),
                                            ],
                                          ),
                                        ),
                                        const Divider(color: Colors.white38),
                                        if (_cart.isEmpty)
                                          const Padding(
                                            padding: EdgeInsets.all(16),
                                            child: Text(
                                              'No items in cart yet',
                                              style: TextStyle(
                                                  color: Colors.white70),
                                            ),
                                          )
                                        else
                                          ..._cart.asMap().entries.map((entry) {
                                            final index = entry.key;
                                            final item = entry.value;
                                            return ListTile(
                                              title: Text(
                                                '${item['name']} x ${item['quantity']}',
                                                style: const TextStyle(
                                                    color: Colors.white),
                                              ),
                                              subtitle: Text(
                                                '₦${(item['price'] * item['quantity']).toStringAsFixed(0)}',
                                                style: const TextStyle(
                                                    color: Colors.white70),
                                              ),
                                              trailing: IconButton(
                                                icon: const Icon(
                                                    Icons.remove_circle,
                                                    color: Colors.red),
                                                onPressed: () {
                                                  _removeFromCart(index);
                                                },
                                              ),
                                            );
                                          }),
                                        ListTile(
                                          leading: const Icon(Icons.add_circle,
                                              color: Colors.white),
                                          title: const Text('Add more items',
                                              style: TextStyle(
                                                  color: Colors.white)),
                                          onTap: _showAddItemSheet,
                                        ),
                                        Container(
                                          width: double.infinity,
                                          color: themeColor,
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 12),
                                          child: Center(
                                            child: Text(
                                              'Total: ₦${(_cartTotal + 200).toStringAsFixed(0)}',
                                              style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ],
                ),
      floatingActionButton: _cart.isNotEmpty
          ? FloatingActionButton(
              backgroundColor: themeColor,
              onPressed: _showDeliveryPersonnel,
              child:
                  const Icon(Icons.shopping_cart_checkout, color: Colors.white),
            )
          : null,
    );
  }
}
