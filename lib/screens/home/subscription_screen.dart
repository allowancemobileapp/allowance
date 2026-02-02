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
      'amount': 70000,
      'email': user.email,
      'reference': reference,
      'plan': 'PLN_2tgtzyaurt8qz0d', // Ensures subscription is created
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

      if (resp.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Payment initialization failed: ${resp.body}')));
        setState(() => _isProcessing = false);
        return;
      }

      final data = jsonDecode(resp.body)['data'];
      final String? authUrlString = data['authorization_url'];

      if (authUrlString != null) {
        final Uri url = Uri.parse(authUrlString);

        // Check if the URL can be handled before attempting to launch.
        // Note: canLaunchUrl returns a Future<bool>.
        final bool isSupported = await canLaunchUrl(url);
        if (isSupported) {
          await launchUrl(url, mode: LaunchMode.externalApplication);
        } else {
          throw 'Could not launch $authUrlString';
        }
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

  /// Prompt user and then poll Paystack for verification.
  Future<void> _promptVerify(String reference) async {
    final verify = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verify Payment'),
        content: const Text(
            'Tap Verify after completing payment. We will then check the transaction.'),
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
      setState(() => _isProcessing = true);
      try {
        final success = await _pollAndProcessVerification(reference);
        if (success) {
          setState(() => _currentTier = membershipTier);
          widget.userPreferences.subscriptionTier = membershipTier;
          await widget.userPreferences.savePreferences();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Subscription activated!'),
                backgroundColor: Colors.green),
          );
          // Navigate home or refresh UI
          if (mounted) {
            Navigator.of(context)
                .pushNamedAndRemoveUntil('/', (route) => false);
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'Payment not verified. Please try again or contact support.'),
                backgroundColor: Colors.red),
          );
        }
      } catch (e) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Verification error: $e')));
      } finally {
        if (mounted) setState(() => _isProcessing = false);
      }
    }
  }

  /// Polls Paystack's verify endpoint until we get success or timeout, then updates Supabase.
  /// Returns true if verification + DB update succeeded, false otherwise.
  Future<bool> _pollAndProcessVerification(String reference,
      {int maxAttempts = 12,
      Duration interval = const Duration(seconds: 5)}) async {
    // Try up to maxAttempts times, waiting `interval` between each attempt.
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        final response = await http.get(
          Uri.parse('https://api.paystack.co/transaction/verify/$reference'),
          headers: {
            'Authorization': 'Bearer ${dotenv.env['PAYSTACK_SECRET_KEY']}'
          },
        );

        if (response.statusCode == 200) {
          final Map<String, dynamic> data = json.decode(response.body);
          final bool ok = data['status'] == true;
          final String? txStatus = data['data']?['status'] as String?;
          if (ok && txStatus == 'success') {
            // Successful payment — now persist to Supabase and local prefs.
            final paystackData = data['data'];
            final customerCode = paystackData['customer']?['customer_code'];
            final subscriptionCode =
                paystackData['subscription_code']; // Might be null

            final user = Supabase.instance.client.auth.currentUser;
            if (user != null) {
              await Supabase.instance.client.from('profiles').update({
                'subscription_tier': membershipTier,
                'paystack_customer_code': customerCode,
                'paystack_subscription_id': subscriptionCode,
                'updated_at': DateTime.now().toIso8601String(),
              }).eq('id', user.id);

              // local prefs update (so UI reflects immediately)
              widget.userPreferences.subscriptionTier = membershipTier;
              await widget.userPreferences.savePreferences();
            }

            return true; // done
          }
          // else not yet successful, continue polling
        } else {
          // non-200: decide whether to continue polling or break.
          debugPrint(
              'Paystack verify returned ${response.statusCode}: ${response.body}');
        }
      } catch (e) {
        debugPrint('Error while verifying transaction: $e');
        // We continue polling; transient network errors can happen.
      }

      // Wait before next attempt (don't block UI).
      await Future.delayed(interval);
    }

    // If we reach here, we timed out without success.
    return false;
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
