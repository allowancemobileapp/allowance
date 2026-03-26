// lib/screens/home/gist_submission_screen.dart

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
// ignore: unused_import
import 'dart:developer' as developer;

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
  static const url = 'url'; // optional URL
  static const status = 'status';
}

/// Maps UI labels to DB values (only local & global)
const Map<String, String> _typeMap = {
  'Local Gist': 'local',
  'Global Gist': 'global',
};

class GistSubmissionScreen extends StatefulWidget {
  final Color themeColor;
  final String? schoolId; // optional preselected school ID (string)

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
  String? _selectedSchoolId;
  final _titleController = TextEditingController();
  XFile? _pickedImage;
  final _durationController = TextEditingController();
  final _urlController = TextEditingController();

  late Future<List<Map<String, dynamic>>> _schoolsFuture;
  bool _isSubmitting = false;
  Uint8List? _pickedImageBytes;

  String? _selectedCategory;
  final categories = ['Sports', 'Entertainment', 'Official', 'Religion'];

  @override
  void initState() {
    super.initState();
    _selectedSchoolId = widget.schoolId;
    _schoolsFuture = _fetchSchools();
    _recoverPendingGistPayment(); // ← NEW SAFETY NET
  }

  Future<List<Map<String, dynamic>>> _fetchSchools() async {
    try {
      final supabase = Supabase.instance.client;
      // cast result explicitly to List<dynamic>? then map safely
      final dynamic raw = await supabase.from('schools').select().order('name');
      final List<dynamic>? resp = raw as List<dynamic>?;
      if (resp == null) return [];
      return resp
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  double get _pricePerDay {
    final dbType = _typeMap[_selectedGistType];
    switch (dbType) {
      case 'local':
        return 500;
      case 'global':
        return 1000;
      default:
        return 500;
    }
  }

  double get _estimatedPrice {
    final days = int.tryParse(_durationController.text) ?? 0;
    return _pricePerDay * days;
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();

    final picked = await picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 80,
    );

    if (!mounted) return;

    if (picked != null) {
      Uint8List? bytes;
      if (kIsWeb) {
        bytes = await picked.readAsBytes();
      }
      setState(() {
        _pickedImage = picked;
        if (bytes != null) _pickedImageBytes = bytes;
      });
    }
  }

  // ==================== RECOVERY (updated for full safety) ====================
  Future<void> _recoverPendingGistPayment() async {
    final prefs = await SharedPreferences.getInstance();
    final pendingJson = prefs.getString('pending_gist_payment');
    if (pendingJson == null) return;

    final Map<String, dynamic> data = jsonDecode(pendingJson);
    final String reference = data['reference'] as String;
    final int gistId = data['gistId'] as int;

    // We don't need to pass days here because _pollAndVerifyGistPayment already reads it
    setState(() => _isSubmitting = true);

    final success = await _pollAndVerifyGistPayment(reference, gistId);

    if (success) {
      await prefs.remove('pending_gist_payment');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('✅ Gist payment recovered and published!'),
              backgroundColor: Colors.green),
        );
        Navigator.of(context).pop(); // close screen
      }
    }
    // If still processing, leave the pending data for next time
    if (mounted) setState(() => _isSubmitting = false);
  }

  // ==================== MAIN SUBMIT (auto-verification) ====================
  Future<void> _submitGist() async {
    if (!_formKey.currentState!.validate() ||
        _pickedImage == null ||
        _selectedGistType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Complete form & pick an image')));
      return;
    }

    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return;

    final dbType = _typeMap[_selectedGistType];
    if (dbType == null) return;

    final chosenSchoolId = _selectedSchoolId ?? widget.schoolId;
    if (dbType == 'local' &&
        (chosenSchoolId == null || chosenSchoolId.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Select university for local gist')));
      return;
    }

    setState(() => _isSubmitting = true);
    int? draftGistId;

    try {
      // 1. Upload image (your existing code)
      const bucket = 'gist-images';
      final ext = _pickedImage!.name.split('.').last;
      final filePath = 'gists/${const Uuid().v4()}.$ext';

      if (kIsWeb) {
        final bytes = await _pickedImage!.readAsBytes();
        await supabase.storage.from(bucket).uploadBinary(filePath, bytes,
            fileOptions: const FileOptions(contentType: 'image/*'));
      } else {
        final file = File(_pickedImage!.path);
        await supabase.storage.from(bucket).upload(filePath, file);
      }

      final publicUrl = supabase.storage.from(bucket).getPublicUrl(filePath);

      // 2. Create draft gist
      final numDays = int.tryParse(_durationController.text) ?? 0;
      final pricePerDay = _pricePerDay;
      final totalNaira = (pricePerDay * numDays).toInt();

      final draftPayload = {
        'user_id': user.id,
        'type': dbType,
        'title': _titleController.text.trim(),
        'image_url': publicUrl,
        'image_path': filePath,
        'number_of_days': numDays,
        'price_per_day': pricePerDay,
        'paid': false,
        'status': 'draft',
        'start_date': DateTime.now().toUtc().toIso8601String().split('T').first,
        'category': _selectedCategory,
      };

      // ONLY attach the school_id if the gist type is 'local'
      if (dbType == 'local' &&
          chosenSchoolId != null &&
          chosenSchoolId.isNotEmpty) {
        draftPayload['school_id'] = int.tryParse(chosenSchoolId);
      }

      if (_urlController.text.trim().isNotEmpty) {
        draftPayload['url'] = _urlController.text.trim();
      }

      final insertResp = await supabase
          .from('gists')
          .insert(draftPayload)
          .select('id')
          .single();
      draftGistId = insertResp['id'] as int;

      if (totalNaira <= 0) {
        await supabase.from('gists').delete().eq('id', draftGistId);
        return;
      }

      // 3. Paystack initialize
      final reference = 'gist_${const Uuid().v4()}';
      final payload = {
        'amount': totalNaira * 100,
        'email': user.email ?? '',
        'reference': reference,
        'metadata': {'gist_id': draftGistId.toString()},
      };

      final httpResp = await http.post(
        Uri.parse('https://api.paystack.co/transaction/initialize'),
        headers: {
          'Authorization': 'Bearer ${dotenv.env['PAYSTACK_SECRET_KEY']}',
          'Content-Type': 'application/json'
        },
        body: jsonEncode(payload),
      );

      if (httpResp.statusCode != 200) {
        await supabase.from('gists').delete().eq('id', draftGistId);
        return;
      }

      final authUrl = jsonDecode(httpResp.body)['data']['authorization_url'];

      // ←←← SAVE PENDING BEFORE OPENING BROWSER
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'pending_gist_payment',
          jsonEncode({
            'reference': reference,
            'gistId': draftGistId,
            'numberOfDays': numDays, // ← ADD THIS LINE
          }));

      final uri = Uri.parse(authUrl);
      await launchUrl(uri, mode: LaunchMode.inAppBrowserView);

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Payment opened. Complete it — we verify automatically...'),
            duration: Duration(seconds: 8)),
      );

      // ←←← AUTOMATIC POLLING
      final success = await _pollAndVerifyGistPayment(reference, draftGistId);

      if (success) {
        await prefs.remove('pending_gist_payment');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('✅ Gist published!'),
              backgroundColor: Colors.green));
          Navigator.of(context).pop();
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              'Payment taking a while. We will check again when you return.'),
          backgroundColor: Colors.orange,
        ));
      }
    } catch (e) {
      if (draftGistId != null) {
        try {
          await supabase.from('gists').delete().eq('id', draftGistId);
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  // ==================== POLLING (now 100% safe even if user leaves screen) ====================
  Future<bool> _pollAndVerifyGistPayment(String reference, int gistId) async {
    // Try to get saved numberOfDays from pending data (most reliable)
    final prefs = await SharedPreferences.getInstance();
    final pendingJson = prefs.getString('pending_gist_payment');
    int savedDays = 0;

    if (pendingJson != null) {
      try {
        final data = jsonDecode(pendingJson) as Map<String, dynamic>;
        savedDays = (data['numberOfDays'] as num?)?.toInt() ?? 0;
      } catch (_) {}
    }

    // Fallback to controller if nothing saved
    if (savedDays == 0) {
      savedDays = int.tryParse(_durationController.text) ?? 0;
    }

    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final resp = await http.get(
          Uri.parse('https://api.paystack.co/transaction/verify/$reference'),
          headers: {
            'Authorization': 'Bearer ${dotenv.env['PAYSTACK_SECRET_KEY']}'
          },
        );

        if (resp.statusCode == 200) {
          final data = jsonDecode(resp.body);
          if (data['status'] == true && data['data']?['status'] == 'success') {
            final amountPaid = data['data']['amount'] as int;

            await Supabase.instance.client.from('gists').update({
              'paid': true,
              'status': 'active',
              'payment_reference': reference,
              'amount_paid': amountPaid,
              'end_date': DateTime.now()
                  .add(Duration(days: savedDays)) // ← NOW USES SAVED VALUE
                  .toIso8601String(),
              'updated_at': DateTime.now().toIso8601String(),
            }).eq('id', gistId);

            return true;
          }
        }
      } catch (_) {}
      await Future.delayed(const Duration(seconds: 4));
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final bg = Colors.grey[900];
    final fieldFill = Colors.grey[850];

    return Scaffold(
      backgroundColor: bg,
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  // This style property fixes the text color of the SELECTED item
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontFamily: 'SanFrancisco'),
                  decoration: InputDecoration(
                    labelText: 'Type of Gist',
                    labelStyle: const TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: fieldFill,
                    border: OutlineInputBorder(
                        borderSide: BorderSide(color: widget.themeColor)),
                  ),
                  items: _typeMap.keys
                      .map((g) => DropdownMenuItem(
                            value: g,
                            // This style fixes the text color of items INSIDE the list
                            child: Text(g,
                                style: const TextStyle(color: Colors.white)),
                          ))
                      .toList(),
                  value: _selectedGistType,
                  onChanged: (v) =>
                      mounted ? setState(() => _selectedGistType = v) : null,
                  validator: (v) => v == null ? 'Select a gist type' : null,
                  dropdownColor:
                      Colors.grey[850], // Background color of the popup menu
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontFamily: 'SanFrancisco'),
                  value: _selectedCategory,
                  items: categories
                      .map((c) => DropdownMenuItem(
                            value: c,
                            child: Text(c,
                                style: const TextStyle(color: Colors.white)),
                          ))
                      .toList(),
                  onChanged: (val) => setState(() => _selectedCategory = val),
                  decoration: InputDecoration(
                    labelText: 'Category',
                    labelStyle: const TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: fieldFill,
                    border: OutlineInputBorder(
                        borderSide: BorderSide(color: widget.themeColor)),
                  ),
                  dropdownColor: Colors.grey[850],
                ),
                const SizedBox(height: 12),
                if (_selectedGistType == 'Local Gist') ...[
                  FutureBuilder<List<Map<String, dynamic>>>(
                    future: _schoolsFuture,
                    builder: (ctx, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const SizedBox(
                            height: 56,
                            child: Center(child: CircularProgressIndicator()));
                      }
                      final schools = snap.data ?? [];
                      return DropdownButtonFormField<String>(
                        // 1. This makes the SELECTED text white
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontFamily: 'SanFrancisco'),
                        decoration: InputDecoration(
                          labelText: 'Select University',
                          labelStyle: const TextStyle(color: Colors.white70),
                          filled: true,
                          fillColor: fieldFill,
                          border: OutlineInputBorder(
                              borderSide: BorderSide(color: widget.themeColor)),
                        ),
                        items: schools.map((s) {
                          final id = s['id']?.toString() ?? '';
                          final name = s['name']?.toString() ?? id;
                          return DropdownMenuItem(
                            value: id,
                            // 2. This makes the text INSIDE THE LIST white
                            child: Text(
                              name,
                              style: const TextStyle(color: Colors.white),
                            ),
                          );
                        }).toList(),
                        value: _selectedSchoolId,
                        onChanged: (v) => mounted
                            ? setState(() => _selectedSchoolId = v)
                            : null,
                        validator: (v) => (v == null || v.isEmpty)
                            ? 'Select a university'
                            : null,
                        dropdownColor: Colors.grey[850],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  controller: _titleController,
                  maxLength: 150,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Gist Title',
                    labelStyle: const TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: fieldFill,
                    border: OutlineInputBorder(
                        borderSide: BorderSide(color: widget.themeColor)),
                  ),
                  validator: (v) =>
                      (v == null || v.isEmpty) ? 'Enter a title' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _urlController,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Optional URL (will show on gist)',
                    labelStyle: const TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: fieldFill,
                    border: OutlineInputBorder(
                        borderSide: BorderSide(color: widget.themeColor)),
                  ),
                  keyboardType: TextInputType.url,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    final uri = Uri.tryParse(v.trim());
                    if (uri == null || (!uri.hasScheme))
                      return 'Enter a valid URL (include https://)';
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _durationController,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Duration (days)',
                    labelStyle: const TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: fieldFill,
                    border: OutlineInputBorder(
                        borderSide: BorderSide(color: widget.themeColor)),
                  ),
                  onChanged: (_) => mounted ? setState(() {}) : null,
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    return (n == null || n <= 0) ? 'Enter valid days' : null;
                  },
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.image, color: Colors.white),
                  label: Text(
                      _pickedImage == null ? 'Upload Image' : 'Change Image',
                      style: const TextStyle(color: Colors.white)),
                  style: OutlinedButton.styleFrom(
                      side: BorderSide(color: widget.themeColor),
                      backgroundColor: Colors.transparent),
                  onPressed: _pickImage,
                ),
                if (_pickedImage != null) ...[
                  const SizedBox(height: 8),
                  kIsWeb
                      ? Image.memory(_pickedImageBytes!,
                          height: 120, fit: BoxFit.cover)
                      : Image.file(File(_pickedImage!.path),
                          height: 120, fit: BoxFit.cover),
                ],
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Estimated Price:',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                    Text('₦${_estimatedPrice.toStringAsFixed(0)}',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: widget.themeColor)),
                  ],
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isSubmitting ? null : _submitGist,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: widget.themeColor,
                        padding: const EdgeInsets.symmetric(vertical: 14)),
                    child: _isSubmitting
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2))
                        : const Text('Advertise'),
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
