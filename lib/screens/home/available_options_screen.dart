// lib/screens/home/available_options_screen.dart
import 'dart:async';
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
  bool _isProcessingSubscription = false;

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
    print(widget.userPreferences.schoolId);
    _foodGroupsFuture = ApiService.fetchFoodGroups();
    _recoverPendingSubscription();
    _optionsFuture =
        ApiService.fetchOptions(widget.userPreferences.schoolId ?? '');
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

  // --- UPDATED: STRICT BUDGET ENFORCEMENT ---
  List<dynamic> _filteredOptions(List<dynamic> options) {
    final budgetStr = widget.userPreferences.budget?.toString() ?? "0";
    final budget = double.tryParse(budgetStr) ?? 0.0;
    final hasValidBudget = budget > 0;

    return options.where((option) {
      final groupId = option["group_id"]?.toString() ?? "";
      final vendorName = option["vendors"]?["name"]?.toString() ?? "";
      if (!widget.selectedRestaurants.contains(vendorName)) return false;

      var selGroup = _groups
          .firstWhere(
            (g) => g["name"] == _selectedGroup,
            orElse: () => {"id": "all"},
          )["id"]
          .toString();

      final items = (option["items"] as List<dynamic>? ?? []);
      if (items.any((i) => _selectedFoodItems.contains(i["name"]))) {
        return false;
      }

      final total =
          items.fold<double>(0, (sum, i) => sum + getAdjustedPrice(i));

      // THE FIX: Only show options that are LESS THAN OR EQUAL TO the budget
      if (hasValidBudget && total > budget) return false;

      return (selGroup == "all" || groupId == selGroup);
    }).toList();
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

    // 🔥 FIX 1: Embed user.id directly into the reference string for Webhook safety
    final reference = 'sub_${user.id}_${DateTime.now().millisecondsSinceEpoch}';
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
          // 🔥 FIX 2: Ensure plan_type is passed so Webhook strictly sets 'Membership'
          'metadata': {
            'plan_code': 'PLN_2tgtzyaurt8qz0d',
            'user_id': user.id,
            'plan_type': 'Membership'
          }
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
            // 🔥 FIX 3: Ensure plan_type is passed here as well
            'meta': {
              'plan_code': 'PLN_2tgtzyaurt8qz0d',
              'user_id': user.id,
              'plan_type': 'Membership'
            },
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Payment taking a while. You can close this; we will check again when you return.'),
            backgroundColor: Colors.orange));
      }
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

  // --- NEW TIMER HELPER ---
  String _getTimeUntil(String? dateStr) {
    if (dateStr == null) return '';
    final date = DateTime.tryParse(dateStr)?.toLocal();
    if (date == null || date.isBefore(DateTime.now())) return '';
    final diff = date.difference(DateTime.now());
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    final hrs = diff.inHours;
    final mins = diff.inMinutes % 60;
    return mins == 0 ? '${hrs}h' : '${hrs}h ${mins}m';
  }

  // --- 1. DELIVERY PICKER (REMOVED 5-HOUR LIMIT) ---
  Future<void> _showDeliveryPicker(Map<String, dynamic> selectedOption) async {
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

  // --- 2. UPDATED DELIVERY AGENT GRID (COOLER PRICING UI) ---
  void _openDeliveryAgentGrid(Map<String, dynamic> orderData) {
    final isPlus = widget.userPreferences.subscriptionTier == 'Membership';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF121212),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => Container(
        constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.85),
        child: FutureBuilder<List<dynamic>>(
          future: Future.wait([
            Supabase.instance.client
                .from('profiles')
                .select(
                    'id, username, avatar_url, gender, is_available_for_delivery, next_available_at')
                .eq('is_delivery_agent', true)
                .eq('school_id', widget.userPreferences.schoolId ?? '')
                .or('is_available_for_delivery.eq.true,next_available_at.gt.${DateTime.now().toUtc().toIso8601String()}'),
            Supabase.instance.client
                .from('app_settings')
                .select('free_delivery_fee, plus_delivery_fee')
                .eq('id', 1)
                .maybeSingle(),
          ]),
          builder: (ctx, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(
                  child: CircularProgressIndicator(color: Color(0xFF4CAF50)));
            }

            final rawList = (snap.data?[0] as List<dynamic>?) ?? [];
            final list = List<dynamic>.from(rawList)..shuffle();
            final settings = (snap.data?[1] as Map<String, dynamic>?) ?? {};

            final freeFee =
                (settings['free_delivery_fee'] as num?)?.toInt() ?? 500;
            final plusFee =
                (settings['plus_delivery_fee'] as num?)?.toInt() ?? 200;
            final currentFee = isPlus ? plusFee : freeFee;

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      const Text('Select a Runner 🏃‍♂️',
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF4CAF50))),
                      // 🔥 FIX 1: THE NEW COOL CENTERED DELIVERY FEE BADGE
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.amber.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: Colors.amber.withOpacity(0.3), width: 1.5),
                        ),
                        child: Text(
                          'Delivery Fee: ₦$currentFee',
                          style: const TextStyle(
                              fontSize: 14,
                              color: Colors.amber,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Colors.white24),
                Expanded(
                  child: list.isEmpty
                      ? const Center(
                          child: Text('No agents available right now 😴',
                              style: TextStyle(color: Colors.white70)))
                      : GridView.builder(
                          padding: const EdgeInsets.all(16),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 16,
                            childAspectRatio: 0.70, // Fits badge and gender
                          ),
                          itemCount: list.length,
                          itemBuilder: (ctx, i) {
                            final person = list[i];
                            final isAvailable =
                                person['is_available_for_delivery'] == true;
                            final timeStr =
                                _getTimeUntil(person['next_available_at']);
                            final isBookable =
                                !isAvailable && timeStr.isNotEmpty;

                            return GestureDetector(
                              onTap: () {
                                // 🔥 BLOCK FREE USERS FROM BOOKING
                                if (isBookable && !isPlus) {
                                  Navigator.pop(context);
                                  _showUniversalSubscriptionSheet(
                                      customMessage:
                                          "Only Allowance Plus ✨ members can book unavailable agents in advance!");
                                  return;
                                }

                                final finalOrderData =
                                    Map<String, dynamic>.from(orderData);
                                finalOrderData['delivery_fee'] = currentFee;
                                final oldTotal = double.tryParse(
                                        finalOrderData['total'].toString()) ??
                                    0.0;
                                finalOrderData['total'] =
                                    (oldTotal + currentFee).toStringAsFixed(0);

                                _sendOrderToAppChat(person, finalOrderData);
                              },
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Stack(
                                    alignment: Alignment.bottomCenter,
                                    clipBehavior: Clip.none,
                                    children: [
                                      CircleAvatar(
                                        radius: 36,
                                        backgroundColor:
                                            const Color(0xFF1E1E1E),
                                        backgroundImage: person['avatar_url'] !=
                                                null
                                            ? NetworkImage(person['avatar_url'])
                                            : null,
                                        child: person['avatar_url'] == null
                                            ? const Icon(Icons.delivery_dining,
                                                color: Colors.white54, size: 30)
                                            : null,
                                      ),
                                      // 🔥 THE YELLOW BOOK BADGE
                                      if (isBookable)
                                        Positioned(
                                          bottom: -8,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Colors.amber,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                              border: Border.all(
                                                  color: Colors.black,
                                                  width: 2),
                                            ),
                                            child: Text('BOOK in $timeStr',
                                                style: const TextStyle(
                                                    color: Colors.black,
                                                    fontSize: 9,
                                                    fontWeight:
                                                        FontWeight.bold)),
                                          ),
                                        ),
                                    ],
                                  ),
                                  SizedBox(height: isBookable ? 14 : 8),
                                  Text(person['username'] ?? 'Agent',
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  // 🔥 SHOW GENDER UNDER NAME
                                  if (person['gender'] != null)
                                    Text(person['gender'],
                                        style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 11)),
                                ],
                              ),
                            );
                          },
                        ),
                ),
                // 🔥 THE FIXED UPGRADE BAR FOR FREE USERS
                if (!isPlus)
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: const BoxDecoration(
                      color: Color(0xFF1E1E1E),
                      borderRadius:
                          BorderRadius.vertical(top: Radius.circular(20)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.star,
                                color: Colors.amber, size: 28),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                'Upgrade to Plus to drop your delivery fee to ₦$plusFee and book unavailable agents!',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF4CAF50),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: () {
                              Navigator.pop(context);
                              _showUniversalSubscriptionSheet();
                            },
                            child: const Text('Upgrade to Plus',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 16)),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  // --- 3. UNIVERSAL SUBSCRIPTION POPUP (OVERFLOW FIXED) ---
  void _showUniversalSubscriptionSheet({String? customMessage}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => StatefulBuilder(
          builder: (BuildContext context, StateSetter setModalState) {
        return SingleChildScrollView(
          // 🔥 FIX 2: Wrapped in SingleChildScrollView to prevent pixel overflow
          child: Padding(
            padding: EdgeInsets.only(
              left: 24.0,
              right: 24.0,
              top: 24.0,
              bottom: MediaQuery.of(context).viewInsets.bottom +
                  24.0, // Safe padding for bottom
            ),
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
                _buildPerkRow(Icons.delivery_dining,
                    'Massively discounted delivery rates'),
                _buildPerkRow(
                    Icons.timer, 'Book unavailable delivery agents in advance'),
                _buildPerkRow(
                    Icons.amp_stories, 'Post Stories that last up to 10 days'),
                _buildPerkRow(Icons.photo_library,
                    'Post unlimited Moments (Free max is 3)'),
                _buildPerkRow(Icons.history,
                    'Save & Backup Chats (Free chats delete in 24h)'),
                _buildPerkRow(Icons.group_add, 'Create custom Campus Groups'),
                _buildPerkRow(Icons.airplane_ticket,
                    'Create & Sell Tickets for events'), // Updated Icon

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
          ),
        );
      }),
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

  void _showFilterPopup() {
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
        builder: (ctx, modalSetState) => SingleChildScrollView(
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
                                checkColor: Color(0xFF121212),
                                value: !_selectedFoodItems.contains(item),
                                onChanged: (v) {
                                  modalSetState(() {
                                    if (v == false) {
                                      _selectedFoodItems.add(item);
                                    } else {
                                      _selectedFoodItems.remove(item);
                                    }
                                  });
                                  setState(
                                      () {}); // Updates the main screen list
                                },
                              ))
                          .toList(),
                    )),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('Close',
                        style: TextStyle(
                            color: themeColor,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
                backgroundColor: Color(0xFF121212),
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
                'Could not load menu: ${snap.error}\nMake sure your school is selected.',
                style: TextStyle(color: Colors.red),
              ),
            );
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
                                color:
                                    selected ? themeColor : Color(0xFF1E1E1E),
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
