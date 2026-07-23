// lib/screens/chat/group_invite_screen.dart
import 'dart:async';
import 'dart:convert';

import 'package:allowance/screens/home/story_viewer_screen.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/chat/chat_room_screen.dart';
import 'package:allowance/screens/introduction/introduction_screen.dart';
import 'package:url_launcher/url_launcher.dart';

class GroupInviteScreen extends StatefulWidget {
  final String chatId;
  final UserPreferences userPreferences;

  const GroupInviteScreen({
    super.key,
    required this.chatId,
    required this.userPreferences,
  });

  @override
  State<GroupInviteScreen> createState() => _GroupInviteScreenState();
}

class _GroupInviteScreenState extends State<GroupInviteScreen> {
  final supabase = Supabase.instance.client;
  bool _isLoading = true;
  bool _isJoining = false;
  bool _needsAuth = false;
  String? _error;
  Map<String, dynamic>? _chat;
  bool _alreadyMember = false;
  int _memberCount = 0;

  @override
  void initState() {
    super.initState();
    _loadGroupPreview();
    _recoverPendingGroupPayment();
  }

  Future<void> _recoverPendingGroupPayment() async {
    final prefs = await SharedPreferences.getInstance();
    final pendingJson =
        prefs.getString('pending_group_payment_${widget.chatId}');
    if (pendingJson == null) return;

    setState(() => _isJoining = true);

    try {
      final data = jsonDecode(pendingJson);
      final reference = data['reference'];
      final gateway = data['gateway'] ?? 'paystack';

      // Poll once just to verify if payment was completed while away
      final success =
          await _pollAndVerifyGroupPayment(reference, gateway, maxAttempts: 1);

      if (success) {
        await prefs.remove('pending_group_payment_${widget.chatId}');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('✅ Payment recovered! Joining group...'),
              backgroundColor: Colors.green));
        }
        await _executeJoin(isPaid: true);
      }
    } catch (_) {}

    if (mounted) setState(() => _isJoining = false);
  }

  Future<void> _loadGroupPreview() async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_group_join_id', widget.chatId);
      if (mounted) {
        setState(() {
          _isLoading = false;
          _needsAuth = true;
        });
      }
      return;
    }

    try {
      // 🔥 Using our new V2 RPC that returns everything as a JSON object
      final result = await supabase.rpc('get_group_invite_preview_v2',
          params: {'p_chat_id': widget.chatId});

      if (result == null || result['is_group'] != true) {
        setState(() {
          _isLoading = false;
          _error = 'This invite link is no longer valid.';
        });
        return;
      }

      final alreadyIn = result['is_already_member'] == true;
      final linkEnabled = result['share_link_enabled'] == true;

      if (!linkEnabled && !alreadyIn) {
        setState(() {
          _isLoading = false;
          _error = 'This invite link has been disabled by the group.';
        });
        return;
      }

      setState(() {
        _chat = result; // The entire JSON object maps perfectly
        _memberCount = (result['member_count'] as num?)?.toInt() ?? 0;
        _alreadyMember = alreadyIn;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _error = 'Could not load this invite.';
      });
    }
  }

  Future<void> _openGroupStory() async {
    try {
      final response = await supabase
          .from('stories')
          .select('''
            id, user_id, chat_id, media_url, media_type,
            caption, url, expires_at, created_at, likes_count,
            profiles:user_id(username, avatar_url, school_name, subscription_tier),
            chats:chat_id(group_name, group_avatar, is_public),
            story_views(user_id)
          ''')
          .eq('chat_id', widget.chatId)
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

  @override
  Widget build(BuildContext context) {
    final bool hasStory = _chat?['has_active_story'] == true;
    final bool isPremium = _chat?['is_premium'] == true;
    final List themes =
        List.from((_chat?['themes'] as List?)?.map((e) => e.toString()) ?? []);
    final int mutualFriends = (_chat?['mutual_friends'] as num?)?.toInt() ?? 0;

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Center(
        child: _isLoading
            ? const CircularProgressIndicator(color: Color(0xFF4CAF50))
            : _needsAuth
                ? Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.groups,
                            color: Color(0xFF4CAF50), size: 56),
                        const SizedBox(height: 20),
                        const Text('You were invited to a group',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        const Text('Log in or sign up to see it and join.',
                            textAlign: TextAlign.center,
                            style:
                                TextStyle(color: Colors.white70, fontSize: 14)),
                        const SizedBox(height: 28),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF4CAF50),
                                padding:
                                    const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12))),
                            onPressed: () => _goToLogin(),
                            child: const Text('Continue',
                                style: TextStyle(
                                    color: Colors.black,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16)),
                          ),
                        ),
                      ],
                    ),
                  )
                : _error != null
                    ? Padding(
                        padding: const EdgeInsets.all(32),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.link_off,
                                color: Colors.white38, size: 48),
                            const SizedBox(height: 16),
                            Text(_error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Colors.white70, fontSize: 16)),
                          ],
                        ),
                      )
                    : SingleChildScrollView(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              GestureDetector(
                                onTap: hasStory ? _openGroupStory : null,
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
                                              width: 3)),
                                      child: CircleAvatar(
                                        radius: 48,
                                        backgroundColor: Colors.grey[800],
                                        backgroundImage:
                                            _chat?['group_avatar'] != null
                                                ? NetworkImage(
                                                    _chat!['group_avatar'])
                                                : null,
                                        child: _chat?['group_avatar'] == null
                                            ? const Icon(Icons.groups,
                                                size: 48, color: Colors.white54)
                                            : null,
                                      ),
                                    ),
                                    if (isPremium)
                                      Container(
                                          padding: const EdgeInsets.all(4),
                                          decoration: const BoxDecoration(
                                              color: Colors.black,
                                              shape: BoxShape.circle),
                                          child: const Icon(Icons.verified,
                                              color: Colors.amber, size: 24)),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 20),
                              Text(_chat?['group_name'] ?? 'Group Chat',
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              Text(
                                  '$_memberCount members ${mutualFriends > 0 ? ' • $mutualFriends mutual friends' : ''}',
                                  style: const TextStyle(
                                      color: Colors.white54, fontSize: 14)),

                              // 🔥 FIX: Colorful tags implemented directly!
                              if (themes.isNotEmpty) ...[
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  alignment: WrapAlignment.center,
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
                                    final c = colors[
                                        t.hashCode.abs() % colors.length];
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 6),
                                      decoration: BoxDecoration(
                                          color: c.withOpacity(0.12),
                                          border: Border.all(
                                              color: c.withOpacity(0.3)),
                                          borderRadius:
                                              BorderRadius.circular(8)),
                                      child: Text(t,
                                          style: TextStyle(
                                              color: c,
                                              fontSize: 11,
                                              fontWeight: FontWeight.bold)),
                                    );
                                  }).toList(),
                                )
                              ],

                              if (_chat?['group_description']
                                      ?.toString()
                                      .isNotEmpty ==
                                  true) ...[
                                const SizedBox(height: 16),
                                Text(_chat!['group_description'],
                                    textAlign: TextAlign.center,
                                    style:
                                        const TextStyle(color: Colors.white70)),
                              ],

                              // 🔥 FIX: Mandatory Pricing display for premium groups!
                              if (isPremium && !_alreadyMember) ...[
                                const SizedBox(height: 24),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 16, horizontal: 16),
                                  decoration: BoxDecoration(
                                      color: Colors.black45,
                                      border: Border.all(
                                          color: Colors.amber.withOpacity(0.3),
                                          width: 1.5),
                                      borderRadius: BorderRadius.circular(16)),
                                  child: Column(
                                    children: [
                                      const Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(Icons.workspace_premium,
                                              color: Colors.amber, size: 20),
                                          SizedBox(width: 8),
                                          Text('Premium Access Pass',
                                              style: TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.bold)),
                                        ],
                                      ),
                                      const Divider(
                                          color: Colors.white10, height: 24),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Text('Free Users',
                                              style: TextStyle(
                                                  color: Colors.white54,
                                                  fontSize: 14)),
                                          Text(
                                              '₦${_chat!['price_free']}/${_chat!['duration']}',
                                              style: const TextStyle(
                                                  color: Colors.white,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16)),
                                        ],
                                      ),
                                      const SizedBox(height: 12),
                                      Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.spaceBetween,
                                        children: [
                                          const Row(children: [
                                            Icon(Icons.star,
                                                color: Colors.amber, size: 14),
                                            SizedBox(width: 4),
                                            Text('Plus Users',
                                                style: TextStyle(
                                                    color: Colors.amber,
                                                    fontSize: 14,
                                                    fontWeight:
                                                        FontWeight.bold))
                                          ]),
                                          Text(
                                              '₦${_chat!['price_plus']}/${_chat!['duration']}',
                                              style: const TextStyle(
                                                  color: Colors.amber,
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16)),
                                        ],
                                      )
                                    ],
                                  ),
                                )
                              ],

                              const SizedBox(height: 32),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor:
                                        isPremium && !_alreadyMember
                                            ? Colors.amber
                                            : const Color(0xFF4CAF50),
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 16),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(12)),
                                  ),
                                  onPressed: _isJoining
                                      ? null
                                      : (_alreadyMember
                                          ? () => _openChat()
                                          : _joinGroup),
                                  child: _isJoining
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(
                                              color: Colors.black,
                                              strokeWidth: 2))
                                      : Text(
                                          _alreadyMember
                                              ? 'Open Chat'
                                              : (isPremium
                                                  ? 'Pay to Gain Access'
                                                  : 'Join Group'),
                                          style: const TextStyle(
                                              color: Colors.black,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16)),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
      ),
    );
  }

  Future<void> _joinGroup() async {
    final isPremium = _chat?['is_premium'] == true;
    if (isPremium) {
      await _processPremiumJoin();
    } else {
      await _executeJoin();
    }
  }

  Future<void> _processPremiumJoin() async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null || _chat == null) return;

    final isPlus = widget.userPreferences.subscriptionTier == 'Membership';
    final priceFree =
        double.tryParse(_chat!['price_free']?.toString() ?? '0') ?? 0.0;
    final pricePlus =
        double.tryParse(_chat!['price_plus']?.toString() ?? '0') ?? 0.0;
    final numPrice = isPlus ? pricePlus : priceFree;

    if (numPrice <= 0) {
      await _executeJoin();
      return;
    }

    setState(() => _isJoining = true);

    final reference =
        'group_${widget.chatId}_${myId}_${DateTime.now().millisecondsSinceEpoch}';
    String gateway = 'paystack';
    String? authUrlString;
    final email = supabase.auth.currentUser?.email ?? 'user@allowance.com';

    try {
      final payResp = await supabase.functions.invoke(
        'paystack-init',
        body: {
          'amount': (numPrice * 100).toInt(),
          'email': email,
          'reference': reference,
          'metadata': {
            'chat_id': widget.chatId,
            'user_id': myId,
            'payment_type': 'group_access'
          }
        },
      );
      final data =
          payResp.data is String ? jsonDecode(payResp.data) : payResp.data;
      if (payResp.status == 200 && data != null && data['data'] != null) {
        authUrlString = data['data']['authorization_url'];
      } else {
        throw 'Paystack unavailable';
      }
    } catch (e) {
      gateway = 'flutterwave';
      try {
        final flwResp = await supabase.functions.invoke(
          'flutterwave-init',
          body: {
            'tx_ref': reference,
            'amount': numPrice.toStringAsFixed(0),
            'currency': 'NGN',
            'redirect_url': 'https://allowanceapp.org',
            'customer': {'email': email},
            'meta': {
              'chat_id': widget.chatId,
              'user_id': myId,
              'payment_type': 'group_access'
            },
            'customizations': {
              'title': _chat!['group_name'] ?? 'Premium Group',
              'description': 'Group Access Fee'
            }
          },
        );
        final data =
            flwResp.data is String ? jsonDecode(flwResp.data) : flwResp.data;
        if (flwResp.status == 200 && data != null && data['data'] != null) {
          authUrlString = data['data']['link'];
        } else {
          throw 'Flutterwave unavailable';
        }
      } catch (err) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Payment gateways are currently offline. Try again later.'),
              backgroundColor: Colors.red));
        }
        setState(() => _isJoining = false);
        return;
      }
    }

    if (authUrlString != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_group_payment_${widget.chatId}',
          jsonEncode({'reference': reference, 'gateway': gateway}));

      final Uri url = Uri.parse(authUrlString);
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.inAppBrowserView);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text(
                  'Payment opened. Complete it in the browser — we verify automatically...'),
              duration: Duration(seconds: 8)));
        }
      }
    }

    final success = await _pollAndVerifyGroupPayment(reference, gateway,
        maxAttempts: 30, interval: const Duration(seconds: 4));

    if (success) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('pending_group_payment_${widget.chatId}');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('✅ Payment Verified! Access Granted!'),
            backgroundColor: Colors.green));
      }
      await _executeJoin(isPaid: true);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Payment taking a while. You can close this; we will check again when you return.'),
            backgroundColor: Colors.orange));
      }
    }

    if (mounted) setState(() => _isJoining = false);
  }

  Future<void> _executeJoin({bool isPaid = false}) async {
    final myId = supabase.auth.currentUser?.id;
    if (myId == null || _chat == null) return;

    setState(() => _isJoining = true);
    try {
      await supabase
          .rpc('join_group_via_invite', params: {'p_chat_id': widget.chatId});

      final myUsername = widget.userPreferences.username ?? 'Someone';
      await supabase.from('messages').insert({
        'chat_id': widget.chatId,
        'sender_id': myId,
        'content': '@$myUsername joined via invite link',
        'media_type': 'system',
        'is_read': true,
      });

      if (mounted) _openChat();
    } catch (e) {
      if (mounted) {
        setState(() => _isJoining = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('Failed to join. This link may no longer be active.')));
      }
    }
  }

  Future<bool> _pollAndVerifyGroupPayment(String reference, String gateway,
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

          if (gateway == 'paystack' &&
              data['status'] == true &&
              data['data']?['status'] == 'success') {
            isSuccess = true;
          } else if (gateway == 'flutterwave' &&
              data['status'] == 'success' &&
              data['data']?['status'] == 'successful') {
            isSuccess = true;
          }

          if (isSuccess) return true;
        }
      } catch (e) {
        debugPrint('Verify group transaction error: $e');
      }
      await Future.delayed(interval);
    }
    return false;
  }

  void _openChat() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ChatRoomScreen(
          // 🔥 FIX: Added the `_` context parameter
          chatId: widget.chatId,
          chatTitle: _chat?['group_name'] ?? 'Group',
          isAdmin: false,
          userPreferences: widget.userPreferences,
          isGroup: true,
        ),
      ),
    );
  }

  void _goToLogin() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => IntroductionScreen(
          onFinishIntro: () {},
          userPreferences: widget.userPreferences,
        ),
      ),
    );
  }
}
