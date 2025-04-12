import 'package:flutter/material.dart';
import 'package:allowance/models/user_preferences.dart';

class ProfileScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  final VoidCallback onSave; // Callback to notify HomeScreen

  const ProfileScreen({
    super.key,
    required this.userPreferences,
    required this.onSave,
  });

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _weightController = TextEditingController();
  final TextEditingController _heightController = TextEditingController();
  final TextEditingController _ageController = TextEditingController();

  String? _bloodGroup;
  final List<String> bloodGroups = [
    "A+",
    "A-",
    "B+",
    "B-",
    "AB+",
    "AB-",
    "O+",
    "O-",
  ];

  @override
  void initState() {
    super.initState();
    _usernameController.text = widget.userPreferences.username ?? "";
    _phoneController.text = widget.userPreferences.phoneNumber ?? "";
    _weightController.text = widget.userPreferences.weight?.toString() ?? "";
    _heightController.text = widget.userPreferences.height?.toString() ?? "";
    _ageController.text = widget.userPreferences.age?.toString() ?? "";
    _bloodGroup = widget.userPreferences.bloodGroup;
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _phoneController.dispose();
    _weightController.dispose();
    _heightController.dispose();
    _ageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        centerTitle: true,
        title: const Text(
          "My Profile",
          style: TextStyle(
            fontFamily: 'SF Pro',
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        elevation: 4,
      ),
      body: Stack(
        children: [
          // Centered input fields with updated styling
          Center(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: ListView(
                shrinkWrap: true,
                children: [
                  _buildInputField(
                    controller: _usernameController,
                    label: "Username",
                    hint: "Enter your username",
                  ),
                  const SizedBox(height: 16),
                  _buildInputField(
                    controller: _phoneController,
                    label: "Phone Number",
                    hint: "Enter your phone number",
                    keyboardType: TextInputType.phone,
                  ),
                  const SizedBox(height: 16),
                  _buildInputField(
                    controller: _weightController,
                    label: "Weight (kg)",
                    hint: "Enter your weight",
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 16),
                  _buildInputField(
                    controller: _heightController,
                    label: "Height (cm)",
                    hint: "Enter your height",
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 16),
                  _buildInputField(
                    controller: _ageController,
                    label: "Age",
                    hint: "Enter your age",
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 16),
                  _buildDropdownField(),
                ],
              ),
            ),
          ),
          // Fixed "Save" button at the bottom (unchanged)
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Container(
                decoration: BoxDecoration(
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF4CAF50).withOpacity(0.15),
                      spreadRadius: 1,
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                    BoxShadow(
                      color: const Color(0xFF4CAF50).withOpacity(0.05),
                      spreadRadius: 3,
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: () {
                    // Update user preferences
                    widget.userPreferences.username = _usernameController.text;
                    widget.userPreferences.phoneNumber = _phoneController.text;
                    widget.userPreferences.weight =
                        double.tryParse(_weightController.text);
                    widget.userPreferences.height =
                        double.tryParse(_heightController.text);
                    widget.userPreferences.age =
                        int.tryParse(_ageController.text);
                    widget.userPreferences.bloodGroup = _bloodGroup;
                    // Trigger callback to switch to home screen
                    widget.onSave();
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4CAF50),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        vertical: 16, horizontal: 48),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  child: const Text(
                    "Save",
                    style: TextStyle(
                      fontFamily: 'SF Pro',
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Helper method to build styled input fields with left-aligned text
  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required String hint,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFF2C2C2C), // Matches vendor/budget bar background
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1), // Subtle glow effect
            spreadRadius: 1,
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: const TextStyle(
            color: Colors.white,
            fontFamily: 'SF Pro',
            fontWeight:
                FontWeight.bold, // Matches bold text of vendor/budget bar
          ),
          hintStyle: const TextStyle(
            color: Colors.white60,
            fontFamily: 'SF Pro',
          ),
          filled: true,
          fillColor: Colors.transparent, // Background handled by Container
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
              vertical: 18, horizontal: 16), // Adjusted for height similarity
        ),
        keyboardType: keyboardType,
        style: const TextStyle(
          fontFamily: 'SF Pro',
          color: Colors.white,
        ),
        textAlign: TextAlign.left, // Changed to left-aligned
      ),
    );
  }

  // Helper method to build styled dropdown field with left-aligned text
  Widget _buildDropdownField() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: const Color(0xFF2C2C2C), // Matches vendor/budget bar background
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1), // Subtle glow effect
            spreadRadius: 1,
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: DropdownButtonFormField<String>(
        decoration: InputDecoration(
          labelText: "Blood Group",
          labelStyle: const TextStyle(
            color: Colors.white,
            fontFamily: 'SF Pro',
            fontWeight:
                FontWeight.bold, // Matches bold text of vendor/budget bar
          ),
          filled: true,
          fillColor: Colors.transparent, // Background handled by Container
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
              vertical: 18, horizontal: 16), // Adjusted for height similarity
        ),
        value: _bloodGroup,
        items: bloodGroups
            .map((bg) => DropdownMenuItem(
                  value: bg,
                  child: Text(
                    bg,
                    style: const TextStyle(
                      fontFamily: 'SF Pro',
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.left, // Changed to left-aligned
                  ),
                ))
            .toList(),
        onChanged: (val) => setState(() => _bloodGroup = val),
        style: const TextStyle(
          fontFamily: 'SF Pro',
          color: Colors.white,
        ),
        // Removed alignment: Alignment.center to ensure left alignment
      ),
    );
  }
}
