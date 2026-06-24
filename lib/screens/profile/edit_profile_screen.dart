// lib/screens/profile/edit_profile_screen.dart
import 'dart:io';
import 'package:allowance/screens/home/home_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:allowance/models/user_preferences.dart';

const Color _bg = Color(0xFF121212);
const Color _accent = Color(0xFF4CAF50);

class EditProfileScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  const EditProfileScreen({super.key, required this.userPreferences});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _displayNameController;
  late TextEditingController _usernameController;
  late TextEditingController _phoneController;
  late TextEditingController _bioController;
  late TextEditingController _dobController; // ← NEW for Date of Birth

  DateTime? _selectedDob;
  XFile? _pickedAvatar;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _displayNameController =
        TextEditingController(text: widget.userPreferences.fullName ?? '');
    _usernameController =
        TextEditingController(text: widget.userPreferences.username ?? '');
    _phoneController =
        TextEditingController(text: widget.userPreferences.phoneNumber ?? '');
    _bioController =
        TextEditingController(text: widget.userPreferences.bio ?? '');

    // Show their existing age if they already have one saved
    _dobController = TextEditingController(
        text: widget.userPreferences.age != null
            ? '${widget.userPreferences.age} years old'
            : '');
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _usernameController.dispose();
    _phoneController.dispose();
    _bioController.dispose();
    _dobController.dispose();
    super.dispose();
  }

  // --- NEW: THE COOL DATE OF BIRTH SLIDER ---
  void _selectDateOfBirth() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (BuildContext builder) {
        return SizedBox(
          height: 300,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20.0, vertical: 16.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Select Date of Birth',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Done',
                          style: TextStyle(
                              color: _accent,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                    )
                  ],
                ),
              ),
              Expanded(
                child: CupertinoTheme(
                  data: const CupertinoThemeData(
                    textTheme: CupertinoTextThemeData(
                      dateTimePickerTextStyle:
                          TextStyle(color: Colors.white, fontSize: 20),
                    ),
                  ),
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.date,
                    // Default to 18 years ago if they haven't picked one yet
                    initialDateTime: _selectedDob ??
                        DateTime.now().subtract(const Duration(days: 365 * 18)),
                    minimumDate: DateTime(1950),
                    maximumDate: DateTime.now().subtract(
                        const Duration(days: 365 * 13)), // Must be 13+
                    onDateTimeChanged: (DateTime newDate) {
                      setState(() {
                        _selectedDob = newDate;
                        // Accurately calculate age
                        int age = DateTime.now().year - newDate.year;
                        if (DateTime.now().month < newDate.month ||
                            (DateTime.now().month == newDate.month &&
                                DateTime.now().day < newDate.day)) {
                          age--;
                        }
                        _dobController.text =
                            '${newDate.day}/${newDate.month}/${newDate.year} ($age yrs)';
                      });
                    },
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final f =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (f != null && mounted) setState(() => _pickedAvatar = f);
  }

  Future<String?> _uploadAvatarIfPicked() async {
    if (_pickedAvatar == null) return widget.userPreferences.avatarUrl;

    final client = Supabase.instance.client;
    final bucket = 'avatars';
    final ext = _pickedAvatar!.name.split('.').last;
    final filename = 'avatars/${const Uuid().v4()}.$ext';

    try {
      final bytes = await _pickedAvatar!.readAsBytes();
      await client.storage.from(bucket).uploadBinary(
            filename,
            bytes,
            fileOptions: const FileOptions(upsert: false),
          );
      return client.storage.from(bucket).getPublicUrl(filename);
    } catch (e) {
      debugPrint('Avatar upload failed: $e');
      return null;
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;

    try {
      final String? newAvatarUrl = await _uploadAvatarIfPicked();

      // Calculate Age to maintain DB Schema
      int? computedAge = widget.userPreferences.age;
      if (_selectedDob != null) {
        computedAge = DateTime.now().year - _selectedDob!.year;
        if (DateTime.now().month < _selectedDob!.month ||
            (DateTime.now().month == _selectedDob!.month &&
                DateTime.now().day < _selectedDob!.day)) {
          computedAge--;
        }
      }

      // Update UserPreferences locally
      widget.userPreferences.fullName = _displayNameController.text.trim();
      widget.userPreferences.username = _usernameController.text.trim();
      widget.userPreferences.phoneNumber = _phoneController.text.trim();
      widget.userPreferences.bio = _bioController.text.trim();
      widget.userPreferences.age = computedAge;

      // Nullify old fields locally
      widget.userPreferences.weight = null;
      widget.userPreferences.height = null;
      widget.userPreferences.bloodGroup = null;

      if (newAvatarUrl != null) {
        widget.userPreferences.avatarUrl = newAvatarUrl;
      }

      widget.userPreferences.hasCompletedProfile = true;
      await widget.userPreferences.savePreferences();

      // Upsert to Supabase
      if (user != null) {
        final Map<String, dynamic> updates = {
          'id': user.id,
          'full_name': widget.userPreferences.fullName,
          'username': widget.userPreferences.username,
          'avatar_url': widget.userPreferences.avatarUrl,
          'phone_number': widget.userPreferences.phoneNumber,
          'age': widget.userPreferences.age,
          'bio': widget.userPreferences.bio,
          // Explicitly clear old unused fields from the DB
          'weight': null,
          'height': null,
          'blood_group': null,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        };

        // Remove nulls EXCEPT for the ones we explicitly want to erase
        updates.removeWhere((key, value) =>
            value == null &&
            key != 'weight' &&
            key != 'height' &&
            key != 'blood_group');

        try {
          await supabase.from('profiles').upsert(updates);
        } catch (e) {
          debugPrint('Supabase upsert failed (non-fatal): $e');
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Profile saved successfully!'),
            backgroundColor: _accent,
          ),
        );
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (_) => HomeScreen(userPreferences: widget.userPreferences),
          ),
          (route) => false,
        );
      }
    } catch (e) {
      debugPrint('Save profile error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Failed to save profile'),
              backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  InputDecoration _buildInputDecoration(String label, IconData icon,
      {String? prefixText}) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54, fontSize: 14),
      prefixIcon: Icon(icon, color: Colors.white54, size: 20),
      prefixText: prefixText,
      prefixStyle: const TextStyle(color: Colors.white, fontSize: 16),
      filled: true,
      fillColor: const Color(0xFF1E1E1E), // App's standard card color
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: _accent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: const BorderSide(color: Colors.redAccent, width: 1),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
    );
  }

  @override
  Widget build(BuildContext context) {
    final avatarUrl = widget.userPreferences.avatarUrl;

    ImageProvider? imageProvider;
    if (_pickedAvatar != null) {
      imageProvider = FileImage(File(_pickedAvatar!.path));
    } else if (avatarUrl != null && avatarUrl.isNotEmpty) {
      imageProvider = NetworkImage(
          '$avatarUrl?ts=${DateTime.now().millisecondsSinceEpoch}');
    }

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        centerTitle: true,
        title: const Text('Edit Profile',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            children: [
              // --- 1. IDENTITY SECTION (Avatar + Bio) ---
              Center(
                child: Stack(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: _accent.withOpacity(0.5), width: 2),
                      ),
                      child: CircleAvatar(
                        radius: 56,
                        backgroundColor: const Color(0xFF1E1E1E),
                        backgroundImage: imageProvider,
                        child: imageProvider == null
                            ? const Icon(Icons.person,
                                size: 50, color: Colors.white24)
                            : null,
                      ),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Material(
                        color: _accent,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: const BorderSide(color: _bg, width: 3)),
                        child: InkWell(
                          onTap: _pickAvatar,
                          borderRadius: BorderRadius.circular(12),
                          child: const Padding(
                            padding: EdgeInsets.all(8.0),
                            child: Icon(Icons.camera_alt,
                                color: Colors.black, size: 18),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Bio directly underneath the Avatar
              TextFormField(
                controller: _bioController,
                style: const TextStyle(color: Colors.white, fontSize: 15),
                maxLines: 3,
                maxLength: 160,
                textAlign: TextAlign.center,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  hintText: "Write a short bio about yourself...",
                  hintStyle: const TextStyle(
                      color: Colors.white38, fontStyle: FontStyle.italic),
                  filled: true,
                  fillColor:
                      Colors.transparent, // Blends perfectly with background
                  counterStyle:
                      const TextStyle(color: Colors.white38, fontSize: 10),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: Colors.white10),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(16),
                    borderSide: const BorderSide(color: _accent, width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.all(16),
                ),
              ),
              const SizedBox(height: 32),

              // --- 2. ACCOUNT DETAILS SECTION ---
              const Text("ACCOUNT DETAILS",
                  style: TextStyle(
                      color: _accent,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2)),
              const SizedBox(height: 16),

              TextFormField(
                controller: _displayNameController,
                decoration:
                    _buildInputDecoration('Full Name', Icons.badge_outlined),
                style: const TextStyle(color: Colors.white),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Full name is required'
                    : null,
              ),
              const SizedBox(height: 16),

              TextFormField(
                controller: _usernameController,
                decoration: _buildInputDecoration(
                    'Username', Icons.alternate_email,
                    prefixText: '@'),
                style: const TextStyle(color: Colors.white),
                validator: (v) {
                  if (v == null || v.trim().isEmpty)
                    return 'Username is required';
                  if (v.contains(' ')) return 'No spaces allowed';
                  return null;
                },
              ),
              const SizedBox(height: 16),

              TextFormField(
                controller: _phoneController,
                decoration:
                    _buildInputDecoration('Phone Number', Icons.phone_outlined),
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Phone number is required'
                    : null,
              ),
              const SizedBox(height: 16),

              // --- NEW: DATE OF BIRTH SLIDER FILED ---
              TextFormField(
                controller: _dobController,
                readOnly: true, // Prevents keyboard from popping up
                onTap: _selectDateOfBirth, // Triggers the cool slider!
                decoration:
                    _buildInputDecoration('Date of Birth', Icons.cake_outlined),
                style: const TextStyle(color: Colors.white),
                validator: (v) => (v == null || v.trim().isEmpty)
                    ? 'Date of birth is required'
                    : null,
              ),

              const SizedBox(height: 48),

              // --- SAVE BUTTON ---
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isSaving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    disabledBackgroundColor: _accent.withOpacity(0.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    elevation: 4,
                  ),
                  child: _isSaving
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(
                              color: Colors.black, strokeWidth: 3))
                      : const Text('Save Changes',
                          style: TextStyle(
                              color: Colors.black,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ),
    );
  }
}
