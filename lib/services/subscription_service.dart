// lib/services/subscription_service.dart
import 'package:flutter/material.dart';

class SubscriptionService {
  /// The specific string identifier for your Plus tier
  static const String plusTier = 'Membership';

  /// Check if a tier string matches the Plus status
  static bool isPlus(String? tier) {
    return tier == plusTier;
  }

  /// Returns the star icon used across the app
  static Widget getPlusBadge({double size = 18}) {
    return Icon(
      Icons.star,
      color: Colors.amber,
      size: size,
    );
  }
}
