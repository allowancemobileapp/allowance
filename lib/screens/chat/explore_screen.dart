// lib/screens/chat/explore_screen.dart
import 'dart:convert';

import 'package:allowance/screens/chat/chat_room_screen.dart';
import 'package:allowance/screens/chat/individual_chat_screen.dart';
import 'package:allowance/screens/home/moment_viewer_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import 'dart:math';
import 'dart:typed_data';
import '../../models/user_preferences.dart';
import '../../widgets/universal_profile_card.dart';
import '../home/story_viewer_screen.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

class ExploreScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  final String?
      initialQuery; // <-- NEW: Accepts a search query from the Universal Menu

  const ExploreScreen(
      {super.key, required this.userPreferences, this.initialQuery});

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  final supabase = Supabase.instance.client;

  List<Map<String, dynamic>> _exploreItems = [];
  final List<Map<String, dynamic>> _masonryBlueprints = [];

  // Cache to prevent regenerating video thumbnails while scrolling
  final Map<String, Uint8List> _videoThumbCache = {};

  bool _isLoading = true;
  String _searchQuery = "";
  int _selectedSegment = 0; // 0 for Discover, 1 for Groups
  bool _isProcessingSubscription = false;

  late TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchQuery = widget.initialQuery ?? "";
    _searchController = TextEditingController(text: _searchQuery);
    _fetchExploreData();
    _recoverPendingSubscription();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchExploreData() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    final currentUserId = supabase.auth.currentUser?.id;
    List<Map<String, dynamic>> mixedResults = [];
    final now = DateTime.now().toUtc().toIso8601String();
    final schoolId = widget.userPreferences.schoolId;

    if (_selectedSegment == 0) {
      // ==========================================
      // DISCOVER FEED
      // ==========================================
      if (_searchQuery.trim().isNotEmpty) {
        final query = _searchQuery.trim();
        var userQuery = supabase
            .from('profiles')
            .select('id, username, avatar_url, school_name, subscription_tier')
            .ilike('username', '%$query%');
        if (currentUserId != null) {
          userQuery = userQuery.neq('id', currentUserId);
        }
        final userRes = await userQuery.limit(50);
        List<Map<String, dynamic>> profiles =
            List<Map<String, dynamic>>.from(userRes);
        final userIds = profiles.map((u) => u['id'].toString()).toList();

        final activeStoriesRes = await supabase
            .from('stories')
            .select('user_id')
            .gt('expires_at', now);
        final Set<String> usersWithStories =
            activeStoriesRes.map((s) => s['user_id'].toString()).toSet();

        profiles = profiles
            .map((e) => {
                  ...e,
                  'explore_type': 'profile',
                  'has_active_story':
                      usersWithStories.contains(e['id'].toString())
                })
            .toList();

        mixedResults.addAll(profiles);

        if (userIds.isNotEmpty) {
          final momentsRes = await supabase
              .from('moments')
              .select('*, profiles:user_id(username, avatar_url, school_name)')
              .inFilter('user_id', userIds)
              .order('created_at', ascending: false)
              .limit(50);
          mixedResults.addAll((momentsRes as List).map((e) =>
              {...Map<String, dynamic>.from(e), 'explore_type': 'moment'}));

          final gistsRes = await supabase
              .from('gists')
              .select('*, profiles:user_id(username, avatar_url)')
              .eq('status', 'active')
              .inFilter('user_id', userIds)
              .limit(50);
          mixedResults.addAll((gistsRes as List).map((e) =>
              {...Map<String, dynamic>.from(e), 'explore_type': 'gist'}));
        } else {
          final momentsRes = await supabase
              .from('moments')
              .select('*, profiles:user_id(username, avatar_url, school_name)')
              .ilike('caption', '%$query%')
              .order('created_at', ascending: false)
              .limit(20);
          mixedResults.addAll((momentsRes as List).map((e) =>
              {...Map<String, dynamic>.from(e), 'explore_type': 'moment'}));

          final gistsRes = await supabase
              .from('gists')
              .select('*, profiles:user_id(username, avatar_url)')
              .eq('status', 'active')
              .ilike('title', '%$query%')
              .limit(20);
          mixedResults.addAll((gistsRes as List).map((e) =>
              {...Map<String, dynamic>.from(e), 'explore_type': 'gist'}));
        }
      } else {
        var userQuery = supabase
            .from('profiles')
            .select('id, username, avatar_url, school_name, subscription_tier');
        if (currentUserId != null) {
          userQuery = userQuery.neq('id', currentUserId);
        }
        final res = await userQuery.limit(1000);
        var allProfiles = List<Map<String, dynamic>>.from(res);
        allProfiles.shuffle(Random());
        var profiles = allProfiles.take(40).toList();

        final activeStoriesRes = await supabase
            .from('stories')
            .select('user_id')
            .gt('expires_at', now);
        final Set<String> usersWithStories =
            activeStoriesRes.map((s) => s['user_id'].toString()).toSet();

        profiles = profiles
            .map((e) => {
                  ...e,
                  'explore_type': 'profile',
                  'has_active_story':
                      usersWithStories.contains(e['id'].toString())
                })
            .toList();

        profiles.sort((a, b) {
          final aTier = a['subscription_tier'] ?? 'Free';
          final bTier = b['subscription_tier'] ?? 'Free';
          if (aTier == 'Membership' && bTier != 'Membership') return -1;
          if (bTier == 'Membership' && aTier != 'Membership') return 1;
          return 0;
        });

        List<Map<String, dynamic>> orders = [];
        var orderQuery = supabase
            .from('options')
            .select('*, vendors!inner(name, school_id)');
        if (schoolId != null && schoolId.isNotEmpty) {
          orderQuery = orderQuery.eq('vendors.school_id', schoolId);
        }
        final orderRes = await orderQuery.limit(100);
        orders = (orderRes as List)
            .map((e) =>
                {...Map<String, dynamic>.from(e), 'explore_type': 'order'})
            .toList();
        if (orders.length > profiles.length ~/ 5) {
          orders = orders.sublist(0, profiles.length ~/ 5);
        }

        mixedResults.addAll(profiles);
        mixedResults.addAll(orders);

        final gistRes = await supabase
            .from('gists')
            .select('*, profiles:user_id(username, avatar_url)')
            .eq('status', 'active')
            .limit(50);
        mixedResults.addAll((gistRes as List).map(
            (e) => {...Map<String, dynamic>.from(e), 'explore_type': 'gist'}));

        final momentRes = await supabase
            .from('moments')
            .select('*, profiles:user_id(username, avatar_url, school_name)')
            .order('created_at', ascending: false)
            .limit(50);
        mixedResults.addAll((momentRes as List).map((e) =>
            {...Map<String, dynamic>.from(e), 'explore_type': 'moment'}));

        final ticketRes = await supabase
            .from('tickets')
            .select('*')
            .eq('status', 'active')
            .gt('date', now.split('T')[0])
            .limit(30);
        mixedResults.addAll((ticketRes as List).map((e) =>
            {...Map<String, dynamic>.from(e), 'explore_type': 'ticket'}));

        mixedResults.shuffle(Random());
      }

      if (mounted) {
        setState(() {
          _exploreItems = mixedResults;
          _generateMasonryBlueprints();
          _isLoading = false;
        });
      }
    } else {
      // ==========================================
      // GROUPS FEED (UPGRADED)
      // ==========================================
      var groupQuery = supabase
          .from('chats')
          .select(
              'id, group_name, group_avatar, group_description, is_public, is_premium, price_free, price_plus, duration, themes, rules, admin_id, created_at, chat_participants(user_id)')
          .eq('is_group', true)
          .or('is_public.eq.true,is_public.is.null'); // 🔥 THIS FIXES IT! BRINGS YOUR GROUPS BACK!

      if (_searchQuery.trim().isNotEmpty) {
        groupQuery = groupQuery.ilike('group_name', '%${_searchQuery.trim()}%');
      }

      try {
        final res = await groupQuery;

        final activeGroupStories = await supabase
            .from('stories')
            .select('chat_id')
            .gt('expires_at', now)
            .not('chat_id', 'is', null);
        final Set<String> groupsWithStories =
            activeGroupStories.map((s) => s['chat_id'].toString()).toSet();

        Set<String> myFollowings = {};
        if (currentUserId != null) {
          final fRes = await supabase
              .from('followers')
              .select('following_id')
              .eq('follower_id', currentUserId);
          myFollowings = fRes.map((f) => f['following_id'].toString()).toSet();
        }

        var groupList = (res as List).map((g) {
          final parts =
              List<Map<String, dynamic>>.from(g['chat_participants'] ?? []);
          int mutuals = 0;
          for (var p in parts) {
            if (myFollowings.contains(p['user_id'].toString())) mutuals++;
          }

          return {
            ...Map<String, dynamic>.from(g),
            'explore_type': 'group',
            'has_active_story': groupsWithStories.contains(g['id'].toString()),
            'mutual_friends': mutuals,
          };
        }).toList();

        // 🔥 EXTRA DART FILTER JUST TO BE SAFE
        groupList = groupList.where((g) => g['is_public'] != false).toList();

        // Sort by active story, then by mutual friends
        groupList.sort((a, b) {
          if (a['has_active_story'] && !b['has_active_story']) return -1;
          if (!a['has_active_story'] && b['has_active_story']) return 1;
          return (b['mutual_friends'] as int)
              .compareTo(a['mutual_friends'] as int);
        });

        if (mounted) {
          setState(() {
            _exploreItems = groupList;
            _isLoading = false;
          });
        }
      } catch (e) {
        debugPrint("Explore Groups Error: $e");
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

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
              bottom: MediaQuery.viewInsetsOf(context).bottom +
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
        Navigator.pop(context); // Close loading
        Navigator.pop(context); // Close bottom sheet
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
                    )));
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to route order.')));
      }
    }
  }

  Future<void> _openStory(String userId) async {
    try {
      final response = await supabase
          .from('stories')
          .select(
              'id, user_id, media_url, media_type, caption, url, expires_at, created_at, likes_count, profiles:user_id(username, avatar_url)')
          .eq('user_id', userId)
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .order('created_at', ascending: false);

      if (response.isNotEmpty && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StoryViewerScreen(
              stories: List<Map<String, dynamic>>.from(response),
              initialIndex: 0,
              userPreferences: widget.userPreferences,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint("Error opening story: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212), // <-- OFFICIAL BG COLOR
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212), // <-- OFFICIAL BG COLOR
        elevation: 0,
        scrolledUnderElevation: 0, // <-- FIX: STOPS COLOR CHANGE ON SCROLL
        surfaceTintColor:
            Colors.transparent, // <-- FIX: STOPS COLOR CHANGE ON SCROLL
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Image.asset(
          'assets/images/explore.png',
          height: 100,
          fit: BoxFit.contain,
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(color: Colors.white),
              textInputAction: TextInputAction.search, // Keyboard search button
              onSubmitted: (value) {
                // <-- FIX: Only search when they press Enter!
                setState(() => _searchQuery = value.trim());
                _fetchExploreData();
              },
              decoration: InputDecoration(
                hintText: _selectedSegment == 0
                    ? 'Search explore...'
                    : 'Search groups...',
                hintStyle: const TextStyle(color: Colors.white54),
                prefixIcon: const Icon(Icons.search, color: Colors.white54),
                filled: true,
                fillColor: const Color(0xFF1E1E1E), // Correct Card Color
                contentPadding: EdgeInsets.zero,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<int>(
                backgroundColor: const Color(0xFF1E1E1E).withOpacity(0.5),
                thumbColor: const Color(0xFF2A2A2A),
                groupValue: _selectedSegment,
                children: {
                  0: _buildSegmentText("Discover", 0),
                  1: _buildSegmentText("Groups", 1),
                },
                onValueChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _selectedSegment = value;
                      _exploreItems = [];
                    });
                    _fetchExploreData();
                  }
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Color(0xFF4CAF50)))
                : _exploreItems.isEmpty
                    ? _buildEmptyState()
                    : RefreshIndicator(
                        onRefresh: _fetchExploreData,
                        color: const Color(0xFF4CAF50),
                        child: _selectedSegment == 0
                            ? _buildCustomMasonryGrid()
                            : _buildGroupListView(),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentText(String text, int index) {
    final isSelected = _selectedSegment == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        text,
        style: TextStyle(
          color: isSelected ? Colors.white : Colors.white38,
          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          fontSize: 14,
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.explore_outlined, size: 60, color: Colors.grey[800]),
          const SizedBox(height: 16),
          Text(
            _selectedSegment == 0 ? "Nothing found" : "No groups found",
            style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
                fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 8),
          const Text("Try searching for something else",
              style: TextStyle(color: Colors.white38, fontSize: 13)),
          const SizedBox(height: 16),
          TextButton.icon(
            onPressed: _fetchExploreData,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text("Refresh"),
            style:
                TextButton.styleFrom(foregroundColor: const Color(0xFF4CAF50)),
          )
        ],
      ),
    );
  }

  // --- SLIVER SCROLL ARCHITECTURE FOR BUTTERY SMOOTH LAYOUT ---

  // --- OUTSIDE THE BOX: Calculate the heavy math ONCE in the background ---
  void _generateMasonryBlueprints() {
    _masonryBlueprints.clear();

    final largeItems = _exploreItems
        .where(
            (e) => e['explore_type'] == 'moment' || e['explore_type'] == 'gist')
        .toList();
    final smallItems = _exploreItems
        .where(
            (e) => e['explore_type'] != 'moment' && e['explore_type'] != 'gist')
        .toList();

    int sIdx = 0;
    int lIdx = 0;

    while (sIdx < smallItems.length || lIdx < largeItems.length) {
      int smallLeft = smallItems.length - sIdx;
      int largeLeft = largeItems.length - lIdx;

      if (largeLeft > 0 && smallLeft >= 2) {
        bool largeOnLeft = (lIdx % 2 == 0);
        if (largeOnLeft) {
          _masonryBlueprints.add({
            'type': 'L_SS',
            'large': largeItems[lIdx++],
            'small1': smallItems[sIdx++],
            'small2': smallItems[sIdx++],
          });
        } else {
          _masonryBlueprints.add({
            'type': 'SS_L',
            'small1': smallItems[sIdx++],
            'small2': smallItems[sIdx++],
            'large': largeItems[lIdx++],
          });
        }
      } else if (smallLeft >= 3) {
        _masonryBlueprints.add({
          'type': 'S_S_S',
          'small1': smallItems[sIdx++],
          'small2': smallItems[sIdx++],
          'small3': smallItems[sIdx++],
        });
      } else if (largeLeft > 0) {
        _masonryBlueprints.add({
          'type': 'L_ONLY',
          'large': largeItems[lIdx++],
        });
      } else if (smallLeft > 0) {
        _masonryBlueprints.add({
          'type': 'REMAINDER',
          'items': [
            smallItems[sIdx++],
            if (smallLeft == 2) smallItems[sIdx++],
          ]
        });
      }
    }
  }

  // --- OUTSIDE THE BOX: Render instantly from blueprints without math ---
  // --- UPDATED: Removes cacheExtent memory leak ---
  Widget _buildCustomMasonryGrid() {
    // 1. Instantly group the data
    final largeItems = _exploreItems
        .where(
            (e) => e['explore_type'] == 'moment' || e['explore_type'] == 'gist')
        .toList();
    final smallItems = _exploreItems
        .where(
            (e) => e['explore_type'] != 'moment' && e['explore_type'] != 'gist')
        .toList();

    List<Map<String, dynamic>> layouts = [];
    int sIdx = 0;
    int lIdx = 0;

    while (sIdx < smallItems.length || lIdx < largeItems.length) {
      int smallLeft = smallItems.length - sIdx;
      int largeLeft = largeItems.length - lIdx;

      if (largeLeft > 0 && smallLeft >= 2) {
        bool largeOnLeft = (lIdx % 2 == 0);
        if (largeOnLeft) {
          layouts.add({
            'type': 'L_SS',
            'large': largeItems[lIdx++],
            'small1': smallItems[sIdx++],
            'small2': smallItems[sIdx++],
          });
        } else {
          layouts.add({
            'type': 'SS_L',
            'small1': smallItems[sIdx++],
            'small2': smallItems[sIdx++],
            'large': largeItems[lIdx++],
          });
        }
      } else if (smallLeft >= 3) {
        layouts.add({
          'type': 'S_S_S',
          'small1': smallItems[sIdx++],
          'small2': smallItems[sIdx++],
          'small3': smallItems[sIdx++],
        });
      } else if (largeLeft > 0) {
        layouts.add({
          'type': 'L_ONLY',
          'large': largeItems[lIdx++],
        });
      } else if (smallLeft > 0) {
        layouts.add({
          'type': 'REMAINDER',
          'items': [
            smallItems[sIdx++],
            if (smallLeft >= 2) smallItems[sIdx++],
          ]
        });
      }
    }

    // 2. Read exact device width directly
    final double screenWidth = MediaQuery.sizeOf(context).width;
    const double spacing = 10.0;
    final double w = (screenWidth - 32 - (spacing * 2)) / 3;
    final double h = w * 1.33;

    // 3. Lazy-load the layouts!
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      physics: const AlwaysScrollableScrollPhysics(),
      // 🔥 FIX: Removed cacheExtent: 2500. Let Flutter manage memory naturally!
      itemCount: layouts.length,
      itemBuilder: (context, index) {
        final row = layouts[index];
        final type = row['type'];

        if (type == 'L_SS') {
          return Padding(
            padding: const EdgeInsets.only(bottom: spacing),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _buildSizedCard(
                  [row['large']], 0, w * 2 + spacing, h * 2 + spacing),
              const SizedBox(width: spacing),
              Column(children: [
                _buildSizedCard([row['small1']], 0, w, h),
                const SizedBox(height: spacing),
                _buildSizedCard([row['small2']], 0, w, h),
              ]),
            ]),
          );
        } else if (type == 'SS_L') {
          return Padding(
            padding: const EdgeInsets.only(bottom: spacing),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Column(children: [
                _buildSizedCard([row['small1']], 0, w, h),
                const SizedBox(height: spacing),
                _buildSizedCard([row['small2']], 0, w, h),
              ]),
              const SizedBox(width: spacing),
              _buildSizedCard(
                  [row['large']], 0, w * 2 + spacing, h * 2 + spacing),
            ]),
          );
        } else if (type == 'S_S_S') {
          return Padding(
            padding: const EdgeInsets.only(bottom: spacing),
            child: Row(children: [
              _buildSizedCard([row['small1']], 0, w, h),
              const SizedBox(width: spacing),
              _buildSizedCard([row['small2']], 0, w, h),
              const SizedBox(width: spacing),
              _buildSizedCard([row['small3']], 0, w, h),
            ]),
          );
        } else if (type == 'L_ONLY') {
          return Padding(
            padding: const EdgeInsets.only(bottom: spacing),
            child: Align(
                alignment: Alignment.centerLeft,
                child: _buildSizedCard(
                    [row['large']], 0, w * 2 + spacing, h * 2 + spacing)),
          );
        } else if (type == 'REMAINDER') {
          final items = row['items'] as List;
          return Padding(
            padding: const EdgeInsets.only(bottom: spacing),
            child: Row(children: [
              _buildSizedCard(items, 0, w, h),
              if (items.length == 2) ...[
                const SizedBox(width: spacing),
                _buildSizedCard(items, 1, w, h),
              ]
            ]),
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  // --- UPDATED: Automatically clears old cache to stop memory leaks ---
  // --- ADD OR REPLACE THIS METHOD INSIDE _ExploreScreenState ---
  Widget _buildMediaThumb(String url, String text, IconData fallbackIcon,
      {bool isVideo = false}) {
    Widget imageWidget;

    // Flush cache if it gets too large to prevent RAM crashes
    if (_videoThumbCache.length > 40) {
      _videoThumbCache.clear();
    }

    if (isVideo && url.isNotEmpty) {
      if (kIsWeb) {
        // 🔥 THE WEB FIX: Use the native video frame previewer instead of video_thumbnail
        imageWidget = _VideoFramePreview(url: url);
      } else if (_videoThumbCache.containsKey(url)) {
        imageWidget = Image.memory(_videoThumbCache[url]!, fit: BoxFit.cover);
      } else {
        imageWidget = FutureBuilder<Uint8List?>(
          future: VideoThumbnail.thumbnailData(
            video: url,
            imageFormat: ImageFormat.JPEG,
            maxWidth: 250, // Save RAM
            quality: 35,
          ),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return Container(color: Colors.grey[850]);
            }
            if (snapshot.hasData && snapshot.data != null) {
              _videoThumbCache[url] = snapshot.data!;
              return Image.memory(snapshot.data!, fit: BoxFit.cover);
            }
            return Icon(Icons.videocam, color: Colors.white24, size: 40);
          },
        );
      }
    } else if (url.isNotEmpty) {
      imageWidget = CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        memCacheWidth: 250, // Compression
        placeholder: (ctx, url) => Container(color: Colors.grey[850]),
        errorWidget: (ctx, url, err) =>
            Icon(fallbackIcon, color: Colors.white24, size: 40),
      );
    } else {
      imageWidget = Icon(fallbackIcon, color: Colors.white24, size: 40);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        imageWidget,
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [Colors.black87, Colors.transparent],
            ),
          ),
        ),
        if (isVideo)
          const Center(
            child:
                Icon(Icons.play_circle_filled, color: Colors.white70, size: 36),
          ),
        Positioned(
          bottom: 12,
          left: 12,
          right: 12,
          child: Text(
            text,
            style: const TextStyle(
                color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  // --- ADD THIS NEW METHOD ---
  Future<void> _openGroupStory(String chatId) async {
    try {
      final response = await supabase
          .from('stories')
          .select('''
            id, user_id, chat_id, media_url, media_type, caption, url, expires_at, created_at, likes_count,
            profiles:user_id(username, avatar_url, school_name, subscription_tier),
            chats:chat_id(group_name, group_avatar, is_public),
            story_views(user_id)
          ''')
          .eq('chat_id', chatId)
          .gt('expires_at', DateTime.now().toUtc().toIso8601String())
          .order('created_at', ascending: true);

      if (response.isNotEmpty && mounted) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => StoryViewerScreen(
              stories: List<Map<String, dynamic>>.from(response),
              initialIndex: 0,
              userPreferences: widget.userPreferences,
            ),
          ),
        );
      }
    } catch (e) {
      debugPrint("Error opening group story: $e");
    }
  }

  // --- REPLACE _buildStandardGrid WITH THIS ---
  Widget _buildGroupListView() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _exploreItems.length,
      // Infinite scroll physics
      physics: const BouncingScrollPhysics(),
      itemBuilder: (context, index) =>
          _buildEnhancedGroupCard(_exploreItems[index]),
    );
  }

  // --- REPLACE _buildGroupCard WITH THIS ---
  Widget _buildEnhancedGroupCard(Map<String, dynamic> group) {
    final String groupId = group['id'].toString();

    final String rawName =
        group.containsKey('group_name') && group['group_name'] != null
            ? group['group_name'].toString()
            : (group.containsKey('name') && group['name'] != null
                ? group['name'].toString()
                : '');
    final String name =
        rawName.trim().isNotEmpty ? rawName.trim() : 'Unnamed Group';

    final String? avatar =
        group.containsKey('group_avatar') && group['group_avatar'] != null
            ? group['group_avatar'].toString()
            : (group.containsKey('avatar_url') && group['avatar_url'] != null
                ? group['avatar_url'].toString()
                : null);

    final String rawDesc = group.containsKey('group_description') &&
            group['group_description'] != null
        ? group['group_description'].toString()
        : (group.containsKey('description') && group['description'] != null
            ? group['description'].toString()
            : '');
    final String desc = rawDesc.trim();

    final bool isPremium = group['is_premium'] == true;
    final bool hasStory = group['has_active_story'] == true;
    final List themes =
        List.from((group['themes'] as List?)?.map((e) => e.toString()) ?? []);
    final int mutualFriends = group['mutual_friends'] ?? 0;
    final String priceFree = group['price_free']?.toString() ?? '0';
    final String pricePlus = group['price_plus']?.toString() ?? '0';
    final String duration = group['duration']?.toString() ?? 'weekly';

    return Container(
      key: ValueKey('group_card_$groupId'),
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withOpacity(0.05)),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(0.4),
                blurRadius: 12,
                offset: const Offset(0, 4)),
          ]),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: hasStory ? () => _openGroupStory(groupId) : null,
                  child: Stack(
                    alignment: Alignment.bottomRight,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(3),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                              color: hasStory
                                  ? const Color(0xFF4CAF50)
                                  : Colors.transparent,
                              width: 2.5),
                        ),
                        child: SizedBox(
                          width: 64,
                          height: 64,
                          child: CircleAvatar(
                            radius: 32,
                            backgroundColor: Colors.grey[800],
                            backgroundImage: avatar != null
                                ? CachedNetworkImageProvider(avatar)
                                : null,
                            child: avatar == null
                                ? const Icon(Icons.groups,
                                    size: 34, color: Colors.white54)
                                : null,
                          ),
                        ),
                      ),
                      if (isPremium)
                        Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                              color: Color(0xFF1E1E1E), shape: BoxShape.circle),
                          child: const Icon(Icons.verified,
                              color: Colors.amber, size: 16),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 6),
                      if (mutualFriends > 0)
                        Row(
                          children: [
                            const Icon(Icons.people,
                                size: 14, color: Colors.white54),
                            const SizedBox(width: 6),
                            Text('$mutualFriends mutual friends',
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 13)),
                          ],
                        )
                      else
                        const Text('Tap to view details',
                            style:
                                TextStyle(color: Colors.white38, fontSize: 13)),
                    ],
                  ),
                ),
              ],
            ),
            if (desc.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(desc,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 14, height: 1.3)),
            ],
            const SizedBox(height: 12),
            GestureDetector(
              onTap: () => _showGroupPreview(group),
              child: const Text('Read rules & preview details...',
                  style: TextStyle(
                      color: Colors.blueAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.bold)),
            ),
            // 🔥 FIX: COLORFUL TAGS
            if (themes.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: themes.map((t) {
                  final colors = [
                    Colors.redAccent,
                    Colors.blueAccent,
                    const Color(0xFF4CAF50),
                    Colors.orange,
                    Colors.purpleAccent,
                    Colors.tealAccent,
                    Colors.pinkAccent,
                    Colors.amber
                  ];
                  final c = colors[t.hashCode.abs() % colors.length];
                  return Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                        color: c.withOpacity(0.12),
                        border: Border.all(color: c.withOpacity(0.3)),
                        borderRadius: BorderRadius.circular(8)),
                    child: Text(t,
                        style: TextStyle(
                            color: c,
                            fontSize: 11,
                            fontWeight: FontWeight.bold)),
                  );
                }).toList(),
              )
            ],
            if (isPremium) ...[
              const SizedBox(height: 18),
              Container(
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                decoration: BoxDecoration(
                    color: Colors.black38,
                    borderRadius: BorderRadius.circular(12)),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Free Pass',
                            style:
                                TextStyle(color: Colors.white54, fontSize: 11)),
                        const SizedBox(height: 2),
                        Text('₦$priceFree/$duration',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                                fontSize: 13)),
                      ],
                    ),
                    Container(width: 1, height: 28, color: Colors.white10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Row(children: [
                          Icon(Icons.star, color: Colors.amber, size: 12),
                          SizedBox(width: 4),
                          Text('Plus Pass',
                              style: TextStyle(
                                  color: Colors.amber,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold))
                        ]),
                        const SizedBox(height: 2),
                        Text('₦$pricePlus/$duration',
                            style: const TextStyle(
                                color: Colors.amber,
                                fontWeight: FontWeight.bold,
                                fontSize: 13)),
                      ],
                    ),
                  ],
                ),
              )
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor:
                        isPremium ? Colors.amber : const Color(0xFF4CAF50),
                    foregroundColor: Colors.black,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                onPressed: () => _showGroupPreview(group),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (isPremium)
                      const Icon(Icons.workspace_premium, size: 18),
                    if (isPremium) const SizedBox(width: 6),
                    Text(isPremium ? 'Gain Premium Access' : 'Join Group',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future _showGroupPreview(Map<String, dynamic> group) async {
    final groupName = group['group_name'] ?? 'Unknown Group';
    final desc = group['group_description'] ?? 'No description provided.';
    final isPublic = group['is_public'] == true;
    final isPremium = group['is_premium'] == true;
    final String priceFree = group['price_free']?.toString() ?? '0';
    final String pricePlus = group['price_plus']?.toString() ?? '0';
    final String duration = group['duration']?.toString() ?? 'weekly';
    final int mutualFriends = group['mutual_friends'] ?? 0;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.4,
        maxChildSize: 0.9,
        expand: false,
        builder: (_, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(24),
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
                        borderRadius: BorderRadius.circular(2))),
              ),
              const SizedBox(height: 24),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 30,
                    backgroundColor: Colors.grey[800],
                    backgroundImage: group['group_avatar'] != null
                        ? CachedNetworkImageProvider(group['group_avatar'])
                        : null,
                    child: group['group_avatar'] == null
                        ? const Icon(Icons.groups, color: Colors.white54)
                        : null,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(groupName,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(isPublic ? Icons.public : Icons.lock,
                                size: 14,
                                color: isPublic
                                    ? Colors.greenAccent
                                    : Colors.orangeAccent),
                            const SizedBox(width: 4),
                            Text(isPublic ? 'Public Group' : 'Private Group',
                                style: TextStyle(
                                    color: isPublic
                                        ? Colors.greenAccent
                                        : Colors.orangeAccent,
                                    fontSize: 13)),
                          ],
                        ),
                        if (mutualFriends > 0) ...[
                          const SizedBox(height: 4),
                          Text('$mutualFriends mutual friends inside',
                              style: const TextStyle(
                                  color: Colors.white54, fontSize: 13)),
                        ]
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Text('About this group',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              if (desc.isNotEmpty) ...[
                Text(desc,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 15, height: 1.5)),
              ],
              Builder(builder: (ctx) {
                final rulesList = List<String>.from(
                    (group['custom_rules'] as List?)
                            ?.map((e) => e.toString()) ??
                        []);
                if (rulesList.isEmpty) return const SizedBox.shrink();

                return Padding(
                  padding: const EdgeInsets.only(top: 16.0),
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white10,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.rule, size: 18),
                    label: const Text('View Group Rules'),
                    onPressed: () {
                      showDialog(
                          context: ctx,
                          builder: (dialogCtx) => AlertDialog(
                                  backgroundColor: const Color(0xFF1E1E1E),
                                  title: const Text('Group Guidelines',
                                      style: TextStyle(color: Colors.white)),
                                  content: SingleChildScrollView(
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: rulesList
                                          .map((rule) => Padding(
                                                padding: const EdgeInsets.only(
                                                    bottom: 8.0),
                                                child: Row(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    const Text('• ',
                                                        style: TextStyle(
                                                            color: Color(
                                                                0xFF4CAF50),
                                                            fontSize: 18,
                                                            fontWeight:
                                                                FontWeight
                                                                    .bold)),
                                                    Expanded(
                                                        child: Text(rule,
                                                            style:
                                                                const TextStyle(
                                                                    color: Colors
                                                                        .white70,
                                                                    fontSize:
                                                                        14,
                                                                    height:
                                                                        1.4))),
                                                  ],
                                                ),
                                              ))
                                          .toList(),
                                    ),
                                  ),
                                  actions: [
                                    TextButton(
                                        onPressed: () =>
                                            Navigator.pop(dialogCtx),
                                        child: const Text('Got it',
                                            style: TextStyle(
                                                color: Color(0xFF4CAF50))))
                                  ]));
                    },
                  ),
                );
              }),
              if (isPremium) ...[
                const SizedBox(height: 32),
                const Text('Access Pass',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: Colors.black45,
                      borderRadius: BorderRadius.circular(16)),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Free Users',
                              style:
                                  TextStyle(color: Colors.white, fontSize: 15)),
                          Text('₦$priceFree / $duration',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                        ],
                      ),
                      const Divider(color: Colors.white10, height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(children: [
                            Icon(Icons.star, color: Colors.amber, size: 16),
                            SizedBox(width: 8),
                            Text('Plus Users',
                                style: TextStyle(
                                    color: Colors.amber,
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold)),
                          ]),
                          Text('₦$pricePlus / $duration',
                              style: const TextStyle(
                                  color: Colors.amber,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16)),
                        ],
                      ),
                    ],
                  ),
                )
              ],
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    _joinAndOpenGroup(group);
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4CAF50),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                  ),
                  child: Text(isPremium ? 'Gain Access' : 'Join Group',
                      style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSizedCard(List items, int index, double width, double height) {
    if (index >= items.length) return SizedBox(width: width, height: height);
    return SizedBox(
      width: width,
      height: height,
      child: RepaintBoundary(child: _buildDiscoverCard(items[index])),
    );
  }

  Widget _buildDiscoverCard(Map<String, dynamic> item) {
    final type = item['explore_type'];
    if (type == 'profile') return _buildUserCard(item);

    Color stripColor = Colors.transparent;
    Widget content = const SizedBox();
    VoidCallback? onTap;

    if (type == 'gist') {
      stripColor = const Color(0xFF4CAF50); // Green
      final imageUrl = item['image_url'] ?? '';
      final title = item['title'] ?? 'Gist';
      final isVideo = item['media_type'] == 'video';
      content =
          _buildMediaThumb(imageUrl, title, Icons.article, isVideo: isVideo);
      onTap = () => Navigator.pushNamed(context, '/gist',
          arguments: {'id': item['id'].toString()});
    } else if (type == 'moment') {
      stripColor = Colors.amber; // Yellow
      final imageUrl = item['media_url'] ?? '';
      final String rawCaption = (item['caption'] ?? '').toString().trim();
      final title = rawCaption.isNotEmpty ? rawCaption : 'Moment';
      final isVideo = item['media_type'] == 'video';
      content = _buildMediaThumb(imageUrl, title, Icons.photo_library,
          isVideo: isVideo);
      onTap = () {
        final allMoments =
            _exploreItems.where((e) => e['explore_type'] == 'moment').toList();
        final initialIndex = allMoments.indexOf(item);
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => MomentViewerScreen(
              // <-- Uses the new global screen
              moments: allMoments,
              initialIndex: initialIndex == -1 ? 0 : initialIndex,
              userPreferences: widget.userPreferences,
            ),
          ),
        );
      };
    } else if (type == 'ticket') {
      stripColor = Colors.purpleAccent; // Purple
      final imageUrl = item['photo_url'] ?? '';
      final title = item['name'] ?? 'Ticket';
      content = _buildMediaThumb(imageUrl, title, Icons.confirmation_number);
      onTap = () => Navigator.pushNamed(context, '/ticket',
          arguments: {'id': item['id'].toString()});
    } else if (type == 'order') {
      stripColor = Colors.transparent; // Transparent
      content = _buildOrderThumb(item);
      onTap = () => _showDeliveryPicker(item);
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.hardEdge,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: content),
            if (stripColor != Colors.transparent)
              Container(height: 4, color: stripColor),
          ],
        ),
      ),
    );
  }

  Widget _buildOrderThumb(Map<String, dynamic> item) {
    final vendor = item['vendors']?['name'] ?? 'Vendor';
    final comboDesc = item['combo_description'] ?? 'Combo Option';
    final items = item['items'] as List<dynamic>? ?? [];
    final total = items.fold<double>(0, (sum, i) => sum + getAdjustedPrice(i));

    return Container(
      padding: const EdgeInsets.all(8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
              color: const Color(0xFF4CAF50),
              borderRadius: BorderRadius.circular(6)),
          child: Row(
            children: [
              const Icon(Icons.receipt_long, color: Colors.black, size: 12),
              const SizedBox(width: 4),
              Expanded(
                  child: Text(vendor,
                      style: const TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                          fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis)),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Text(comboDesc,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.bold),
              maxLines: 3,
              overflow: TextOverflow.ellipsis),
        ),
        const Divider(color: Colors.white24, height: 8),
        Text('₦${total.toStringAsFixed(0)}',
            style: const TextStyle(
                color: Color(0xFF4CAF50),
                fontWeight: FontWeight.bold,
                fontSize: 14)),
      ]),
    );
  }

  Widget _buildUserCard(Map<String, dynamic> user) {
    final isPlus = user['subscription_tier'] == 'Membership';
    final hasStory = user['has_active_story'] == true;

    return GestureDetector(
      // Tapping the card background opens their profile
      onTap: () => UniversalProfileCard.show(
          context, user['id'], widget.userPreferences),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey[900],
          borderRadius: BorderRadius.circular(16),
          border: isPlus
              ? Border.all(color: Colors.amber.withOpacity(0.3), width: 1)
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              // TAPPING THE AVATAR OPENS THEIR STORY!
              onTap: hasStory
                  ? () => _openStory(user['id'])
                  : () => UniversalProfileCard.show(
                      context, user['id'], widget.userPreferences),
              child: Container(
                padding: EdgeInsets.all(hasStory ? 2.5 : 0),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: hasStory
                      ? Border.all(color: const Color(0xFF4CAF50), width: 2)
                      : null,
                ),
                child: CircleAvatar(
                  radius: 26,
                  backgroundColor: Colors.grey[800],
                  backgroundImage: user['avatar_url'] != null
                      ? CachedNetworkImageProvider(user['avatar_url'])
                      : null,
                  child: user['avatar_url'] == null
                      ? Text(user['username'].toString()[0].toUpperCase(),
                          style: const TextStyle(
                              fontSize: 18, color: Colors.white))
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text('${user['username']}',
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12),
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (isPlus)
                    const Padding(
                        padding: EdgeInsets.only(left: 2.0),
                        child: Icon(Icons.star, color: Colors.amber, size: 10)),
                ],
              ),
            ),
            Text(user['school_name'] ?? 'Allowance',
                style: const TextStyle(color: Colors.white54, fontSize: 10),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
    );
  }

  Future<void> _joinAndOpenGroup(Map<String, dynamic> group) async {
    final currentUserId = supabase.auth.currentUser?.id;
    if (currentUserId == null) return;
    try {
      final existingMember = await supabase
          .from('chat_participants')
          .select('chat_id, user_id')
          .eq('chat_id', group['id'])
          .eq('user_id', currentUserId)
          .maybeSingle();

      if (existingMember == null) {
        await supabase
            .from('chat_participants')
            .insert({'chat_id': group['id'], 'user_id': currentUserId});

        // 🔥 FIX: Drop the system message when they join from Explore!
        final myUsername = widget.userPreferences.username ?? 'Someone';
        await supabase.from('messages').insert({
          'chat_id': group['id'],
          'sender_id': currentUserId,
          'content': '@$myUsername joined the group',
          'media_type': 'system',
          'is_read': true,
        });
      }

      if (!mounted) return;
      Navigator.pop(context);
      Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => ChatRoomScreen(
                  chatId: group['id'].toString(),
                  chatTitle: group['group_name'] ?? 'Group Chat',
                  isGroup: true,
                  isAdmin: false,
                  userPreferences: widget.userPreferences)));
    } catch (e) {
      debugPrint("Join/Open group error: $e");
    }
  }
}

// =========================================================================
// TIKTOK-STYLE MOMENT VIEWER FOR EXPLORE SCREEN
// =========================================================================
class ExploreVerticalMomentFeed extends StatefulWidget {
  final List<dynamic> moments;
  final int initialIndex;
  final UserPreferences userPreferences;

  const ExploreVerticalMomentFeed({
    super.key,
    required this.moments,
    required this.initialIndex,
    required this.userPreferences,
  });

  @override
  State<ExploreVerticalMomentFeed> createState() =>
      _ExploreVerticalMomentFeedState();
}

class _ExploreVerticalMomentFeedState extends State<ExploreVerticalMomentFeed> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: PageView.builder(
        controller: _pageController,
        scrollDirection: Axis.vertical,
        allowImplicitScrolling: true,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        itemCount: widget.moments.length,
        itemBuilder: (context, index) {
          return ExploreMomentViewerItem(
            moment: widget.moments[index],
            userPreferences: widget.userPreferences,
            isCurrentPage: index ==
                _currentIndex, // 🔥 FIX: Passed down for Garbage Collection
          );
        },
      ),
    );
  }
}

class ExploreMomentViewerItem extends StatefulWidget {
  final Map<String, dynamic> moment;
  final UserPreferences userPreferences;
  final bool isCurrentPage;

  const ExploreMomentViewerItem({
    super.key,
    required this.moment,
    required this.userPreferences,
    required this.isCurrentPage,
  });

  @override
  State<ExploreMomentViewerItem> createState() =>
      _ExploreMomentViewerItemState();
}

class _ExploreMomentViewerItemState extends State<ExploreMomentViewerItem> {
  VideoPlayerController? _videoController;
  bool _isLiked = false;
  bool _isHighQuality = false;

  @override
  void initState() {
    super.initState();
    if (widget.moment['media_type'] == 'video' && widget.isCurrentPage) {
      _initVideo();
    }
  }

  void _initVideo() {
    _videoController =
        VideoPlayerController.networkUrl(Uri.parse(widget.moment['media_url']))
          ..initialize().then((_) {
            if (mounted && widget.isCurrentPage) {
              setState(() {});
              _videoController!.setLooping(true);
              _videoController!.play();
            }
          });
  }

  // 🔥 THE FIX: DESTROY OFF-SCREEN VIDEOS
  @override
  void didUpdateWidget(ExploreMomentViewerItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isCurrentPage && !oldWidget.isCurrentPage) {
      if (widget.moment['media_type'] == 'video') {
        if (_videoController == null)
          _initVideo();
        else
          _videoController!.play();
      }
    } else if (!widget.isCurrentPage && oldWidget.isCurrentPage) {
      _videoController?.pause();
      _videoController?.dispose();
      _videoController = null;
    }
  }

  @override
  void dispose() {
    _videoController?.dispose();
    super.dispose();
  }

  void _showMomentOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.moment['media_type'] != 'video')
              ListTile(
                leading: const Icon(Icons.hd, color: Colors.blueAccent),
                title: const Text('View Full Quality',
                    style: TextStyle(color: Colors.blueAccent, fontSize: 16)),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() => _isHighQuality = true);
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Loading High Quality...')));
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.moment['media_type'] == 'video';
    final profile = widget.moment['profiles'] ?? {};
    final username = profile['username'] ?? 'User';
    final avatarUrl = profile['avatar_url'];
    final schoolName = profile['school_name'];
    final caption = widget.moment['caption'] ?? '';

    return Stack(
      fit: StackFit.expand,
      children: [
        Center(
          child: isVideo
              ? (_videoController != null &&
                      _videoController!.value.isInitialized
                  ? GestureDetector(
                      onTap: () {
                        _videoController!.value.isPlaying
                            ? _videoController!.pause()
                            : _videoController!.play();
                        setState(() {});
                      },
                      child: AspectRatio(
                          aspectRatio: _videoController!.value.aspectRatio,
                          child: VideoPlayer(_videoController!)),
                    )
                  : const CircularProgressIndicator(color: Color(0xFF4CAF50)))
              : CachedNetworkImage(
                  imageUrl: widget.moment['media_url'],
                  fit: BoxFit.contain,
                  memCacheWidth:
                      _isHighQuality ? null : 600, // 🔥 FIX: RAM Compression
                  placeholder: (context, url) =>
                      const CircularProgressIndicator(color: Color(0xFF4CAF50)),
                ),
        ),
        SafeArea(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios,
                    color: Colors.white,
                    shadows: [Shadow(color: Colors.black, blurRadius: 4)]),
                onPressed: () => Navigator.pop(context),
              ),
              IconButton(
                icon: const Icon(Icons.more_vert,
                    color: Colors.white,
                    shadows: [Shadow(color: Colors.black, blurRadius: 4)]),
                onPressed: _showMomentOptions,
              ),
            ],
          ),
        ),

        // ... Keep the rest of your original Stack UI (Caption & Right Buttons) exactly the same ...
        Positioned(
          bottom: 20,
          left: 16,
          right: 80,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: () => UniversalProfileCard.show(
                    context, widget.moment['user_id'], widget.userPreferences),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('@$username',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            shadows: [
                              Shadow(color: Colors.black87, blurRadius: 4)
                            ])),
                    if (schoolName != null && schoolName.toString().isNotEmpty)
                      Text(schoolName,
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              shadows: [
                                Shadow(color: Colors.black87, blurRadius: 4)
                              ])),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              if (caption.isNotEmpty)
                Text(caption,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        shadows: [
                          Shadow(color: Colors.black87, blurRadius: 4)
                        ])),
            ],
          ),
        ),
        Positioned(
          bottom: 20,
          right: 8,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: () => UniversalProfileCard.show(
                    context, widget.moment['user_id'], widget.userPreferences),
                child: SizedBox(
                  height: 60,
                  width: 50,
                  child: Stack(
                    children: [
                      CircleAvatar(
                        radius: 24,
                        backgroundColor: Colors.grey[800],
                        backgroundImage:
                            avatarUrl != null ? NetworkImage(avatarUrl) : null,
                        child: avatarUrl == null
                            ? const Icon(Icons.person, color: Colors.white)
                            : null,
                      ),
                      Positioned(
                        bottom: 0,
                        left: 15,
                        child: Container(
                          decoration: const BoxDecoration(
                              color: Colors.red, shape: BoxShape.circle),
                          child: const Icon(Icons.add,
                              color: Colors.white, size: 16),
                        ),
                      )
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              GestureDetector(
                onTap: () => setState(() => _isLiked = !_isLiked),
                child: Column(
                  children: [
                    Icon(_isLiked ? Icons.favorite : Icons.favorite_border,
                        color: _isLiked ? Colors.red : Colors.white,
                        size: 36,
                        shadows: const [
                          Shadow(color: Colors.black54, blurRadius: 8)
                        ]),
                    const SizedBox(height: 4),
                    const Text('Like',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 4)
                            ])),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              GestureDetector(
                onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Comments coming soon!'))),
                child: Column(
                  children: const [
                    Icon(CupertinoIcons.chat_bubble,
                        color: Colors.white,
                        size: 34,
                        shadows: [
                          Shadow(color: Colors.black54, blurRadius: 8)
                        ]),
                    SizedBox(height: 4),
                    Text('0',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 4)
                            ])),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              GestureDetector(
                onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Sharing coming soon!'))),
                child: Column(
                  children: const [
                    Text('🚀',
                        style: TextStyle(fontSize: 30, shadows: [
                          Shadow(color: Colors.black54, blurRadius: 8)
                        ])),
                    SizedBox(height: 4),
                    Text('Share',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 4)
                            ])),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// =========================================================================
// WEB NATIVE VIDEO THUMBNAIL EXTRACTOR
// =========================================================================
class _VideoFramePreview extends StatefulWidget {
  final String url;
  const _VideoFramePreview({required this.url});

  @override
  State<_VideoFramePreview> createState() => _VideoFramePreviewState();
}

class _VideoFramePreviewState extends State<_VideoFramePreview> {
  VideoPlayerController? _controller;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) setState(() {});
      }).catchError((_) {
        // Handle dead links silently
      });
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller != null && _controller!.value.isInitialized) {
      return SizedBox(
        width: double.infinity,
        height: double.infinity,
        child: ClipRect(
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _controller!.value.size.width,
              height: _controller!.value.size.height,
              child: IgnorePointer(child: VideoPlayer(_controller!)),
            ),
          ),
        ),
      );
    }

    // Loading State
    return Container(
      width: double.infinity,
      height: double.infinity,
      color: Colors.grey[850],
      child: const Center(
        child: CircularProgressIndicator(color: Color(0xFF4CAF50)),
      ),
    );
  }
}
