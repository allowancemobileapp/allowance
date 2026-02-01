// lib/screens/profile/edit_profile_screen.dart
import 'dart:io';
import 'package:allowance/screens/home/home_screen.dart';
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
  late TextEditingController _weightController;
  late TextEditingController _heightController;
  late TextEditingController _ageController;

  String? _bloodGroup;
  XFile? _pickedAvatar;
  bool _isSaving = false;

  final List<String> bloodGroups = [
    "A+",
    "A-",
    "B+",
    "B-",
    "AB+",
    "AB-",
    "O+",
    "O-"
  ];

  @override
  void initState() {
    super.initState();
    _displayNameController =
        TextEditingController(text: widget.userPreferences.fullName ?? '');
    _usernameController =
        TextEditingController(text: widget.userPreferences.username ?? '');
    _phoneController =
        TextEditingController(text: widget.userPreferences.phoneNumber ?? '');
    _weightController = TextEditingController(
        text: widget.userPreferences.weight?.toString() ?? '');
    _heightController = TextEditingController(
        text: widget.userPreferences.height?.toString() ?? '');
    _ageController = TextEditingController(
        text: widget.userPreferences.age?.toString() ?? '');
    _bloodGroup = widget.userPreferences.bloodGroup;
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _usernameController.dispose();
    _phoneController.dispose();
    _weightController.dispose();
    _heightController.dispose();
    _ageController.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final f =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 70);
    if (f != null && mounted) setState(() => _pickedAvatar = f);
  }

  /// Upload avatar to 'avatars' bucket and return the resolved public URL (or null).
  Future<String?> _uploadAvatarIfPicked() async {
    if (_pickedAvatar == null) return widget.userPreferences.avatarUrl;

    final client = Supabase.instance.client;
    final bucket = 'avatars';
    final ext = _pickedAvatar!.name.split('.').last; // use .name, not .path
    final filename = 'avatars/${const Uuid().v4()}.$ext';

    try {
      final bytes = await _pickedAvatar!.readAsBytes();

      await client.storage.from(bucket).uploadBinary(
            filename,
            bytes,
            fileOptions: FileOptions(upsert: false),
          );

      // Get public URL
      final String publicUrl =
          client.storage.from(bucket).getPublicUrl(filename);
      return publicUrl;
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
      // 1. Upload avatar first
      final String? newAvatarUrl = await _uploadAvatarIfPicked();

      // 2. Update local UserPreferences (no longer allowing null for required fields – validation already ensures they are not empty)
      widget.userPreferences.fullName = _displayNameController.text.trim();
      widget.userPreferences.username = _usernameController.text.trim();
      widget.userPreferences.phoneNumber = _phoneController.text.trim();
      widget.userPreferences.weight =
          double.tryParse(_weightController.text.trim());
      widget.userPreferences.height =
          double.tryParse(_heightController.text.trim());
      widget.userPreferences.age = int.parse(_ageController.text.trim());
      widget.userPreferences.bloodGroup = _bloodGroup;

      if (newAvatarUrl != null) {
        widget.userPreferences.avatarUrl = newAvatarUrl;
        setState(() {});
      }

      // 3. Mark profile completed + save locally + server
      widget.userPreferences.hasCompletedProfile = true;
      await widget.userPreferences.savePreferences();

      // 4. Extra upsert to Supabase (safety net)
      if (user != null) {
        final Map<String, dynamic> updates = {
          'id': user.id,
          'full_name': widget.userPreferences.fullName,
          'username': widget.userPreferences.username,
          'avatar_url': widget.userPreferences.avatarUrl,
          'phone_number': widget.userPreferences.phoneNumber,
          'weight': widget.userPreferences.weight,
          'height': widget.userPreferences.height,
          'age': widget.userPreferences.age,
          'blood_group': widget.userPreferences.bloodGroup,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        };

        updates.removeWhere((key, value) => value == null);

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
      }

      if (mounted) {
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
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  InputDecoration _inputDecoration(String label) => InputDecoration(
        labelText: label,
        labelStyle: const TextStyle(color: Colors.white70),
        filled: true,
        fillColor: Colors.white.withOpacity(0.03),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: const BorderSide(color: _accent, width: 1.4)),
      );

  @override
  Widget build(BuildContext context) {
    final avatarUrl = widget.userPreferences.avatarUrl;

    // ←←← THIS IS THE FINAL FIX FOR AVATAR NOT UPDATING
    ImageProvider? imageProvider;
    if (_pickedAvatar != null) {
      imageProvider = FileImage(File(_pickedAvatar!.path));
    } else if (avatarUrl != null && avatarUrl.isNotEmpty) {
      // Forces Flutter to reload the new image immediately (bypasses cache)
      imageProvider = NetworkImage(
          '$avatarUrl?ts=${DateTime.now().millisecondsSinceEpoch}');
    }
    // ←←← END OF FIX

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
          backgroundColor: _bg,
          elevation: 1,
          title: const Text('Edit profile',
              style: TextStyle(color: Colors.white))),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: Stack(
                  children: [
                    CircleAvatar(
                        radius: 52,
                        backgroundColor: Colors.grey[800],
                        backgroundImage: imageProvider),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Material(
                        color: _accent,
                        shape: const CircleBorder(),
                        child: IconButton(
                          icon: const Icon(Icons.edit, color: Colors.black),
                          onPressed: _pickAvatar,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              TextFormField(
                controller: _displayNameController,
                decoration: _inputDecoration('Full name *'),
                style: const TextStyle(color: Colors.white),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'Full name is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _usernameController,
                decoration: _inputDecoration('Username (public) *'),
                style: const TextStyle(color: Colors.white),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'Username is required';
                  }
                  if (v.contains(' ')) {
                    return 'No spaces allowed';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _phoneController,
                decoration: _inputDecoration('Phone number *'),
                keyboardType: TextInputType.phone,
                style: const TextStyle(color: Colors.white),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'Phone number is required';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                      child: TextFormField(
                          controller: _weightController,
                          decoration: _inputDecoration('Weight (kg)'),
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white))),
                  const SizedBox(width: 12),
                  Expanded(
                      child: TextFormField(
                          controller: _heightController,
                          decoration: _inputDecoration('Height (cm)'),
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white))),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _ageController,
                decoration: _inputDecoration('Age *'),
                keyboardType: TextInputType.number,
                style: const TextStyle(color: Colors.white),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) {
                    return 'Age is required';
                  }
                  final age = int.tryParse(v);
                  if (age == null || age <= 0) {
                    return 'Enter a valid age';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _bloodGroup,
                items: bloodGroups
                    .map((b) => DropdownMenuItem(
                        value: b,
                        child: Text(b,
                            style: const TextStyle(color: Colors.white))))
                    .toList(),
                dropdownColor: Colors.grey[850],
                decoration: _inputDecoration('Blood group'),
                onChanged: (v) => setState(() => _bloodGroup = v),
                style: const TextStyle(color: Colors.white),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _isSaving ? null : _save,
                style: ElevatedButton.styleFrom(
                    backgroundColor: _accent,
                    padding: const EdgeInsets.symmetric(vertical: 14)),
                child: _isSaving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                            color: Colors.black, strokeWidth: 2))
                    : const Text('Save changes',
                        style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
