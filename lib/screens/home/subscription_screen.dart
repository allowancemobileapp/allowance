import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';
import 'gist_submission_screen.dart';
import 'ticket_submission_screen.dart';

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
  String _currentTier = "Membership";
  late PageController _pageController;

  final List<Map<String, dynamic>> plans = [
    {
      "tier": "Membership",
      "price": "",
      "features": [
        "Remove ads",
        "Diet mode (coming soon)",
      ],
      "cta": "Coming Soon", // 🟢 changed from “N700/Month”
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
    final savedTier = widget.userPreferences.subscriptionTier;
    if (savedTier != null &&
        plans.map((p) => p['tier'].toString()).contains(savedTier)) {
      _currentTier = savedTier;
    }
    _pageController = PageController(viewportFraction: 0.77);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _switchTier(String tier) {
    try {
      setState(() {
        _currentTier = tier;
        widget.userPreferences.subscriptionTier = tier;
        widget.userPreferences.savePreferences();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Switched to $tier plan successfully!")),
      );
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Oops! Something went wrong. Please try again."),
          backgroundColor: Colors.redAccent,
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
    String currentLabel;
    switch (tier) {
      case 'Membership':
        currentLabel = 'Coming Soon'; // 🟢 changed
        break;
      case 'Tickets':
        currentLabel = 'Sell Tickets';
        break;
      case 'Gist Us':
        currentLabel = 'Advertise';
        break;
      default:
        currentLabel = 'Current Plan';
    }

    final buttonText = isCurrent ? currentLabel : cta;
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
                    onPressed: buttonEnabled
                        ? () {
                            if (tier == 'Gist Us') {
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
                                    schoolId: int.tryParse(
                                        widget.userPreferences.schoolId ?? ''),
                                  ),
                                ),
                              );
                            } else {
                              _switchTier(tier);
                            }
                          }
                        : null,
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
                    child: Text(
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
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Text(
                'Current plan: Free',
                style: TextStyle(
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
