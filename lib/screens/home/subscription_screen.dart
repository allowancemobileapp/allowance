// lib/screens/home/subscription_screen.dart
import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart'; // Adjust import based on your project structure

class SubscriptionScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  final Color themeColor; // Grass green color for "N"

  const SubscriptionScreen({
    super.key,
    required this.userPreferences,
    required this.themeColor,
  });

  @override
  State<SubscriptionScreen> createState() => _SubscriptionScreenState();
}

class _SubscriptionScreenState extends State<SubscriptionScreen> {
  String _currentTier = "Free";
  late PageController _pageController;

  // Subscription plans data
  final List<Map<String, dynamic>> plans = [
    {
      "tier": "Free",
      "price": "N0/week",
      "features": [
        "Ads",
        "Limited diet mode access",
        "No diet plans",
      ],
    },
    {
      "tier": "Plus",
      "price": "N100/week",
      "features": [
        "No ads",
        "Full diet mode access",
        "Unlimited diet plan access",
        "Daily food timetable notifications",
      ],
    },
  ];

  @override
  void initState() {
    super.initState();
    _currentTier = widget.userPreferences.subscriptionTier;
    _pageController =
        PageController(viewportFraction: 0.7); // Adjusted for card visibility
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  // Handle tier switching
  void _switchTier(String tier) {
    if (tier == "Free") {
      setState(() {
        _currentTier = "Free";
        widget.userPreferences.subscriptionTier = "Free";
        widget.userPreferences.savePreferences();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Switched to Free tier")),
      );
    } else if (tier == "Plus") {
      // Placeholder for payment logic
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Payment for Plus tier not implemented yet")),
      );
      // TODO: Add payment processing logic here
    }
  }

  // Build individual subscription card
  Widget _buildSubscriptionCard(
      String tier, String price, List<String> features, bool isCurrent) {
    final buttonText = isCurrent
        ? "Current Plan"
        : tier == "Free"
            ? "Downgrade to Free"
            : "Upgrade to $tier";
    final buttonEnabled = !isCurrent;

    return Center(
      // Center the card on the screen
      child: SizedBox(
        width: MediaQuery.of(context).size.width, // Full screen width
        height: 300, // Reduced height
        child: Card(
          color: Colors.grey[800], // Dark card background
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Tier title
                Text(
                  tier,
                  style: const TextStyle(
                    fontFamily: 'SanFrancisco',
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 8),
                // Price with grass green "N" and glow
                RichText(
                  text: TextSpan(
                    children: [
                      TextSpan(
                        text: "N",
                        style: TextStyle(
                          fontFamily: 'SanFrancisco',
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: widget.themeColor, // Grass green
                          shadows: [
                            Shadow(
                              color: widget.themeColor.withOpacity(0.5),
                              blurRadius: 4,
                            ),
                          ],
                        ),
                      ),
                      TextSpan(
                        text: price.substring(1), // Rest of the price
                        style: const TextStyle(
                          fontFamily: 'SanFrancisco',
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Features list
                ...features.map((feature) => Padding(
                      padding: const EdgeInsets.only(bottom: 4.0),
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
                                fontSize: 16, // Smaller font for compact height
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )),
                const Spacer(), // Push button to bottom
                // Action button
                Center(
                  child: ElevatedButton(
                    onPressed: buttonEnabled ? () => _switchTier(tier) : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.themeColor, // Grass green color
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 10),
                      elevation: 8, // Adds elevation for glow effect
                      shadowColor:
                          widget.themeColor.withOpacity(0.7), // Glow shadow
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
      backgroundColor: Colors.grey[900], // Dark mode background
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "Subscriptions",
          style: TextStyle(
            fontFamily: 'SanFrancisco',
            fontSize: 32,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.5,
            color: Colors.white,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications, size: 24),
            color: Colors.white,
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("Notifications clicked!")),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: PageView(
          controller: _pageController,
          children: plans
              .map((plan) => _buildSubscriptionCard(
                    plan["tier"],
                    plan["price"],
                    plan["features"],
                    _currentTier == plan["tier"],
                  ))
              .toList(),
        ),
      ),
    );
  }
}
