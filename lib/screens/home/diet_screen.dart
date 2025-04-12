// lib/screens/home/diet_screen.dart
import 'package:flutter/material.dart';

class DietScreen extends StatefulWidget {
  const DietScreen({super.key});
  @override
  State<DietScreen> createState() => _DietScreenState();
}

class _DietScreenState extends State<DietScreen> {
  String? selectedVendors;
  String? selectedDietPlan;
  final TextEditingController _budgetController = TextEditingController();
  final PageController _foodPageController = PageController();
  int _currentFoodIndex = 0;

  final List<Map<String, String>> _foodOptions = [
    {
      'image': 'assets/images/food1.jpg',
      'description': 'Delicious salad with fresh greens.'
    },
    {
      'image': 'assets/images/food2.jpg',
      'description': 'Hearty soup with vegetables and beans.'
    },
    {
      'image': 'assets/images/food3.jpg',
      'description': 'Grilled chicken with steamed veggies.'
    },
  ];

  void _selectVendors() {
    setState(() {
      selectedVendors = "Selected Vendors";
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Vendor selection tapped")),
    );
  }

  void _selectDietPlan() {
    setState(() {
      selectedDietPlan = "Selected Diet Plan";
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Diet plan selection tapped")),
    );
  }

  void _changeFoodOption() {
    int nextPage = (_currentFoodIndex + 1) % _foodOptions.length;
    _foodPageController.animateToPage(
      nextPage,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
    setState(() {
      _currentFoodIndex = nextPage;
    });
  }

  @override
  void dispose() {
    _budgetController.dispose();
    _foodPageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Diet Mode", style: TextStyle(fontFamily: 'SF Pro')),
        backgroundColor: Colors.grey[900],
      ),
      backgroundColor: Colors.grey[900],
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            GestureDetector(
              onTap: _selectVendors,
              child: Container(
                width: double.infinity,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(25),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.store, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      selectedVendors ?? "Select Vendors",
                      style: const TextStyle(
                          fontFamily: 'SF Pro',
                          fontSize: 22,
                          color: Colors.white54),
                    ),
                    const Spacer(),
                    const Icon(Icons.arrow_drop_down, color: Colors.white),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            GestureDetector(
              onTap: _selectDietPlan,
              child: Container(
                width: double.infinity,
                height: 48,
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(25),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.restaurant_menu, color: Colors.white),
                    const SizedBox(width: 8),
                    Text(
                      selectedDietPlan ?? "Select Diet Plan",
                      style: const TextStyle(
                          fontFamily: 'SF Pro',
                          fontSize: 22,
                          color: Colors.white54),
                    ),
                    const Spacer(),
                    const Icon(Icons.arrow_drop_down, color: Colors.white),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              height: 48,
              decoration: BoxDecoration(
                color: Colors.grey[800],
                borderRadius: BorderRadius.circular(25),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const Icon(Icons.attach_money, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _budgetController,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(
                          fontFamily: 'SF Pro',
                          fontSize: 22,
                          color: Colors.white),
                      decoration: const InputDecoration(
                        hintText: "Enter Monthly Budget",
                        hintStyle: TextStyle(
                            fontFamily: 'SF Pro',
                            fontSize: 22,
                            color: Colors.white54),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Column(
                children: [
                  Expanded(
                    child: PageView.builder(
                      controller: _foodPageController,
                      itemCount: _foodOptions.length,
                      itemBuilder: (context, index) {
                        final option = _foodOptions[index];
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              height: 200,
                              width: double.infinity,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(12),
                                image: DecorationImage(
                                  image: AssetImage(option['image']!),
                                  fit: BoxFit.cover,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              option['description']!,
                              style: const TextStyle(
                                  fontFamily: 'SF Pro',
                                  fontSize: 18,
                                  color: Colors.white),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        );
                      },
                      onPageChanged: (index) {
                        setState(() {
                          _currentFoodIndex = index;
                        });
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _changeFoodOption,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(
                          vertical: 16, horizontal: 32),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text(
                      "Change",
                      style: TextStyle(
                          fontFamily: 'SF Pro',
                          fontSize: 16,
                          fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
