// lib/screens/home/order_screen.dart
// ignore_for_file: use_build_context_synchronously

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
  List<Map<String, dynamic>> _vendors = [];
  Map<String, dynamic>? _selectedVendor;
  List<Map<String, dynamic>> _sections = [];
  List<Map<String, dynamic>> _meals = [];
  final List<Map<String, dynamic>> _cart = []; // Made final as per error
  bool _isLoading = true;
  String? _error;
  double _cartTotal = 0.0;

  @override
  void initState() {
    super.initState();
    _fetchVendors();
  }

  Future<void> _fetchVendors() async {
    try {
      // Current code might be failing here if schoolId is not a valid integer string
      final schoolIdStr = widget.userPreferences.schoolId ?? '';
      final schoolIdInt = int.tryParse(schoolIdStr);

      if (schoolIdInt == null) {
        setState(() {
          _error = "Please select a school in your profile first.";
          _isLoading = false;
        });
        return;
      }

      final vendorsRaw = await supabase
          .from('vendors')
          .select()
          .eq('school_id', schoolIdInt); // Ensure it's filtered by school

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
      // Fetch sections (unchanged)
      final sectionsRaw = await supabase
          .from('sections')
          .select()
          .order('name', ascending: true);

      // Fetch vendor_menus flat (just ids + price)
      final vendorMenusRaw = await supabase
          .from('vendor_menus')
          .select('id, meal_id, price')
          .eq('vendor_id', vendorId);

      // Fetch all relevant meals + their sections in one query
      final mealIds =
          vendorMenusRaw.map((vm) => vm['meal_id']).toSet().toList();
      final mealsRaw = await supabase
          .from('meals')
          .select('id, name, section_id, sections(name)')
          .inFilter('id', mealIds);

      // Map meals to a lookup
      final mealMap = {for (var m in mealsRaw) m['id']: m};

      // Build final list
      final mealsList = vendorMenusRaw
          .map((vm) {
            final meal = mealMap[vm['meal_id']];
            if (meal == null) return null;
            return {
              'id': vm['id'],
              'price': vm['price'],
              'meals': {
                'id': meal['id'],
                'name': meal['name'],
                'section_id': meal['section_id'],
                'sections': {'name': meal['sections']['name']},
              }
            };
          })
          .whereType<Map<String, dynamic>>()
          .toList();

      setState(() {
        _sections = List<Map<String, dynamic>>.from(sectionsRaw);
        _meals = mealsList;
        _isLoading = false;
        _error = null;
      });
    } catch (e, st) {
      debugPrint('Error fetching menu: $e\n$st');
      setState(() {
        _error = 'Failed to load menu. Check console.';
        _isLoading = false;
      });
    }
  }

  void _addToCart(Map<String, dynamic> meal, int quantity) {
    final idx =
        _cart.indexWhere((item) => item['meal_id'] == meal['meals']['id']);
    if (idx != -1) {
      _cart[idx]['quantity'] = (_cart[idx]['quantity'] ?? 0) + quantity;
    } else {
      _cart.add({
        'meal_id': meal['meals']['id'],
        'name': meal['meals']['name'] ?? 'Unnamed', // ✅ FIXED to 'meals.name'
        'price': (meal['price'] ?? 0.0) as num,
        'quantity': quantity,
      });
    }
    _updateCartTotal();
  }

  void _updateCartTotal() {
    _cartTotal = _cart.fold(
        0.0, (sum, item) => sum + (item['price'] * item['quantity']));
    setState(() {});
  }

  void _showDeliveryPersonnel() async {
    final schoolId = int.tryParse(widget.userPreferences.schoolId ?? '');
    if (schoolId == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('No school selected.')));
      return;
    }

    final personnel = await supabase
        .from('delivery_personnel')
        .select()
        .eq('school_id', schoolId);

    if (personnel.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No delivery personnel available.')));
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900], // dark sheet background
      builder: (ctx) => ListView.builder(
        itemCount: personnel.length,
        itemBuilder: (ctx, i) {
          final person = personnel[i];
          return ListTile(
            tileColor: Colors.transparent,
            title: Text(person['name'] ?? '',
                style: const TextStyle(color: Colors.white)),
            subtitle: Text(person['gender'] ?? '',
                style: const TextStyle(color: Colors.white70)),
            trailing: IconButton(
              icon: const Icon(Icons.message, color: Colors.white),
              onPressed: () => _sendOrderToWhatsApp(person),
            ),
          );
        },
      ),
    );
  }

  void _sendOrderToWhatsApp(Map<String, dynamic> person) async {
    final orderDetails =
        _cart.map((item) => '${item['name']} x ${item['quantity']}').join('\n');
    final message = 'Hello! Order:\n$orderDetails\nTotal: ₦$_cartTotal';
    final url =
        'https://wa.me/${person['whatsapp_number']}?text=${Uri.encodeComponent(message)}';

    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url));
      _cart.clear();
      _updateCartTotal();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open WhatsApp.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(title: const Text('Order Custom Food')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : Column(
                  children: [
                    DropdownButtonFormField<Map<String, dynamic>>(
                      hint: const Text('Select Vendor',
                          style: TextStyle(color: Colors.white70)),
                      value: _selectedVendor,
                      dropdownColor:
                          Colors.grey[850], // <- dark dropdown background
                      style: const TextStyle(
                          color: Colors.white), // <- items use white text
                      decoration: InputDecoration(
                        fillColor: Colors.grey[800],
                        filled: true,
                        border: const OutlineInputBorder(),
                      ),
                      items: _vendors
                          .map((v) => DropdownMenuItem(
                              value: v,
                              child: Text(v['name'] ?? '',
                                  style: const TextStyle(color: Colors.white))))
                          .toList(),
                      onChanged: (v) {
                        setState(() {
                          _selectedVendor = v;
                          _cart.clear();
                          _updateCartTotal();
                        });
                        if (v != null) {
                          debugPrint('selected vendor id: ${v['id']}');
                          _fetchSectionsAndMeals(v['id']);
                        }
                      },
                    ),
                    if (_selectedVendor != null)
                      Expanded(
                        child: _meals.isEmpty
                            ? Center(
                                child: Text(
                                    'No menu items available for this vendor',
                                    style: TextStyle(color: Colors.white70)))
                            : ListView.builder(
                                itemCount: _cart.length + 1,
                                itemBuilder: (ctx, i) {
                                  if (i == 0) {
                                    return ListTile(
                                      title: const Text('Add Item',
                                          style:
                                              TextStyle(color: Colors.white)),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.add,
                                            color: Colors.white),
                                        onPressed: () => _addItemDialog(),
                                      ),
                                    );
                                  }
                                  final item = _cart[i - 1];
                                  return ListTile(
                                    title: Text(item['name'],
                                        style: const TextStyle(
                                            color: Colors.white)),
                                    subtitle: Text(
                                        'x ${item['quantity']} - ₦${item['price'] * item['quantity']}',
                                        style: const TextStyle(
                                            color: Colors.white70)),
                                    trailing: IconButton(
                                      icon: const Icon(Icons.remove,
                                          color: Colors.white),
                                      onPressed: () {
                                        setState(() => _cart.removeAt(i - 1));
                                        _updateCartTotal();
                                      },
                                    ),
                                  );
                                },
                              ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Total: ₦$_cartTotal',
                          style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Colors.white)),
                    ),
                  ],
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _cart.isNotEmpty ? _showDeliveryPersonnel : null,
        backgroundColor: Colors.green,
        child: const Icon(Icons.shopping_cart_checkout, color: Colors.white),
      ),
    );
  }

  void _addItemDialog() {
    String? selectedSection;
    String? selectedMeal;
    int quantity = 1;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: Colors.grey[800],
          title: const Text('Add Item', style: TextStyle(color: Colors.white)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                dropdownColor: Colors.grey[850],
                hint: const Text('Category',
                    style: TextStyle(color: Colors.white70)),
                value: selectedSection,
                items: _sections
                    .map((s) => DropdownMenuItem<String>(
                        value: s['name'] as String,
                        child: Text(s['name'] as String,
                            style: const TextStyle(color: Colors.white))))
                    .toList(),
                onChanged: (v) {
                  setState(() {
                    selectedSection = v;
                    selectedMeal = null;
                  });
                },
              ),
              if (selectedSection != null)
                DropdownButtonFormField<String>(
                  dropdownColor: Colors.grey[850],
                  hint: const Text('Meal',
                      style: TextStyle(color: Colors.white70)),
                  value: selectedMeal,
                  items: _meals
                      .where((m) =>
                          m['meals']?['sections']?['name'] ==
                          selectedSection) // ✅ FIXED TO m['meals']['sections']['name']
                      .map((m) => DropdownMenuItem<String>(
                          value: m['meals']['name'] as String,
                          child: Text(m['meals']['name'] as String,
                              style: const TextStyle(color: Colors.white))))
                      .toList(),
                  onChanged: (v) => setState(() => selectedMeal = v),
                ),
              if (selectedMeal != null)
                Row(
                  children: [
                    const Text('Quantity:',
                        style: TextStyle(color: Colors.white)),
                    IconButton(
                        onPressed: () => setState(
                            () => quantity = (quantity > 1 ? quantity - 1 : 1)),
                        icon: const Icon(Icons.remove, color: Colors.white)),
                    Text('$quantity',
                        style: const TextStyle(color: Colors.white)),
                    IconButton(
                        onPressed: () => setState(() => quantity++),
                        icon: const Icon(Icons.add, color: Colors.white)),
                  ],
                ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel',
                    style: TextStyle(color: Colors.white))),
            TextButton(
              onPressed: selectedMeal != null
                  ? () {
                      final meal = _meals.firstWhere(
                          (m) => m['meals']['name'] == selectedMeal);
                      _addToCart(meal, quantity);
                      Navigator.pop(ctx);
                    }
                  : null,
              child: const Text('Add', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    );
  }
}
