// lib/screens/home/gist_submission_screen.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Constants for table and column names
class GistFields {
  static const table = 'gists';
  static const userId = 'user_id';
  static const type = 'type';
  static const schoolId = 'school_id';
  static const title = 'title';
  static const imageUrl = 'image_url';
  static const startDate = 'start_date';
  static const numberOfDays = 'number_of_days';
  static const pricePerDay = 'price_per_day';
}

/// Maps UI labels to DB values
const Map<String, String> _typeMap = {
  'Local Gist': 'local',
  'Sports': 'sport',
  'Announcement': 'announcement',
  'Global Gist': 'global',
};

class GistSubmissionScreen extends StatefulWidget {
  final Color themeColor;
  final String? schoolId; // pass selected school ID

  const GistSubmissionScreen({
    super.key,
    required this.themeColor,
    required this.schoolId,
  });

  @override
  State<GistSubmissionScreen> createState() => _GistSubmissionScreenState();
}

class _GistSubmissionScreenState extends State<GistSubmissionScreen> {
  final _formKey = GlobalKey<FormState>();
  String? _selectedGistType;
  final _titleController = TextEditingController();
  XFile? _pickedImage;
  final _durationController = TextEditingController();

  double get _pricePerDay {
    final dbType = _typeMap[_selectedGistType];
    switch (dbType) {
      case 'local':
        return 1000;
      case 'sport':
        return 1000;
      case 'announcement':
        return 1000;
      case 'global':
        return 3000;
      default:
        return 1000;
    }
  }

  double get _estimatedPrice {
    final days = int.tryParse(_durationController.text) ?? 0;
    return _pricePerDay * days;
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null && mounted) setState(() => _pickedImage = image);
  }

  Future<void> _submitGist() async {
    if (!_formKey.currentState!.validate() || _pickedImage == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Complete form & pick an image')));
      }
      return;
    }

    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('You must be logged in')));
      }
      return;
    }

    final dbType = _typeMap[_selectedGistType];
    if (dbType == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Invalid gist type selected')));
      }
      return;
    }

    // Ensure schoolId for local gists
    if (dbType == 'local' && widget.schoolId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Select your school before posting a local gist')));
      }
      return;
    }

    const bucket = 'gist-images';
    final file = File(_pickedImage!.path);
    final ext = _pickedImage!.path.split('.').last;
    final filePath = 'gists/${const Uuid().v4()}.$ext';

    try {
      await supabase.storage.from(bucket).upload(filePath, file);
      final publicUrl = supabase.storage.from(bucket).getPublicUrl(filePath);

      final data = <String, dynamic>{
        GistFields.userId: user.id,
        GistFields.type: dbType,
        GistFields.title: _titleController.text,
        GistFields.imageUrl: publicUrl,
        GistFields.startDate: DateTime.now().toIso8601String(),
        GistFields.numberOfDays: int.parse(_durationController.text),
        GistFields.pricePerDay: _pricePerDay,
      };

      if (dbType == 'local') {
        data[GistFields.schoolId] = int.parse(widget.schoolId!);
      }

      await supabase.from(GistFields.table).insert(data);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Gist submitted successfully!')));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed to submit gist: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Image.asset(
          'assets/images/gist_us.png',
          height: 90,
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  decoration: InputDecoration(
                    labelText: 'Type of Gist',
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: widget.themeColor),
                    ),
                  ),
                  items: _typeMap.keys
                      .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                      .toList(),
                  value: _selectedGistType,
                  onChanged: (v) =>
                      mounted ? setState(() => _selectedGistType = v) : null,
                  validator: (v) => v == null ? 'Select a gist type' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _titleController,
                  maxLength: 50,
                  decoration: InputDecoration(
                    labelText: 'Gist Title',
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: widget.themeColor),
                    ),
                  ),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Enter a title' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _durationController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Duration (days)',
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: widget.themeColor),
                    ),
                  ),
                  onChanged: (_) => mounted ? setState(() {}) : null,
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    return (n == null || n <= 0) ? 'Enter valid days' : null;
                  },
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  icon: const Icon(Icons.image),
                  label: Text(
                      _pickedImage == null ? 'Upload Image' : 'Change Image'),
                  style: OutlinedButton.styleFrom(
                      side: BorderSide(color: widget.themeColor)),
                  onPressed: _pickImage,
                ),
                if (_pickedImage != null) ...[
                  const SizedBox(height: 8),
                  Image.file(File(_pickedImage!.path), height: 100),
                ],
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Estimated Price:',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    Text('₦${_estimatedPrice.toStringAsFixed(0)}',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: widget.themeColor)),
                  ],
                ),
                const Spacer(),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _submitGist,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.themeColor,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Advertise'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
