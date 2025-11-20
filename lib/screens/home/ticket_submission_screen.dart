// lib/screens/home/ticket_submission_screen.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class TicketSubmissionScreen extends StatefulWidget {
  final Color themeColor;
  final int? schoolId;

  const TicketSubmissionScreen({
    super.key,
    required this.themeColor,
    required this.schoolId,
  });

  @override
  State<TicketSubmissionScreen> createState() => _TicketSubmissionScreenState();
}

class _TicketSubmissionScreenState extends State<TicketSubmissionScreen> {
  final _formKey = GlobalKey<FormState>();

  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _locationController = TextEditingController();
  final _organizersController = TextEditingController();
  final _organizersEmailController = TextEditingController();
  final _organizersWhatsappController = TextEditingController();
  final _ticketsController = TextEditingController();
  final _priceController = TextEditingController();

  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  XFile? _pickedImage;
  bool _isSubmitting = false;

  static const int _minTickets = 100;
  static const int _platformFee = 100; // for disclaimer only

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _locationController.dispose();
    _organizersController.dispose();
    _organizersEmailController.dispose();
    _organizersWhatsappController.dispose();
    _ticketsController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final image =
        await picker.pickImage(source: ImageSource.gallery, imageQuality: 80);
    if (image != null && mounted) {
      setState(() => _pickedImage = image);
    }
  }

  String _formatDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

  Future<void> _selectDate(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: DateTime(now.year + 2),
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.dark(primary: widget.themeColor),
        ),
        child: child!,
      ),
    );
    if (picked != null && mounted) setState(() => _selectedDate = picked);
  }

  Future<void> _selectTime(BuildContext context) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      builder: (ctx, child) => Theme(data: ThemeData.dark(), child: child!),
    );
    if (picked != null && mounted) setState(() => _selectedTime = picked);
  }

  /// Uploads the picked image to Supabase Storage and returns a public URL.
  /// Fully defensive: supports uploadBinary, file fallback, and all publicUrl shapes.
  Future<String> _uploadImageAndGetPublicUrl({
    required String bucket,
    required String path,
  }) async {
    final supabase = Supabase.instance.client;

    // 1. Read file bytes (works for Android content URIs)
    final Uint8List bytes = await _pickedImage!.readAsBytes();

    bool uploaded = false;

    // 2. Attempt uploadBinary first (new SDKs)
    try {
      await supabase.storage.from(bucket).uploadBinary(
            path,
            bytes,
            fileOptions: const FileOptions(upsert: false),
          );
      uploaded = true;
    } catch (eBinary) {
      // 3. Fallback to File upload (older SDKs)
      try {
        final file = File(_pickedImage!.path);
        await supabase.storage.from(bucket).upload(
              path,
              file,
              fileOptions: const FileOptions(upsert: false),
            );
        uploaded = true;
      } catch (eFile) {
        throw Exception(
          'Upload failed.\nBinary error: $eBinary\nFile error: $eFile',
        );
      }
    }

    if (!uploaded) {
      throw Exception('Upload did not complete.');
    }

    // 4. Get the public URL (different SDKs return different shapes)
    dynamic resp;

    try {
      resp = supabase.storage.from(bucket).getPublicUrl(path);
    } catch (e) {
      throw Exception('getPublicUrl() failed: $e');
    }

    String publicUrl = '';

    // Case 1 — String
    if (resp is String) {
      publicUrl = resp;
    }

    // Case 2 — Map (SDK variant: {"publicUrl": "..."} or {"data": {"publicUrl": "..."}})
    else if (resp is Map) {
      try {
        final map = resp;

        // Try publicUrl
        if (map['publicUrl'] != null) {
          publicUrl = map['publicUrl'].toString();
        }
        // Try nested data.publicUrl
        else if (map['data'] is Map &&
            (map['data'] as Map)['publicUrl'] != null) {
          publicUrl = (map['data'] as Map)['publicUrl'].toString();
        }
        // Try uppercase variants
        else if (map['publicURL'] != null) {
          publicUrl = map['publicURL'].toString();
        } else if (map['data'] is Map &&
            (map['data'] as Map)['publicURL'] != null) {
          publicUrl = (map['data'] as Map)['publicURL'].toString();
        }
        // Worst case — stringified map
        else {
          publicUrl = map.toString();
        }
      } catch (eMap) {
        throw Exception('Unexpected getPublicUrl() map format: $eMap');
      }
    }

    // Case 3 — Other object → toString fallback
    else if (resp != null) {
      publicUrl = resp.toString();
    }

    if (publicUrl.isEmpty) {
      throw Exception('Public URL is empty. Raw response: $resp');
    }

    return publicUrl;
  }

  Future<void> _submitTicket() async {
    if (!_formKey.currentState!.validate() ||
        _pickedImage == null ||
        _selectedDate == null ||
        _selectedTime == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Please fill out all required fields and upload an event poster.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final ticketsCount = int.tryParse(_ticketsController.text.trim()) ?? -1;
    if (ticketsCount < _minTickets) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('The minimum number of tickets is $_minTickets.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final pricePerTicket = double.tryParse(_priceController.text.trim()) ?? -1;
    if (pricePerTicket <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid ticket price.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please log in to create a ticket.')),
      );
      return;
    }

    if (widget.schoolId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('School ID not found. Please try again.')),
      );
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      // Upload event image
      const bucket = 'event-images';
      final ext = _pickedImage!.name.split('.').last;
      final uuid = const Uuid().v4();
      final path = 'events/$uuid.$ext';

      // Upload and get a public URL (throws if fails)
      final publicUrl =
          await _uploadImageAndGetPublicUrl(bucket: bucket, path: path);

      // Insert event directly (no Paystack)
      final dateString = _formatDate(_selectedDate!);
      final timeString =
          '${_selectedTime!.hour.toString().padLeft(2, '0')}:${_selectedTime!.minute.toString().padLeft(2, '0')}:00';

      final payload = {
        'school_id': widget.schoolId,
        'user_id': user.id,
        'name': _nameController.text.trim(),
        'description': _descriptionController.text.trim(),
        'date': dateString,
        'time': timeString,
        'location': _locationController.text.trim(),
        'organizers': _organizersController.text.trim(),
        'organizers_email': _organizersEmailController.text.trim(),
        'organizers_whatsapp': _organizersWhatsappController.text.trim(),
        'tickets_remaining': ticketsCount,
        'price': pricePerTicket,
        'photo_url': publicUrl,
        'paid': true,
        'status': 'active',
      };

      // INSERT + GET ID + SEND PUSH NOTIFICATION TO EVERYONE
      final insertResp = await supabase
          .from('tickets')
          .insert(payload)
          .select('id')
          .maybeSingle();

      final ticketId = insertResp?['id']?.toString();

      if (ticketId != null) {
        supabase.functions.invoke('send-push-for-gist', body: {
          'type': 'ticket',
          'ticketId': ticketId,
        }); // fire and forget – we don't care if it fails
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Ticket created successfully! Everyone just got notified 🔥'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 4),
          ),
        );
        Navigator.pop(context, true);
      }
    } catch (e, st) {
      // Show a friendly message and log the stacktrace for adb logcat
      debugPrint('Ticket submit error: $e\n$st');
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sorry, something went wrong: $e')));
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bg = Colors.grey[900];
    final fieldFill = Colors.grey[850];

    return Theme(
      data: ThemeData.dark().copyWith(scaffoldBackgroundColor: bg),
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: Image.asset('assets/images/tickets.png', height: 90),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16.0),
            child: Form(
              key: _formKey,
              child: Column(
                children: [
                  TextFormField(
                    controller: _nameController,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Event Name',
                      filled: true,
                      fillColor: fieldFill,
                    ),
                    validator: (v) =>
                        v!.isEmpty ? 'Please enter the event name.' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _descriptionController,
                    maxLines: 3,
                    style: const TextStyle(color: Colors.white70),
                    decoration: InputDecoration(
                      labelText: 'Description (Optional)',
                      filled: true,
                      fillColor: fieldFill,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        decoration: InputDecoration(
                          labelText: _selectedDate == null
                              ? 'Select Date'
                              : 'Date: ${_formatDate(_selectedDate!)}',
                          filled: true,
                          fillColor: fieldFill,
                        ),
                        readOnly: true,
                        onTap: () => _selectDate(context),
                        validator: (v) => _selectedDate == null
                            ? 'Please select a date.'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        decoration: InputDecoration(
                          labelText: _selectedTime == null
                              ? 'Select Time'
                              : 'Time: ${_selectedTime!.format(context)}',
                          filled: true,
                          fillColor: fieldFill,
                        ),
                        readOnly: true,
                        onTap: () => _selectTime(context),
                        validator: (v) => _selectedTime == null
                            ? 'Please select a time.'
                            : null,
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _locationController,
                    style: const TextStyle(color: Colors.white70),
                    decoration: InputDecoration(
                      labelText: 'Location',
                      filled: true,
                      fillColor: fieldFill,
                    ),
                    validator: (v) =>
                        v!.isEmpty ? 'Please enter the location.' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _organizersController,
                    style: const TextStyle(color: Colors.white70),
                    decoration: InputDecoration(
                      labelText: 'Organizer Name',
                      filled: true,
                      fillColor: fieldFill,
                    ),
                    validator: (v) =>
                        v!.isEmpty ? 'Please enter the organizer name.' : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _organizersEmailController,
                    style: const TextStyle(color: Colors.white70),
                    decoration: InputDecoration(
                      labelText: 'Organizer Email',
                      filled: true,
                      fillColor: fieldFill,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _organizersWhatsappController,
                    style: const TextStyle(color: Colors.white70),
                    decoration: InputDecoration(
                      labelText: 'Organizer WhatsApp',
                      filled: true,
                      fillColor: fieldFill,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(
                      child: TextFormField(
                        controller: _priceController,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: Colors.white70),
                        decoration: InputDecoration(
                          labelText: 'Ticket Price (₦)',
                          filled: true,
                          fillColor: fieldFill,
                        ),
                        validator: (v) => double.tryParse(v ?? '') == null
                            ? 'Please enter a valid price.'
                            : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: _ticketsController,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(color: Colors.white70),
                        decoration: InputDecoration(
                          labelText: 'Tickets Available',
                          filled: true,
                          fillColor: fieldFill,
                        ),
                        validator: (v) {
                          final n = int.tryParse(v ?? '');
                          return (n == null || n < _minTickets)
                              ? 'Minimum $_minTickets tickets required.'
                              : null;
                        },
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.grey[850],
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      'Disclaimer: Allowance takes ₦$_platformFee per ticket sold. Minimum ticket supply is $_minTickets.',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.image, color: Colors.white),
                    label: Text(
                      _pickedImage == null ? 'Upload Poster' : 'Change Poster',
                      style: const TextStyle(color: Colors.white),
                    ),
                    onPressed: _pickImage,
                  ),
                  if (_pickedImage != null) ...[
                    const SizedBox(height: 8),
                    Image.file(File(_pickedImage!.path),
                        height: MediaQuery.of(context).size.width * 0.6,
                        fit: BoxFit.cover),
                  ],
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isSubmitting ? null : _submitTicket,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: widget.themeColor,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      child: _isSubmitting
                          ? const CircularProgressIndicator(color: Colors.white)
                          : const Text('Create Ticket'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
