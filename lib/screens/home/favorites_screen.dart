// lib/screens/home/favorites_screen.dart
import 'dart:convert';

import 'package:allowance/screens/chat/individual_chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/services/api_service.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

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
  bool _isProcessingSubscription = false;

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
    _recoverPendingSubscription();
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
  // --- 1. DELIVERY PICKER (5-HOUR LOGIC) ---
  Future<void> _showDeliveryPicker(Map<String, dynamic> selectedOption) async {
    final isPlus = widget.userPreferences.subscriptionTier == 'Membership';

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
            shape: const RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
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
                    height: 56,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.pop(ctx);
                        _showUniversalSubscriptionSheet(); // <-- SLIDES UP THE PAYWALL!
                      },
                      style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF4CAF50),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16))),
                      child: const Text("Remove Limit (Upgrade)",
                          style: TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                              fontSize: 16)),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text("I'll wait",
                          style: TextStyle(color: Colors.white54)))
                ],
              ),
            ),
          );
          return;
        }
      }
      await prefs.setString(
          'last_order_time_$myId', DateTime.now().toIso8601String());
    }

    final vendorName =
        selectedOption['vendors']?['name']?.toString() ?? 'Vendor';
    final items = selectedOption['items'] as List<dynamic>;
    final total = items.fold<double>(0, (sum, i) => sum + getAdjustedPrice(i));

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

  // --- 2. UNIVERSAL SUBSCRIPTION POPUP ---
  void _showUniversalSubscriptionSheet({String? customMessage}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
        return Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                  child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 24),
              const Text('Upgrade to Plus ✨',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (customMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                      color: Colors.orangeAccent.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.orangeAccent)),
                  child: Text(customMessage,
                      style: const TextStyle(
                          color: Colors.orangeAccent,
                          fontWeight: FontWeight.bold)),
                )
              else
                const Text(
                    'Unlock the full university cheat code and remove all limits.',
                    style: TextStyle(color: Colors.white70, fontSize: 14)),
              const SizedBox(height: 16),
              _buildPerkRow(Icons.block, 'Ad-free experience across the app'),
              _buildPerkRow(Icons.delivery_dining,
                  'Unlimited food orders (No 5-hour wait)'),
              _buildPerkRow(Icons.photo_library,
                  'Post unlimited Moments (Free max is 3)'),
              _buildPerkRow(Icons.history,
                  'Save & Backup Chats (Free chats delete in 24h)'),
              _buildPerkRow(Icons.group_add, 'Create custom Campus Groups'),
              _buildPerkRow(BoxIcons.bx_food_menu,
                  'Unlimited food orders (No 5-hour wait)'),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isProcessingSubscription
                      ? null
                      : () => _subscribeToMembership(context, setModalState),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF4CAF50),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16))),
                  child: _isProcessingSubscription
                      ? const CircularProgressIndicator(color: Colors.black)
                      : const Text('Subscribe - ₦700/mo',
                          style: TextStyle(
                              color: Colors.black,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        );
      }),
    );
  }

  Widget _buildPerkRow(IconData icon, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF4CAF50), size: 22),
          const SizedBox(width: 12),
          Expanded(
              child: Text(text,
                  style: const TextStyle(color: Colors.white, fontSize: 14))),
        ],
      ),
    );
  }

  // --- 1. RECOVER PENDING SUBSCRIPTION ---
  Future<void> _recoverPendingSubscription() async {
    final prefs = await SharedPreferences.getInstance();
    final pendingJson = prefs.getString('pending_sub_reference');
    if (pendingJson == null) return;

    setState(() => _isProcessingSubscription = true);

    try {
      String reference = '';
      String gateway = 'paystack';
      if (pendingJson.startsWith('{')) {
        final data = jsonDecode(pendingJson);
        reference = data['reference'];
        gateway = data['gateway'] ?? 'paystack';
      } else {
        reference = pendingJson;
      }

      final success =
          await _pollAndProcessVerification(reference, gateway, maxAttempts: 1);

      if (success) {
        await prefs.remove('pending_sub_reference');
        if (mounted) {
          setState(() {
            widget.userPreferences.subscriptionTier = 'Membership';
          });
          await widget.userPreferences.savePreferences();
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('✅ Subscription recovered!'),
              backgroundColor: Colors.green));
        }
      }
    } catch (_) {}

    if (mounted) setState(() => _isProcessingSubscription = false);
  }

  // --- 2. SUBSCRIBE TO MEMBERSHIP (FAILOVER LOGIC) ---
  Future<void> _subscribeToMembership(
      BuildContext context, StateSetter setModalState) async {
    setModalState(() => _isProcessingSubscription = true);
    final user = supabase.auth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please log in.')));
      setModalState(() => _isProcessingSubscription = false);
      return;
    }

    final reference = 'sub_${DateTime.now().millisecondsSinceEpoch}';
    final int amountNaira = 700;
    String gateway = 'paystack';
    String? authUrlString;

    try {
      final funcResp = await supabase.functions.invoke(
        'paystack-init',
        body: {
          'amount': amountNaira * 100,
          'email': user.email ?? 'user@allowance.com',
          'reference': reference,
          'plan': 'PLN_2tgtzyaurt8qz0d',
          'metadata': {'plan_code': 'PLN_2tgtzyaurt8qz0d', 'user_id': user.id}
        },
      );

      final data =
          funcResp.data is String ? jsonDecode(funcResp.data) : funcResp.data;
      if (funcResp.status == 200 && data != null && data['data'] != null) {
        authUrlString = data['data']['authorization_url'];
      } else {
        throw 'Paystack failed: ${funcResp.data}';
      }
    } catch (e) {
      gateway = 'flutterwave';
      try {
        final flwResp = await supabase.functions.invoke(
          'flutterwave-init',
          body: {
            'tx_ref': reference,
            'amount': amountNaira.toString(),
            'currency': 'NGN',
            'redirect_url': 'https://allowanceapp.org',
            'customer': {'email': user.email ?? 'user@allowance.com'},
            'payment_plan': dotenv.env['FLW_PLAN_ID'] ?? '',
            'meta': {'plan_code': 'PLN_2tgtzyaurt8qz0d', 'user_id': user.id},
            'customizations': {
              'title': 'Allowance Plus',
              'description': 'Subscription payment'
            }
          },
        );

        final data =
            flwResp.data is String ? jsonDecode(flwResp.data) : flwResp.data;
        if (flwResp.status == 200 && data != null && data['data'] != null) {
          authUrlString = data['data']['link'];
        } else {
          throw 'Flutterwave failed: ${flwResp.data}';
        }
      } catch (err) {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Gateways offline: $err'),
              backgroundColor: Colors.red));
        setModalState(() => _isProcessingSubscription = false);
        return;
      }
    }

    if (authUrlString != null) {
      final Uri url = Uri.parse(authUrlString);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_sub_reference',
          jsonEncode({'reference': reference, 'gateway': gateway}));

      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.inAppBrowserView);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Payment opened. Complete it in the browser — we verify automatically...'),
            duration: Duration(seconds: 8)));
      } else {
        if (mounted)
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not launch payment page')));
      }
    }

    final success = await _pollAndProcessVerification(reference, gateway,
        maxAttempts: 30, interval: const Duration(seconds: 4));

    if (success) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('pending_sub_reference');
      setState(() => widget.userPreferences.subscriptionTier = 'Membership');
      await widget.userPreferences.savePreferences();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('✅ Subscription activated!'),
            backgroundColor: Colors.green));
        Navigator.pop(context);
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Payment taking a while. You can close this; we will check again when you return.'),
          backgroundColor: Colors.orange));
    }
    if (mounted) setModalState(() => _isProcessingSubscription = false);
  }

  Future<bool> _pollAndProcessVerification(String reference, String gateway,
      {int maxAttempts = 10,
      Duration interval = const Duration(seconds: 3)}) async {
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final funcResp = await Supabase.instance.client.functions.invoke(
          'verify-payment',
          body: {'reference': reference, 'gateway': gateway},
        );

        final data =
            funcResp.data is String ? jsonDecode(funcResp.data) : funcResp.data;
        if (funcResp.status == 200 && data != null) {
          bool isSuccess = false;
          String? customerCode;
          String? subCode;

          if (gateway == 'paystack' &&
              data['status'] == true &&
              data['data']?['status'] == 'success') {
            isSuccess = true;
            customerCode = data['data']['customer']?['customer_code'];
            subCode = data['data']['subscription_code'];
          } else if (gateway == 'flutterwave' &&
              data['status'] == 'success' &&
              data['data']?['status'] == 'successful') {
            isSuccess = true;
            customerCode = 'FLW_NATIVE';
            subCode = 'FLW_SUB';
          }

          if (isSuccess) {
            await _activateSubscriptionDb(customerCode, subCode);
            return true;
          }
        }
      } catch (_) {}
      await Future.delayed(interval);
    }
    return false;
  }

  Future<void> _activateSubscriptionDb(
      String? customerCode, String? subCode) async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      await Supabase.instance.client.from('profiles').update({
        'subscription_tier': 'Membership',
        'paystack_customer_code': customerCode,
        'paystack_subscription_id': subCode,
        'updated_at': DateTime.now().toIso8601String(),
      }).eq('id', user.id);
      widget.userPreferences.subscriptionTier = 'Membership';
      await widget.userPreferences.savePreferences();
    }
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
      backgroundColor: Color(0xFF121212),
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
      backgroundColor: Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: Color(0xFF121212),
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
                            color: sel ? themeColor : Color(0xFF1E1E1E),
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
                        color: Color(0xFF1E1E1E).withOpacity(0.7),
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
                                                          const Color(
                                                              0xFF121212),
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
