import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

/// Constants for table and column names
class TicketFields {
  static const table = 'tickets';
  static const schoolId = 'school_id'; // Must match DB exactly
  static const name = 'name';
  static const description = 'description';
  static const date = 'date';
  static const time = 'time';
  static const location = 'location';
  static const organizers = 'organizers';
  static const ticketsRemaining = 'tickets_remaining';
  static const photoUrl = 'photo_url';
  static const createdAt = 'created_at';
}

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
  final _ticketsController = TextEditingController();

  DateTime? _selectedDate;
  TimeOfDay? _selectedTime;
  XFile? _pickedImage;

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final image = await picker.pickImage(source: ImageSource.gallery);
    if (image != null && mounted) {
      setState(() => _pickedImage = image);
    }
  }

  Future<void> _submitTicket() async {
    if (!_formKey.currentState!.validate() ||
        _pickedImage == null ||
        _selectedDate == null ||
        _selectedTime == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Complete all fields & pick an image'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;

    if (user == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('You must be logged in')),
        );
      }
      return;
    }

    if (widget.schoolId == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('School ID not found')),
        );
      }
      return;
    }

    try {
      // Upload image
      const bucket = 'event-images';
      final file = File(_pickedImage!.path);
      final ext = _pickedImage!.path.split('.').last;
      final filePath = 'events/${Uuid().v4()}.$ext'; // ✅ No `const` here

      await supabase.storage.from(bucket).upload(filePath, file);
      final publicUrl = supabase.storage.from(bucket).getPublicUrl(filePath);

      // Format date and time
      final dateString =
          '${_selectedDate!.year}-${_selectedDate!.month.toString().padLeft(2, '0')}-${_selectedDate!.day.toString().padLeft(2, '0')}';
      final timeString =
          '${_selectedTime!.hour.toString().padLeft(2, '0')}:${_selectedTime!.minute.toString().padLeft(2, '0')}';

      final data = <String, dynamic>{
        TicketFields.schoolId: widget.schoolId,
        TicketFields.name: _nameController.text,
        TicketFields.description: _descriptionController.text,
        TicketFields.date: dateString,
        TicketFields.time: timeString,
        TicketFields.location: _locationController.text,
        TicketFields.organizers: _organizersController.text,
        TicketFields.ticketsRemaining: int.parse(_ticketsController.text),
        TicketFields.photoUrl: publicUrl,
      };

      await supabase.from(TicketFields.table).insert(data);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ticket submitted successfully!'),
            backgroundColor: Colors.green,
          ),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to submit ticket: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
      debugPrint('Ticket submission error: $e');
    }
  }

  Future<void> _selectDate(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: now,
      firstDate: now,
      lastDate: DateTime(now.year + 1),
    );
    if (picked != null && mounted) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _selectTime(BuildContext context) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
    );
    if (picked != null && mounted) {
      setState(() => _selectedTime = picked);
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
          'assets/images/tickets.png',
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
                TextFormField(
                  controller: _nameController,
                  maxLength: 100,
                  decoration: InputDecoration(
                    labelText: 'Event Name',
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: widget.themeColor),
                    ),
                  ),
                  validator: (v) =>
                      v?.isEmpty ?? true ? 'Enter event name' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _descriptionController,
                  maxLines: 3,
                  decoration: InputDecoration(
                    labelText: 'Description (Optional)',
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: widget.themeColor),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        decoration: InputDecoration(
                          labelText: _selectedDate == null
                              ? 'Select Date'
                              : 'Date: ${_formatDate(_selectedDate!)}',
                          border: OutlineInputBorder(
                            borderSide: BorderSide(color: widget.themeColor),
                          ),
                        ),
                        readOnly: true,
                        onTap: () => _selectDate(context),
                        validator: (v) =>
                            _selectedDate == null ? 'Select date' : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        decoration: InputDecoration(
                          labelText: _selectedTime == null
                              ? 'Select Time'
                              : 'Time: ${_selectedTime!.format(context)}',
                          border: OutlineInputBorder(
                            borderSide: BorderSide(color: widget.themeColor),
                          ),
                        ),
                        readOnly: true,
                        onTap: () => _selectTime(context),
                        validator: (v) =>
                            _selectedTime == null ? 'Select time' : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _locationController,
                  decoration: InputDecoration(
                    labelText: 'Location',
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: widget.themeColor),
                    ),
                  ),
                  validator: (v) =>
                      v?.isEmpty ?? true ? 'Enter location' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _organizersController,
                  decoration: InputDecoration(
                    labelText: 'Organizers',
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: widget.themeColor),
                    ),
                  ),
                  validator: (v) =>
                      v?.isEmpty ?? true ? 'Enter organizers' : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _ticketsController,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Available Tickets',
                    border: OutlineInputBorder(
                      borderSide: BorderSide(color: widget.themeColor),
                    ),
                  ),
                  validator: (v) {
                    final n = int.tryParse(v ?? '');
                    return (n == null || n < 0) ? 'Enter valid number' : null;
                  },
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  icon: const Icon(Icons.image),
                  label: Text(
                    _pickedImage == null ? 'Upload Poster' : 'Change Poster',
                  ),
                  style: OutlinedButton.styleFrom(
                    side: BorderSide(color: widget.themeColor),
                  ),
                  onPressed: _pickImage,
                ),
                if (_pickedImage != null) ...[
                  const SizedBox(height: 8),
                  Image.file(
                    File(_pickedImage!.path),
                    height: MediaQuery.of(context).size.width * 0.6,
                    fit: BoxFit.cover,
                  ),
                ],
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _submitTicket,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.themeColor,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    child: const Text('Create Ticket'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
