// lib/screens/home/gist_submission_screen.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
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

  @override
  void initState() {
    super.initState();
    _selectedSchoolId = widget.schoolId;
    _schoolsFuture = _fetchSchools();
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
    final image =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (image != null && mounted) setState(() => _pickedImage = image);
  }

  Future<void> _submitGist() async {
    // quick validation
    if (!_formKey.currentState!.validate() ||
        _pickedImage == null ||
        _selectedGistType == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Complete form & pick an image')),
        );
      }
      return;
    }

    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You must be logged in to post a gist')),
        );
      }
      return;
    }

    final dbType = _typeMap[_selectedGistType];
    if (dbType == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Invalid gist type selected')),
        );
      }
      return;
    }

    final chosenSchoolId = _selectedSchoolId ?? widget.schoolId;
    if (dbType == 'local' &&
        (chosenSchoolId == null || chosenSchoolId.isEmpty)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Select the target university for a local gist')),
        );
      }
      return;
    }

    setState(() => _isSubmitting = true);
    String? draftGistId;

    try {
      // ---------- 1) Upload image to storage ----------
      const bucket = 'gist-images';
      final file = File(_pickedImage!.path);
      final ext = _pickedImage!.path.split('.').last;
      final filePath = 'gists/${const Uuid().v4()}.$ext';

      await supabase.storage.from(bucket).upload(filePath, file);

      // get public url (supabase_flutter typically returns String)
      final publicUrl = supabase.storage.from(bucket).getPublicUrl(filePath);

      // ---------- 2) Create draft gist (paid: false) ----------
      final now = DateTime.now().toUtc();
      final startDateStr = now.toIso8601String().split('T').first; // YYYY-MM-DD
      final numDays = int.tryParse(_durationController.text) ?? 0;
      final pricePerDay = _pricePerDay;
      final createdAt = now.toIso8601String();

      final Map<String, dynamic> draftPayload = {
        'user_id': user.id,
        'type': dbType,
        'title': _titleController.text.trim(),
        'image_url': publicUrl,
        'image_path': filePath,
        'number_of_days': numDays,
        'price_per_day': pricePerDay,
        'paid': false,
        'payment_reference': null,
        'start_date': startDateStr,
        'status': 'draft',
        'created_at': createdAt,
      };

      if (chosenSchoolId != null && chosenSchoolId.isNotEmpty) {
        final maybeInt = int.tryParse(chosenSchoolId);
        if (maybeInt != null) draftPayload['school_id'] = maybeInt;
      }

      final providedUrl = _urlController.text.trim();
      if (providedUrl.isNotEmpty) draftPayload['url'] = providedUrl;

      final insertResp = await supabase
          .from('gists')
          .insert(draftPayload)
          .select('id')
          .maybeSingle();

      // normalize insert response to get id
      dynamic returnedId;
      if (insertResp == null) {
        throw Exception('Failed to create draft gist (no response).');
      } else if (insertResp is Map && insertResp.containsKey('id')) {
        returnedId = insertResp['id'];
      } else if (insertResp is List &&
          insertResp.isNotEmpty &&
          insertResp[0] is Map &&
          insertResp[0].containsKey('id')) {
        returnedId = insertResp[0]['id'];
      } else if (insertResp is Map && insertResp.values.isNotEmpty) {
        final first = insertResp.values.first;
        if (first is Map && first.containsKey('id')) returnedId = first['id'];
      }

      if (returnedId == null) {
        throw Exception('Failed to retrieve draft gist id.');
      }
      draftGistId = returnedId.toString();

      // ---------- 3) Prepare payment init (DIRECT PAYSTACK) ----------
      final totalNaira = (pricePerDay * numDays).toInt();
      if (totalNaira <= 0) {
        // remove draft if invalid total
        if (draftGistId != null) {
          try {
            await supabase.from('gists').delete().eq('id', draftGistId);
          } catch (_) {}
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Enter a valid number of days')),
          );
        }
        return;
      }

      final paystackSecretKey = dotenv.env['PAYSTACK_SECRET_KEY'];
      if (paystackSecretKey == null || paystackSecretKey.isEmpty) {
        // critical: don't proceed without secret
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Missing Paystack secret key')),
          );
        }
        return;
      }

      // generate a stable reference we'll use for verification
      final reference = 'gist_${const Uuid().v4()}';

      final payload = {
        'amount': totalNaira * 100, // amount in kobo
        'email': user.email ?? '',
        'reference': reference,
        'metadata': {'gist_id': draftGistId}
      };

      final httpResp = await http.post(
        Uri.parse('https://api.paystack.co/transaction/initialize'),
        headers: {
          'Authorization': 'Bearer $paystackSecretKey',
          'Content-Type': 'application/json',
        },
        body: jsonEncode(payload),
      );

      if (httpResp.statusCode < 200 || httpResp.statusCode >= 300) {
        // cleanup draft if init fails
        if (draftGistId != null) {
          try {
            await supabase.from('gists').delete().eq('id', draftGistId);
          } catch (_) {}
        }
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text('Payment init failed (${httpResp.statusCode})')),
          );
        }
        return;
      }

      final respJson = jsonDecode(httpResp.body) as Map<String, dynamic>? ?? {};
      final authUrl = respJson['data']?['authorization_url'] ??
          respJson['authorization_url'] ??
          '';

      if (authUrl == null || (authUrl as String).isEmpty) {
        // cleanup draft if no URL
        if (draftGistId != null) {
          try {
            await supabase.from('gists').delete().eq('id', draftGistId);
          } catch (_) {}
        }
        if (mounted) {
          final msg = respJson['message'] ?? 'Failed to initialize payment.';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Payment init error: $msg')),
          );
        }
        return;
      }

      // ---------- 4) Open checkout URL ----------
      final uri = Uri.parse(authUrl.toString());
      try {
        bool launched =
            await launchUrl(uri, mode: LaunchMode.externalApplication);

        // fallback: use platform default if external app not available
        if (!launched) {
          launched = await launchUrl(uri, mode: LaunchMode.platformDefault);
        }

        if (!launched) {
          // don't delete draft — allow user to retry manually later
          throw 'No browser available to open Paystack checkout.';
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text(
                    'Payment page opened. After paying, tap Verify to publish your gist.')),
          );
        }

        // Prompt the user to verify the payment using the reference and the draft id
        // (this uses your _promptVerify implementation)
        await _promptVerify(reference, draftGistId, numDays);
      } catch (e) {
        // do not aggressively delete draft here: allow user to retry verification
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open the payment page: $e')),
          );
        }
      }
    } catch (e) {
      // try to clean up draft if created and error is terminal
      if (draftGistId != null) {
        try {
          await Supabase.instance.client
              .from('gists')
              .delete()
              .eq('id', draftGistId);
        } catch (_) {}
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to submit gist: ${e.toString()}')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  /// Add these imports at top if not already present
// import 'package:flutter_dotenv/flutter_dotenv.dart';
// import 'package:http/http.dart' as http;
// import 'dart:convert';
// import 'package:supabase_flutter/supabase_flutter.dart';

  /// Verify payment with Paystack and patch the gist row in Supabase.
  /// Returns true if payment verified and DB patched.
  /// amountPaidUnit: the amount Paystack returned (lowest currency unit, e.g., kobo)
  Future<bool> _verifyPayment(
      String reference, String gistId, int numberOfDays) async {
    final paystackSecretKey = dotenv.env['PAYSTACK_SECRET_KEY'];
    if (paystackSecretKey == null || paystackSecretKey.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Missing Paystack secret key')),
        );
      }
      return false;
    }

    try {
      // 1) Call Paystack verify endpoint
      final verifyUrl =
          Uri.parse('https://api.paystack.co/transaction/verify/$reference');
      final resp = await http.get(
        verifyUrl,
        headers: {
          'Authorization': 'Bearer $paystackSecretKey',
          'Content-Type': 'application/json',
        },
      );

      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        // not verified
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content:
                    Text('Payment verification failed (${resp.statusCode})')),
          );
        }
        return false;
      }

      final Map<String, dynamic> body =
          jsonDecode(resp.body) as Map<String, dynamic>? ?? {};
      final bool ok =
          body['status'] == true || body['status']?.toString() == 'true';
      final data = body['data'] as Map<String, dynamic>?;

      if (!ok || data == null) {
        if (mounted) {
          final msg = body['message'] ?? 'Verification failed';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Paystack verify error: $msg')),
          );
        }
        return false;
      }

      // Paystack success statuses: check data['status'] == 'success'
      final txStatus = data['status']?.toString() ?? '';
      if (txStatus.toLowerCase() != 'success') {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Transaction not successful: $txStatus')),
          );
        }
        return false;
      }

      final amountPaid = (data['amount'] is int)
          ? data['amount'] as int
          : int.tryParse('${data['amount']}') ?? 0;
      final paymentRef = data['reference'] ?? reference;

      // 2) Compute end_date from now or from start_date+numberOfDays.
      // We'll set end_date = now + numberOfDays days (timestamp)
      // Optionally you can prefer the stored start_date if you set it earlier.
      final now = DateTime.now().toUtc();
      final endDate = now.add(Duration(days: numberOfDays));

      // 3) Patch gist row in Supabase using service role key (client-side we use anon key; patch allowed if policies permit)
      // Prefer using authenticated update (user must be owner) — here we update paid/status/payment_reference/amount_paid/end_date.
      final supabase = Supabase.instance.client;

      final updatePayload = {
        'paid': true,
        'status': 'active',
        'payment_reference': paymentRef,
        'amount_paid': amountPaid,
        'end_date': endDate.toIso8601String(),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      };

      final updateResp = await supabase
          .from('gists')
          .update(updatePayload)
          .eq('id', gistId)
          .select()
          .maybeSingle();

      // Accept a variety of driver responses - success if no exception thrown.
      // If the update failed (null response or error), handle gracefully:
      if (updateResp == null) {
        // Could still be success server-side but driver returned null; check by fetching row.
        final check = await supabase
            .from('gists')
            .select('paid, status')
            .eq('id', gistId)
            .maybeSingle();
        if (check == null || (check is Map && check['paid'] != true)) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                  content: Text('Failed to update gist after verification.')),
            );
          }
          return false;
        }
      }

      // success
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Payment verified — gist is now active!')),
        );
      }

      // NEW: invoke Edge Function here
      try {
        final fn = supabase.functions;
        final gistType = (await supabase
                .from('gists')
                .select('type')
                .eq('id', gistId)
                .maybeSingle())?['type'] ??
            'global';
        await fn.invoke('send-push-for-gist', body: {
          'gistId': gistId.toString(),
          'title': 'New gist published!',
          'body': 'Check out the latest gist on Allowance.',
          'type': gistType,
        });
      } catch (e) {
        developer.log('Error invoking Edge Function: $e', name: 'fcm');
        // non-fatal: continue even if notify fails
      }

      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Verification error: ${e.toString()}')),
        );
      }
      return false;
    }
  }

  /// After launching the checkout URL, call this to prompt the user to Verify (simple UI).
  Future<void> _promptVerify(
      String reference, String gistId, int numberOfDays) async {
    // show dialog with Verify button
    final didVerify = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Complete Payment'),
        content: const Text(
            'After completing payment in the browser, tap "Verify" to confirm and publish your gist.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Verify Payment'),
          ),
        ],
      ),
    );

    if (didVerify == true) {
      // show a loading indicator while verifying
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(child: CircularProgressIndicator()),
      );
      final ok = await _verifyPayment(reference, gistId, numberOfDays);
      if (mounted) Navigator.of(context).pop(); // remove loading
      if (!ok) {
        // let user retry
        final retry = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Verification failed'),
            content: const Text('Could not verify payment. Try again?'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('No')),
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Retry')),
            ],
          ),
        );
        if (retry == true) {
          await _promptVerify(reference, gistId, numberOfDays);
        }
      } else {
        // good — pop screen or refresh feed
        // you might navigate back or refresh HomeScreen
        if (mounted) {
          Navigator.of(context)
              .pop(); // close gist submission screen if desired
        }
      }
    } else {
      // user cancelled verify — do nothing. Consider deleting draft after X minutes on server.
    }
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
                  decoration: InputDecoration(
                    labelText: 'Type of Gist',
                    labelStyle: const TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: fieldFill,
                    border: OutlineInputBorder(
                        borderSide: BorderSide(color: widget.themeColor)),
                  ),
                  items: _typeMap.keys
                      .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                      .toList(),
                  value: _selectedGistType,
                  onChanged: (v) =>
                      mounted ? setState(() => _selectedGistType = v) : null,
                  validator: (v) => v == null ? 'Select a gist type' : null,
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
                          return DropdownMenuItem(value: id, child: Text(name));
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
                  Image.file(File(_pickedImage!.path), height: 120),
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
