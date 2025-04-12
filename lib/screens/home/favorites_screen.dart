// lib/screens/home/favorites_screen.dart
import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';

class FavoritesScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  const FavoritesScreen({super.key, required this.userPreferences});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  final Color themeColor = const Color(0xFF4CAF50);

  // For testing purposes, using static data. Replace with actual data fetching.
  final List<Map<String, dynamic>> _vendorOptions = [
    {
      'id': '1', // Ensure IDs are strings if used as such elsewhere
      'vendor': 'Captain Cook',
      'items': [
        {'name': 'Jollof Rice', 'price': 1000},
        {'name': 'Fried Rice', 'price': 1200},
      ],
      'total_price': 2200, // Consider calculating this dynamically
      'calories': '560 kcal',
      'contact': '09135067590',
    },
    // Add more realistic test data matching potential API structure
    {
      'id': '2',
      'vendor': 'Mama Put',
      'items': [
        {'name': 'Amala & Ewedu', 'price': 1500},
        {'name': 'Beef Stew', 'price': 800},
      ],
      'total_price': 2300,
      'calories': '700 kcal',
      'contact': '08012345678',
    },
  ];

  // Getter to filter options based on user's favorites
  List<Map<String, dynamic>> get _filteredVendorOptions {
    // Ensure favoritedOptions contains IDs matching the format in _vendorOptions (e.g., strings)
    return _vendorOptions.where((vendor) {
      // Removed unused 'items' variable:
      // final List items = vendor['items'];
      final vendorId = vendor['id']; // Get the ID
      return widget.userPreferences.favoritedOptions
          .contains(vendorId); // Check if ID is in favorites
    }).toList();
  }

  // Helper to get items list from vendor data safely
  List getItems(Map<String, dynamic> vendor) {
    return vendor['items'] as List? ??
        []; // Return empty list if null or wrong type
  }

  // Helper to get total price safely
  int getTotalPrice(Map<String, dynamic> vendor) {
    // Option 1: Use pre-defined total_price if available
    // return vendor['total_price'] as int? ?? 0;
    // Option 2: Calculate from items (more robust if 'items' exists)
    final items = getItems(vendor);
    return items.fold(0, (sum, item) => sum + (item['price'] as int? ?? 0));
  }

  @override
  Widget build(BuildContext context) {
    // Use the getter to get filtered options
    final options = _filteredVendorOptions;

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.transparent, // Keep transparent
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "Favorites",
          style: TextStyle(
              fontFamily: 'Montserrat', // Consistent font
              fontSize: 28, // Slightly smaller
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2, // Adjusted spacing
              color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list, size: 24),
            color: Colors.white,
            onPressed: () {
              // TODO: Optionally add filter functionality.
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content: Text("Filter tapped (not implemented)")),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: options.isEmpty
              ? const Center(
                  child: Text(
                    "No favorite options found.\nAdd some from the available options!", // More informative text
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontFamily: 'SanFrancisco',
                        color: Colors.grey,
                        fontSize: 20), // Adjusted size
                  ),
                )
              : ListView.builder(
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final vendor = options[index];
                    final List items = getItems(vendor); // Use safe getter
                    final total =
                        getTotalPrice(vendor); // Use safe getter or calculation
                    final calString = vendor['calories']?.toString() ??
                        "N/A"; // Handle null calories
                    final optionId =
                        vendor['id']?.toString() ?? ''; // Handle null ID

                    return Card(
                      // Use theme's card styling
                      margin: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16)),
                      child: Column(
                        crossAxisAlignment:
                            CrossAxisAlignment.stretch, // Stretch column
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Expanded(
                                      // Allow text to wrap
                                      child: Text(
                                        vendor['vendor']?.toString() ??
                                            'Unknown Vendor', // Handle null vendor name
                                        style: const TextStyle(
                                          fontFamily: 'SanFrancisco',
                                          fontSize: 22,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                    IconButton(
                                      icon: Icon(
                                        widget.userPreferences.favoritedOptions
                                                .contains(optionId)
                                            ? Icons.favorite
                                            : Icons.favorite_border,
                                        color: widget.userPreferences
                                                .favoritedOptions
                                                .contains(optionId)
                                            ? Colors
                                                .redAccent // Slightly different red
                                            : Colors
                                                .white54, // Dimmed border icon
                                        size: 28, // Slightly larger icon
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          if (widget
                                              .userPreferences.favoritedOptions
                                              .contains(optionId)) {
                                            widget.userPreferences
                                                .favoritedOptions
                                                .remove(optionId);
                                          } else {
                                            // Ensure optionId is not empty before adding
                                            if (optionId.isNotEmpty) {
                                              widget.userPreferences
                                                  .favoritedOptions
                                                  .add(optionId);
                                            }
                                          }
                                          // Save preferences after modification
                                          widget.userPreferences
                                              .savePreferences();
                                        });
                                      },
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                if (vendor['contact'] !=
                                    null) // Only show contact if available
                                  Row(
                                    children: [
                                      const Icon(Icons.phone,
                                          color: Colors.blueAccent, size: 18),
                                      const SizedBox(width: 8),
                                      Text(
                                        vendor['contact']?.toString() ?? '',
                                        style: const TextStyle(
                                            fontFamily: 'SanFrancisco',
                                            fontSize: 16, // Slightly smaller
                                            color: Colors.blueAccent),
                                      ),
                                    ],
                                  ),
                                const SizedBox(height: 12),
                                const Divider(
                                    color: Colors.white38, thickness: 1),
                                const SizedBox(height: 12),
                                // Display items only if the list is not empty
                                if (items.isNotEmpty)
                                  Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: items.map((item) {
                                      final itemName =
                                          item['name'] as String? ??
                                              'Unknown Item';
                                      final itemPrice =
                                          item['price'] as int? ?? 0;
                                      return Padding(
                                        padding: const EdgeInsets.only(
                                            bottom: 6), // Increased spacing
                                        child: Text(
                                          '$itemName - ₦$itemPrice',
                                          style: const TextStyle(
                                              fontFamily: 'SanFrancisco',
                                              fontSize: 17, // Slightly larger
                                              color: Colors.white),
                                        ),
                                      );
                                    }).toList(),
                                  )
                                else
                                  const Text(
                                    // Placeholder if no items
                                    "No items listed for this favorite.",
                                    style: TextStyle(
                                        color: Colors.white60,
                                        fontStyle: FontStyle.italic),
                                  ),
                              ],
                            ),
                          ),
                          // Footer section for totals
                          Container(
                            decoration: BoxDecoration(
                              color: themeColor.withOpacity(
                                  0.9), // Use theme color with opacity
                              borderRadius: const BorderRadius.vertical(
                                  bottom: Radius.circular(16)),
                            ),
                            padding: const EdgeInsets.symmetric(
                                vertical: 12,
                                horizontal: 20), // Adjusted padding
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  "Total: ₦$total", // Combined text
                                  style: const TextStyle(
                                    fontFamily: 'SanFrancisco',
                                    fontSize: 18, // Adjusted size
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                                Text(
                                  "Calories: $calString",
                                  style: const TextStyle(
                                    fontFamily: 'SanFrancisco',
                                    fontSize: 18, // Adjusted size
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ),
    );
  }
}
