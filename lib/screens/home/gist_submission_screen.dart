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
  final _durationController = TextEditingController();
  final _urlController = TextEditingController();
  final _couponController = TextEditingController();
  Map<String, dynamic>? _appliedCoupon;
  bool _isVerifyingCoupon = false;

  late Future<List<Map<String, dynamic>>> _schoolsFuture;
  bool _isSubmitting = false;
  final List<XFile> _pickedImages = [];
  final List<Uint8List> _pickedImageBytes = [];
  List<XFile> _pickedVideos = []; // ← NEW
  bool _isVideoMode = false;
  bool _isPlusMember = false;

  String? _selectedCategory;
  final categories = ['Sports', 'Entertainment', 'Official', 'Religion'];

  @override
  void initState() {
    super.initState();
    _selectedSchoolId = widget.schoolId;
    _schoolsFuture = _fetchSchools();
    _recoverPendingGistPayment();
    _checkPlusStatus();
  }

  Future<void> _checkPlusStatus() async {
    final user = Supabase.instance.client.auth.currentUser;
    if (user != null) {
      try {
        final data = await Supabase.instance.client
            .from('profiles')
            .select('subscription_tier')
            .eq('id', user.id)
            .maybeSingle();
        if (mounted && data != null) {
          setState(() {
            _isPlusMember = data['subscription_tier'] == 'Membership';
          });
        }
      } catch (_) {}
    }
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

  double get _basePrice {
    final days = int.tryParse(_durationController.text) ?? 0;
    return _pricePerDay * days;
  }

  // --- UPDATED: Calculates discount dynamically ---
  double get _estimatedPrice {
    double base = _basePrice;
    if (_appliedCoupon != null) {
      int discount = _appliedCoupon!['discount_percentage'] as int? ?? 0;
      return base * (1 - (discount / 100));
    }
    return base;
  }

  // --- NEW: COUPON LOGIC ---
  Future<void> _verifyAndApplyCoupon(String code) async {
    if (code.isEmpty) {
      setState(() => _appliedCoupon = null);
      return;
    }

    setState(() => _isVerifyingCoupon = true);

    try {
      final data = await Supabase.instance.client
          .from('allowance_coupons')
          .select('*')
          .eq('code', code.trim())
          .maybeSingle();

      if (data == null) throw 'Invalid coupon code';
      if (data['is_active'] == false) throw 'This coupon is disabled';

      final expiry = DateTime.parse(data['expires_at']).toLocal();
      if (DateTime.now().isAfter(expiry)) throw 'This coupon has expired';

      final limit = data['claim_limit'] as int;
      final claimed = data['claimed_count'] as int;
      if (limit != -1 && claimed >= limit) throw 'Coupon supply exhausted';

      // Valid! Apply it.
      setState(() {
        _appliedCoupon = data;
        _isVerifyingCoupon = false;
      });

      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${data['discount_percentage']}% Discount Applied! 🎉'),
          backgroundColor: Colors.green));
    } catch (e) {
      setState(() {
        _appliedCoupon = null;
        _isVerifyingCoupon = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString()), backgroundColor: Colors.red));
    }
  }

  void _showCouponInfoSheet() {
    if (_appliedCoupon == null) return;

    final expiry = DateTime.parse(_appliedCoupon!['expires_at']).toLocal();
    final expiryString = '${expiry.day}/${expiry.month}/${expiry.year}';
    final limit = _appliedCoupon!['claim_limit'] as int;
    final claimed = _appliedCoupon!['claimed_count'] as int;
    final supplyLeft =
        limit == -1 ? 'Unlimited' : '${limit - claimed} remaining';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Coupon Details 🎟️',
                  style: TextStyle(
                      color: widget.themeColor,
                      fontSize: 20,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              _buildCouponDetailRow('Code:', _appliedCoupon!['code']),
              _buildCouponDetailRow('Discount:',
                  '${_appliedCoupon!['discount_percentage']}% OFF'),
              _buildCouponDetailRow('Supply Left:', supplyLeft),
              _buildCouponDetailRow('Expires:', expiryString),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                      backgroundColor: widget.themeColor),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Close',
                      style: TextStyle(
                          color: Colors.black, fontWeight: FontWeight.bold)),
                ),
              )
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCouponDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 16)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _couponController.dispose();
    super.dispose();
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

  Future<void> _pickImages() async {
    if (_isVideoMode || _pickedVideos.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Cannot mix images and video in one gist')),
      );
      return;
    }
    if (_pickedImages.length >= 3) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Maximum 3 images allowed')),
      );
      return;
    }

    final picker = ImagePicker();
    final picked =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (picked == null || !mounted) return;

    Uint8List? bytes;
    if (kIsWeb) bytes = await picked.readAsBytes();

    setState(() {
      _pickedImages.add(picked);
      if (bytes != null) _pickedImageBytes.add(bytes);
    });
  }

  Future<void> _pickVideo() async {
    if (_pickedImages.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Cannot mix images and video in one gist')),
      );
      return;
    }

    final picker = ImagePicker();
    final picked = await picker.pickVideo(source: ImageSource.gallery);
    if (picked == null || !mounted) return;

    setState(() {
      _pickedVideos = [picked];
      _isVideoMode = true;
    });
  }

  void _removeImage(int index) {
    setState(() {
      _pickedImages.removeAt(index);
      if (kIsWeb) _pickedImageBytes.removeAt(index);
    });
  }

  // ==================== RECOVERY (updated for full safety) ====================
  Future<void> _recoverPendingGistPayment() async {
    final prefs = await SharedPreferences.getInstance();
    final pendingJson = prefs.getString('pending_gist_payment');
    if (pendingJson == null) return;

    final data = jsonDecode(pendingJson);
    final String reference = data['reference'] as String;
    final int gistId = data['gistId'] as int;
    final String gateway = data['gateway'] ?? 'paystack';
    final int numDays = data['numberOfDays'] as int? ?? 1;

    setState(() => _isSubmitting = true);

    final success =
        await _pollAndVerifyGistPayment(reference, gateway, gistId, numDays);

    if (success) {
      await prefs.remove('pending_gist_payment');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('✅ Gist payment recovered and published!'),
            backgroundColor: Colors.green));
        Navigator.of(context).pop();
      }
    }
    if (mounted) setState(() => _isSubmitting = false);
  }

  // ==================== MAIN SUBMIT (auto-verification) ====================
  Future<void> _submitGist() async {
    if (!_formKey.currentState!.validate() ||
        (_pickedImages.isEmpty && _pickedVideos.isEmpty) ||
        _selectedGistType == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Complete form & pick at least one image or video')));
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
    bool paymentLaunched = false;

    try {
      // 1. UPLOAD MEDIA (Your existing upload code here...)
      const bucket = 'gist-images';
      final List<String> uploadedUrls = [];
      final List<String> uploadedPaths = [];
      String mediaType = 'image';

      if (_pickedVideos.isNotEmpty) {
        mediaType = 'video';
        final video = _pickedVideos.first;
        final ext = video.name.split('.').last.toLowerCase();
        final filePath = 'gists/${const Uuid().v4()}.$ext';

        if (kIsWeb) {
          final bytes = await video.readAsBytes();
          await supabase.storage.from(bucket).uploadBinary(filePath, bytes,
              fileOptions: FileOptions(contentType: 'video/$ext'));
        } else {
          final file = File(video.path);
          await supabase.storage.from(bucket).upload(filePath, file);
        }
        uploadedUrls.add(supabase.storage.from(bucket).getPublicUrl(filePath));
        uploadedPaths.add(filePath);
      } else {
        for (int i = 0; i < _pickedImages.length; i++) {
          final image = _pickedImages[i];
          final ext = image.name.split('.').last;
          final filePath = 'gists/${const Uuid().v4()}.$ext';

          if (kIsWeb) {
            final bytes = await image.readAsBytes();
            await supabase.storage.from(bucket).uploadBinary(filePath, bytes,
                fileOptions: const FileOptions(contentType: 'image/*'));
          } else {
            final file = File(image.path);
            await supabase.storage.from(bucket).upload(filePath, file);
          }
          uploadedUrls
              .add(supabase.storage.from(bucket).getPublicUrl(filePath));
          uploadedPaths.add(filePath);
        }
      }

      // 2. CREATE DRAFT GIST (Modified for Coupons)
      final numDays = int.tryParse(_durationController.text) ?? 0;
      final pricePerDay = _pricePerDay;
      final totalNaira =
          _estimatedPrice.toInt(); // This uses the discounted price!

      final reference = 'gist_${const Uuid().v4()}';
      final bool is100PercentFree = _appliedCoupon != null &&
          _appliedCoupon!['discount_percentage'] == 100;

      final draftPayload = {
        'user_id': user.id,
        'type': dbType,
        'title': _titleController.text.trim(),
        'image_url': uploadedUrls.first,
        'image_urls': mediaType == 'image' ? uploadedUrls : [],
        'image_path': uploadedPaths.first,
        'media_type': mediaType,
        'number_of_days': numDays,
        'price_per_day': pricePerDay,
        'paid': is100PercentFree, // Instantly paid if 100% discount
        'status': is100PercentFree ? 'active' : 'draft',
        'start_date': DateTime.now().toUtc().toIso8601String().split('T').first,
        'category': _selectedCategory,
        'payment_reference':
            is100PercentFree ? 'coupon_${_appliedCoupon!['code']}' : reference,
      };

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

      // INCREMENT COUPON COUNT IF APPLIED
      if (_appliedCoupon != null) {
        await supabase.rpc('increment_coupon',
            params: {'p_code': _appliedCoupon!['code']});
      }

      // --- 100% DISCOUNT BYPASS ---
      if (is100PercentFree) {
        if (mounted) {
          setState(() => _isSubmitting = false);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: const Text('✅ Gist published automatically via Coupon!'),
              backgroundColor: widget.themeColor));
          Navigator.of(context).pop();
        }
        return; // Stop execution, no payment gateway needed!
      }

      // Safeguard for 0 days input
      if (totalNaira <= 0) {
        await supabase.from('gists').delete().eq('id', draftGistId);
        return;
      }

      // 3. INITIALIZE PAYMENT (Flutterwave Primary, Paystack Backup)
      String gateway = 'flutterwave';
      String? authUrlString;

      try {
        final flwResp = await supabase.functions.invoke(
          'flutterwave-init',
          body: {
            'tx_ref': reference,
            'amount': totalNaira.toString(), // Passes the reduced amount!
            'currency': 'NGN',
            'redirect_url': 'https://allowanceapp.org',
            'customer': {'email': user.email ?? 'user@allowance.com'},
            'meta': {'gist_id': draftGistId.toString()},
            'customizations': {
              'title': 'Gist Promotion',
              'description': 'Paying for Ad'
            }
          },
        );
        final data =
            flwResp.data is String ? jsonDecode(flwResp.data) : flwResp.data;
        if (flwResp.status == 200 && data != null && data['data'] != null) {
          authUrlString = data['data']['link'];
        } else {
          throw 'Flutterwave failed';
        }
      } catch (e) {
        gateway = 'paystack';
        try {
          final payResp = await supabase.functions.invoke(
            'paystack-init',
            body: {
              'amount': totalNaira * 100, // Paystack is Kobo
              'email': user.email ?? 'user@allowance.com',
              'reference': reference,
              'metadata': {'gist_id': draftGistId.toString()}
            },
          );
          final data =
              payResp.data is String ? jsonDecode(payResp.data) : payResp.data;
          if (payResp.status == 200 && data != null && data['data'] != null) {
            authUrlString = data['data']['authorization_url'];
          } else {
            throw 'Paystack failed';
          }
        } catch (err) {
          await supabase.from('gists').delete().eq('id', draftGistId);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Payment gateways offline. Try again later.'),
                backgroundColor: Colors.red));
          }
          return;
        }
      }

      // 4. SAVE PREFS AND LAUNCH URL (Exactly the same)
      paymentLaunched = true;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'pending_gist_payment',
          jsonEncode({
            'reference': reference,
            'gateway': gateway,
            'gistId': draftGistId,
            'numberOfDays': numDays,
          }));

      if (authUrlString != null) {
        final uri = Uri.parse(authUrlString);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri,
              mode: kIsWeb
                  ? LaunchMode.externalApplication
                  : LaunchMode.inAppBrowserView);

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text('Payment opened! Verifying in the background...'),
                backgroundColor: Colors.blueAccent,
                duration: Duration(seconds: 6)));
          }
        }
      }

      _pollAndVerifyGistPayment(reference, gateway, draftGistId, numDays)
          .then((success) async {
        if (success) await prefs.remove('pending_gist_payment');
      });

      if (mounted) {
        setState(() => _isSubmitting = false);
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (draftGistId != null && !paymentLaunched) {
        try {
          await supabase.from('gists').delete().eq('id', draftGistId);
        } catch (_) {}
      }
      if (mounted)
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<bool> _pollAndVerifyGistPayment(
      String reference, String gateway, int gistId, int numDays) async {
    final prefs = await SharedPreferences.getInstance();
    int savedDays = numDays;

    try {
      final pendingJson = prefs.getString('pending_gist_payment');
      if (pendingJson != null) {
        savedDays =
            (jsonDecode(pendingJson)['numberOfDays'] as num?)?.toInt() ??
                savedDays;
      }
    } catch (_) {}

    for (int attempt = 0; attempt < 15; attempt++) {
      try {
        final funcResp = await Supabase.instance.client.functions.invoke(
          'verify-payment',
          body: {'reference': reference, 'gateway': gateway},
        );

        final data =
            funcResp.data is String ? jsonDecode(funcResp.data) : funcResp.data;

        if (funcResp.status == 200 && data != null) {
          bool isSuccess = false;
          int amountPaid = 0;

          if (gateway == 'paystack' &&
              data['status'] == true &&
              data['data']?['status'] == 'success') {
            isSuccess = true;
            amountPaid = data['data']['amount'] as int;
          } else if (gateway == 'flutterwave' &&
              data['status'] == 'success' &&
              data['data']?['status'] == 'successful') {
            isSuccess = true;
            amountPaid = (data['data']['amount'] as num).toInt() * 100;
          }

          if (isSuccess) {
            await Supabase.instance.client.from('gists').update({
              'paid': true,
              'status': 'active',
              'payment_reference': reference,
              'amount_paid': amountPaid,
              'end_date': DateTime.now()
                  .add(Duration(days: savedDays))
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
                // Gist Type
                DropdownButtonFormField<String>(
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
                            child: Text(g,
                                style: const TextStyle(color: Colors.white)),
                          ))
                      .toList(),
                  value: _selectedGistType,
                  onChanged: (v) =>
                      mounted ? setState(() => _selectedGistType = v) : null,
                  validator: (v) => v == null ? 'Select a gist type' : null,
                  dropdownColor: Colors.grey[850],
                ),
                const SizedBox(height: 12),

                // Category
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

                // School (for Local Gist)
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
                            child: Text(name,
                                style: const TextStyle(color: Colors.white)),
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

                // TITLE
                TextFormField(
                  controller: _titleController,
                  maxLength: 2000,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
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

                // Optional URL
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
                    if (uri == null || (!uri.hasScheme)) {
                      return 'Enter a valid URL (include https://)';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),

                // Duration
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

                // --- NEW: COUPON INPUT (LOCKED FOR FREE USERS) ---
                TextFormField(
                  controller: _couponController,
                  style: TextStyle(
                      color: _isPlusMember ? Colors.white : Colors.white38),
                  readOnly:
                      !_isPlusMember, // <-- Locks keyboard from opening if free
                  onTap: () {
                    if (!_isPlusMember) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text(
                            '🔒 Only Allowance Plus ✨ members can use promo codes.'),
                        backgroundColor: Colors.orange,
                      ));
                    }
                  },
                  decoration: InputDecoration(
                    labelText: _isPlusMember
                        ? 'Coupon Code (Optional)'
                        : 'Coupon Code (Plus Members Only 🔒)',
                    labelStyle: const TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: fieldFill,
                    border: OutlineInputBorder(
                        borderSide: BorderSide(color: widget.themeColor)),
                    suffixIcon: !_isPlusMember
                        ? const Icon(Icons.lock,
                            color: Colors.white38) // Show lock icon
                        : _isVerifyingCoupon
                            ? const Padding(
                                padding: EdgeInsets.all(12.0),
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : IconButton(
                                icon: Icon(
                                    _appliedCoupon != null
                                        ? Icons.check_circle
                                        : Icons.info_outline,
                                    color: _appliedCoupon != null
                                        ? widget.themeColor
                                        : Colors.white54),
                                onPressed: () {
                                  if (_appliedCoupon != null) {
                                    _showCouponInfoSheet();
                                  } else if (_couponController.text
                                          .trim()
                                          .length >=
                                      6) {
                                    _verifyAndApplyCoupon(
                                        _couponController.text);
                                  }
                                },
                              ),
                  ),
                  onChanged: (val) {
                    if (!_isPlusMember) return;
                    // Auto-verify if they type exactly 6 chars
                    if (val.trim().length == 6) {
                      _verifyAndApplyCoupon(val);
                    } else if (_appliedCoupon != null &&
                        val.trim().length != 6) {
                      // Remove coupon if they start deleting the code
                      setState(() => _appliedCoupon = null);
                    }
                  },
                ),
                const SizedBox(height: 20),

                // ====================== MEDIA PICKER (Images + Video) ======================
                const Text('Media (Images or 1 Video)',
                    style: TextStyle(color: Colors.white70, fontSize: 16)),
                const SizedBox(height: 8),

                // Preview area
                if (_pickedImages.isNotEmpty || _pickedVideos.isNotEmpty)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      // Images
                      ...List.generate(_pickedImages.length, (i) {
                        return Stack(
                          children: [
                            kIsWeb
                                ? Image.memory(_pickedImageBytes[i],
                                    height: 100, width: 100, fit: BoxFit.cover)
                                : Image.file(File(_pickedImages[i].path),
                                    height: 100, width: 100, fit: BoxFit.cover),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: GestureDetector(
                                onTap: () => _removeImage(i),
                                child: const CircleAvatar(
                                  radius: 12,
                                  backgroundColor: Colors.red,
                                  child: Icon(Icons.close,
                                      size: 16, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        );
                      }),

                      // Video preview
                      if (_pickedVideos.isNotEmpty)
                        Stack(
                          children: [
                            Container(
                              height: 100,
                              width: 100,
                              decoration: BoxDecoration(
                                color: Colors.black,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Center(
                                child: Icon(Icons.play_circle_fill,
                                    size: 50, color: Colors.white70),
                              ),
                            ),
                            Positioned(
                              top: 4,
                              right: 4,
                              child: GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _pickedVideos.clear();
                                    _isVideoMode = false;
                                  });
                                },
                                child: const CircleAvatar(
                                  radius: 12,
                                  backgroundColor: Colors.red,
                                  child: Icon(Icons.close,
                                      size: 16, color: Colors.white),
                                ),
                              ),
                            ),
                            const Positioned(
                              bottom: 6,
                              left: 6,
                              child: Text('VIDEO',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ],
                        ),
                    ],
                  ),

                const SizedBox(height: 12),

                // Buttons
                Row(
                  children: [
                    // Add Images Button
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.add_photo_alternate,
                            color: Colors.white),
                        label: Text(_pickedImages.length >= 3
                            ? 'Maximum reached (3)'
                            : 'Add Images (${_pickedImages.length}/3)'),
                        style: OutlinedButton.styleFrom(
                            side: BorderSide(color: widget.themeColor),
                            backgroundColor: Colors.transparent),
                        onPressed: (_pickedImages.length >= 3 ||
                                _pickedVideos.isNotEmpty)
                            ? null
                            : _pickImages,
                      ),
                    ),
                    const SizedBox(width: 12),

                    // Add Video Button
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.videocam, color: Colors.white),
                        label: const Text('Add Video'),
                        style: OutlinedButton.styleFrom(
                            side: BorderSide(color: widget.themeColor),
                            backgroundColor: Colors.transparent),
                        onPressed: (_pickedVideos.isNotEmpty ||
                                _pickedImages.isNotEmpty)
                            ? null
                            : _pickVideo,
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // --- UPDATED: Estimated Price (Shows Discount Slash) ---
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Estimated Price:',
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: Colors.white)),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (_appliedCoupon != null && _basePrice > 0)
                          Text('₦${_basePrice.toStringAsFixed(0)}',
                              style: const TextStyle(
                                  fontSize: 14,
                                  decoration: TextDecoration.lineThrough,
                                  color: Colors.redAccent)),
                        Text('₦${_estimatedPrice.toStringAsFixed(0)}',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: widget.themeColor)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // Submit Button
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _isSubmitting ? null : _submitGist,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: widget.themeColor,
                        disabledBackgroundColor: Colors.grey[850],
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(vertical: 8)),
                    child: _isSubmitting
                        ? Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('Uploading Media...',
                                  style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500)),
                              const SizedBox(height: 8),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: const SizedBox(
                                  width: 140,
                                  child: LinearProgressIndicator(
                                    color: Color(0xFF4CAF50),
                                    backgroundColor: Colors.black45,
                                    minHeight: 4,
                                  ),
                                ),
                              ),
                            ],
                          )
                        : const Text('Advertise',
                            style: TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold)),
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
