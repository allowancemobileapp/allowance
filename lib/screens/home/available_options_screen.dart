// lib/screens/home/available_options_screen.dart
import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/services/api_service.dart';

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

  @override
  void initState() {
    super.initState();
    _optionsFuture = ApiService.fetchOptions();
  }

  // Helpers: extract item price and name.
  int getItemPrice(dynamic item) {
    return item["price"];
  }

  String getItemName(dynamic item) {
    return item["name"];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        backgroundColor: Colors.grey[900],
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          "Available Options",
          style: TextStyle(
            fontFamily: 'SanFrancisco',
            fontSize: 24,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
            color: Colors.white,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list, color: Colors.white),
            onPressed: () {
              // Optionally implement a filter popup.
            },
          ),
        ],
      ),
      body: FutureBuilder<List<dynamic>>(
        future: _optionsFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          } else if (snapshot.hasError) {
            return Center(child: Text("Error: ${snapshot.error}"));
          } else if (snapshot.hasData) {
            final List<dynamic> options = snapshot.data!;
            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: options.length,
              itemBuilder: (context, index) {
                final option = options[index];
                final List items = option["items"];
                int total =
                    items.fold(0, (sum, item) => sum + getItemPrice(item));
                String calString =
                    option["total_calories"]?.toString() ?? "0 kcal";

                return TweenAnimationBuilder(
                  tween: Tween<Offset>(
                      begin: const Offset(0, 0.1), end: Offset.zero),
                  duration: const Duration(milliseconds: 500),
                  builder: (context, Offset offset, child) {
                    return Transform.translate(
                      offset: offset,
                      child: child,
                    );
                  },
                  child: Card(
                    color: Colors.grey[800]!.withOpacity(0.7),
                    elevation: 4,
                    margin: const EdgeInsets.symmetric(vertical: 5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    option["combo_description"] ??
                                        option["vendor"] ??
                                        "",
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
                                          color: Colors.white,
                                          size: 26,
                                        ),
                                        onPressed: () {
                                          // Implement delivery logic.
                                        },
                                      ),
                                      IconButton(
                                        icon: Icon(
                                          widget.userPreferences
                                                  .favoritedOptions
                                                  .contains(option["id"])
                                              ? Icons.favorite
                                              : Icons.favorite_border,
                                          color: widget.userPreferences
                                                  .favoritedOptions
                                                  .contains(option["id"])
                                              ? Colors.red
                                              : null,
                                          size: 26,
                                        ),
                                        onPressed: () {
                                          setState(() {
                                            if (widget.userPreferences
                                                .favoritedOptions
                                                .contains(option["id"])) {
                                              widget.userPreferences
                                                  .favoritedOptions
                                                  .remove(option["id"]);
                                            } else {
                                              widget.userPreferences
                                                  .favoritedOptions
                                                  .add(option["id"]);
                                            }
                                            widget.userPreferences
                                                .savePreferences();
                                          });
                                        },
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
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: items.map((item) {
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: Text(
                                      '${getItemName(item)} - ₦${getItemPrice(item)}',
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
                            borderRadius: BorderRadius.zero,
                          ),
                          padding: const EdgeInsets.symmetric(
                              vertical: 8, horizontal: 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Row(
                                children: [
                                  const Text(
                                    "Total: ₦",
                                    style: TextStyle(
                                      fontFamily: 'SanFrancisco',
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                  Text(
                                    "$total",
                                    style: const TextStyle(
                                      fontFamily: 'SanFrancisco',
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                              Text(
                                "Calories: $calString",
                                style: const TextStyle(
                                  fontFamily: 'SanFrancisco',
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          } else {
            return const Center(child: Text("No data available."));
          }
        },
      ),
    );
  }
}
