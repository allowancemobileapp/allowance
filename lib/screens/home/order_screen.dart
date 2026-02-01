// lib/screens/home/order_screen.dart
// ignore_for_file: use_build_context_synchronously

import 'dart:math';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/foundation.dart' show debugPrint;

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
      backgroundColor: Colors.grey[900],
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
                              color: selected ? themeColor : Colors.grey[800],
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
                                color: Colors.grey[800],
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

  void _showDeliveryPersonnel() async {
    if (_cart.isEmpty) return;

    final schoolId = int.tryParse(widget.userPreferences.schoolId ?? '');
    if (schoolId == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No school selected.')));
      return;
    }

    final personnelRaw = await supabase
        .from('delivery_personnel')
        .select()
        .eq('school_id', schoolId);

    final List<Map<String, dynamic>> personnel =
        List<Map<String, dynamic>>.from(personnelRaw);

    if (personnel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No delivery personnel available.')));
      return;
    }

    personnel.shuffle(Random());

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        minChildSize: 0.4,
        expand: false,
        builder: (_, controller) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Select your guy/gal',
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
                itemCount: personnel.length,
                itemBuilder: (_, i) {
                  final person = personnel[i];
                  return ListTile(
                    title: Text(
                      '${person['name']} (${person['gender']})',
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                    trailing: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: themeColor,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      onPressed: () => _sendOrderToWhatsApp(person),
                      child: const Text('Contact',
                          style: TextStyle(color: Colors.white)),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _sendOrderToWhatsApp(Map<String, dynamic> person) async {
    final vendorName = _selectedVendor?['name'] ?? 'Vendor';

    final orderLines =
        _cart.map((item) => '${item['name']} x ${item['quantity']}').toList();

    orderLines.add('Pack x 1');

    final orderDetails = orderLines.join('\n');

    final totalWithPack = _cartTotal + 200;

    final message =
        'Hello! Custom Order from *$vendorName* on *Allowance*!:\n$orderDetails\n*Total*: ₦${totalWithPack.toStringAsFixed(0)}';

    String phone = (person['whatsapp_url'] ?? person['phone'] ?? '')
        .toString()
        .replaceAll(RegExp(r'[^0-9]'), '');

    if (phone.isEmpty) {
      phone =
          (person['phone'] ?? '').toString().replaceAll(RegExp(r'[^0-9]'), '');
    }

    final encodedMessage = Uri.encodeComponent(message);
    final uri = Uri.parse('https://wa.me/$phone?text=$encodedMessage');

    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      _cart.clear();
      _updateCartTotal();
      if (mounted) Navigator.pop(context);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open WhatsApp.')),
      );
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
                        value: _selectedVendor,
                        dropdownColor: Colors.grey[850],
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          fillColor: Colors.grey[800],
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
                                    color: Colors.grey[800]!.withOpacity(0.7),
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
