import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';
import 'gist_submission_screen.dart';
import 'ticket_submission_screen.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const String membershipTier = "Membership"; // Constant for tier name

class SubscriptionScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  final Color themeColor;

  const SubscriptionScreen({
    super.key,
    required this.userPreferences,
    required this.themeColor,
  });

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  String _currentTier = "";
  late PageController _pageController;
  bool _isProcessing = false;

  final List<Map<String, dynamic>> plans = [
    {
      "tier": membershipTier,
      "price": "N700/Month",
      "features": [
        "Order custom chow",
        "Enjoy the ad free life",
      ],
      "cta": "N700/month",
      "imageHeight": 110.0,
      "buttonColor": Colors.orange,
    },
    {
      "tier": "Tickets",
      "price": "",
      "features": [
        "Sell tickets on allowance",
        "Tap into our audience",
        "We take N100/ticket sale",
      ],
      "cta": "Sell Tickets",
      "imageHeight": 80.0,
      "buttonColor": Colors.purple,
    },
    {
      "tier": "Gist Us",
      "price": "",
      "features": [
        "Tell us your latest gist on campus",
        "Reach your desired target audience",
      ],
      "cta": "Advertise",
      "imageHeight": 70.0,
      "buttonColor": Colors.teal,
    },
  ];

  @override
  void initState() {
    super.initState();
    _currentTier = widget.userPreferences.subscriptionTier ?? "Free";
    _pageController = PageController(viewportFraction: 0.77);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _subscribeToMembership() async {
    setState(() => _isProcessing = true);
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Please log in.')));
      setState(() => _isProcessing = false);
      return;
    }

    String? customerCode;
    try {
      final profile = await supabase
          .from('profiles')
          .select('paystack_customer_code')
          .eq('id', user.id)
          .maybeSingle();
      customerCode = profile?['paystack_customer_code'] as String?;
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Error fetching profile: $e')));
      setState(() => _isProcessing = false);
      return;
    }

    if (customerCode == null) {
      try {
        final resp = await http.post(
          Uri.parse('https://api.paystack.co/customer'),
          headers: {
            'Authorization': 'Bearer ${dotenv.env['PAYSTACK_SECRET_KEY']}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode(
              {'email': user.email, 'first_name': '', 'last_name': ''}),
        );
        if (resp.statusCode == 200 || resp.statusCode == 201) {
          final data = jsonDecode(resp.body)['data'];
          customerCode = data['customer_code'];
          await supabase.from('profiles').update(
              {'paystack_customer_code': customerCode}).eq('id', user.id);
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text('Failed to create customer: ${resp.body}')));
          setState(() => _isProcessing = false);
          return;
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error creating customer: $e')));
        setState(() => _isProcessing = false);
        return;
      }
    }

    final reference = 'sub_${DateTime.now().millisecondsSinceEpoch}';
    final payload = {
      'amount': 70000, // 700 NGN in kobo
      'email': user.email,
      'reference': reference,
      'metadata': {'plan_code': 'PLN_2tgtzyaurt8qz0d', 'user_id': user.id}
    };

    try {
      final resp = await http.post(
        Uri.parse('https://api.paystack.co/transaction/initialize'),
        headers: {
          'Authorization': 'Bearer ${dotenv.env['PAYSTACK_SECRET_KEY']}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(payload),
      );
      print('Init response: ${resp.body}'); // Log
      if (resp.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Payment initialization failed: ${resp.body}')));
        setState(() => _isProcessing = false);
        return;
      }
      final data = jsonDecode(resp.body)['data'];
      final authUrl = data['authorization_url'];
      if (await canLaunch(authUrl)) {
        await launch(authUrl);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not launch payment page.')));
      }
      // After launch, prompt verify
      await _promptVerify(reference);
    } catch (e) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Payment error: $e')));
    } finally {
      setState(() => _isProcessing = false);
    }
  }

  Future<void> _promptVerify(String reference) async {
    final verify = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verify Payment'),
        content: const Text('Tap Verify after completing payment.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Verify')),
        ],
      ),
    );
    if (verify == true) {
      final success = await _verifyPayment(reference);
      if (success) {
        setState(() => _currentTier = membershipTier);
        widget.userPreferences.subscriptionTier = membershipTier;
        await widget.userPreferences.savePreferences();
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Subscription activated!')));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Payment not verified. Please try again or contact support.')));
      }
    }
  }

  Future<bool> _verifyPayment(String reference) async {
    try {
      final resp = await http.get(
        Uri.parse('https://api.paystack.co/transaction/verify/$reference'),
        headers: {
          'Authorization': 'Bearer ${dotenv.env['PAYSTACK_SECRET_KEY']}'
        },
      );
      print('Verify response: ${resp.body}'); // Log
      if (resp.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Verify failed with code ${resp.statusCode}: ${resp.body}')));
        return false;
      }
      final body = jsonDecode(resp.body);
      if (!body['status']) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Verify status false: ${body['message']}')));
        return false;
      }
      final data = body['data'];
      if (data['status'] != 'success') {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Transaction not success: ${data['status']}')));
        return false;
      }

      final supabase = Supabase.instance.client;
      final user = supabase.auth.currentUser!;
      final metadata = data['metadata'];
      final planCode = metadata['plan_code'];

      final authCode = data['authorization']['authorization_code'];
      if (authCode == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('No authorization code - use recurring card.')));
        print('No auth code in transaction.');
        return false;
      }

      final subResp = await http.post(
        Uri.parse('https://api.paystack.co/subscription'),
        headers: {
          'Authorization': 'Bearer ${dotenv.env['PAYSTACK_SECRET_KEY']}',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'customer': data['customer']['customer_code'],
          'plan': planCode,
          'authorization': authCode,
        }),
      );
      print('Subscription response: ${subResp.body}'); // Log
      if (subResp.statusCode != 201) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
                'Sub create failed with code ${subResp.statusCode}: ${subResp.body}')));
        return false;
      }

      // Store sub id in profiles
      final subData = jsonDecode(subResp.body)['data'];
      await supabase.from('profiles').update({
        'paystack_subscription_id': subData['subscription_code'],
        'subscription_tier': membershipTier,
      }).eq('id', user.id);

      return true;
    } catch (e) {
      print('Verification error: $e'); // Log
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Verification failed: $e')));
      return false;
    }
  }

  void _handleTier(String tier) {
    if (tier == membershipTier) {
      _subscribeToMembership();
    } else if (tier == 'Gist Us') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GistSubmissionScreen(
            themeColor: widget.themeColor,
            schoolId: widget.userPreferences.schoolId,
          ),
        ),
      );
    } else if (tier == 'Tickets') {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TicketSubmissionScreen(
            themeColor: widget.themeColor,
            schoolId: int.tryParse(widget.userPreferences.schoolId ?? ''),
          ),
        ),
      );
    }
  }

  Widget _buildSubscriptionCard(
    String tier,
    String price,
    List<String> features,
    String cta,
    bool isCurrent,
    double imageHeight,
    Color buttonColor,
  ) {
    final buttonText = isCurrent ? 'Current Plan' : cta;
    final buttonEnabled = !isCurrent;

    return Center(
      child: SizedBox(
        width: MediaQuery.of(context).size.width,
        height: 330,
        child: Card(
          color: Colors.grey[800],
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tier,
                  style: const TextStyle(
                    fontFamily: 'SanFrancisco',
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: features.map((feature) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6.0),
                      child: Row(
                        children: [
                          const Icon(Icons.check,
                              color: Colors.white, size: 16),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              feature,
                              style: const TextStyle(
                                fontFamily: 'SanFrancisco',
                                fontSize: 16,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: buttonEnabled ? () => _handleTier(tier) : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: buttonColor,
                      disabledBackgroundColor: buttonColor.withOpacity(0.5),
                      disabledForegroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 10),
                      elevation: 8,
                      shadowColor: buttonColor.withOpacity(0.7),
                    ),
                    child: _isProcessing && tier == membershipTier
                        ? const CircularProgressIndicator(color: Colors.white)
                        : Text(
                            buttonText,
                            style: const TextStyle(
                              fontFamily: 'SanFrancisco',
                              fontSize: 16,
                              color: Colors.white,
                            ),
                          ),
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
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        iconTheme: const IconThemeData(color: Colors.white),
        scrolledUnderElevation: 0,
        title: Center(
          child: Image.asset(
            'assets/images/subscriptions.png',
            fit: BoxFit.contain,
            height: 190,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Text(
                'Current plan: ${_currentTier == membershipTier ? "Plus" : "Free"}',
                style: const TextStyle(
                  fontFamily: 'SanFrancisco',
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  color: Colors.white,
                ),
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                children: plans
                    .map((plan) => _buildSubscriptionCard(
                          plan['tier'],
                          plan['price'],
                          List<String>.from(plan['features']),
                          plan['cta'],
                          _currentTier == plan['tier'],
                          plan['imageHeight'].toDouble(),
                          plan['buttonColor'],
                        ))
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
