// lib/screens/home/create_story_screen.dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../models/user_preferences.dart';

class CreateStoryScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  const CreateStoryScreen({super.key, required this.userPreferences});

  @override
  State<CreateStoryScreen> createState() => _CreateStoryScreenState();
}

class _CreateStoryScreenState extends State<CreateStoryScreen> {
  XFile? _mediaFile;
  Uint8List? _mediaBytes; // ← NEW: We store bytes for Web
  String _mediaType = 'image';
  final _captionController = TextEditingController();
  final _urlController = TextEditingController();
  bool _isUploading = false;

  Future<void> _pickMedia() async {
    final picker = ImagePicker();
    final picked = await picker.pickMedia(
      imageQuality: 85,
    );

    if (picked != null) {
      final bytes = await picked.readAsBytes(); // ← Read bytes once

      setState(() {
        _mediaFile = picked;
        _mediaBytes = bytes;
        _mediaType = picked.name.toLowerCase().contains('.mp4') ||
                picked.name.toLowerCase().contains('.mov')
            ? 'video'
            : 'image';
      });
    }
  }

  Future<void> _postStory() async {
    if (_mediaBytes == null) return;
    setState(() => _isUploading = true);

    final supabase = Supabase.instance.client;
    final bucket = 'gist-images'; // or whatever bucket you use for stories

    try {
      final ext = _mediaFile!.name.split('.').last;
      final path = 'stories/${const Uuid().v4()}.$ext';

      // Upload using bytes (works perfectly on Web + Mobile)
      await supabase.storage.from(bucket).uploadBinary(path, _mediaBytes!);

      final publicUrl = supabase.storage.from(bucket).getPublicUrl(path);

      await supabase.from('stories').insert({
        'user_id': supabase.auth.currentUser!.id,
        'media_url': publicUrl,
        'media_type': _mediaType,
        'caption': _captionController.text.trim(),
        'url': _urlController.text.trim().isEmpty
            ? null
            : _urlController.text.trim(),
      });

      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Story posted successfully! 🎉'),
            backgroundColor: Color(0xFF4CAF50),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Upload failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isPlus = widget.userPreferences.subscriptionTier == 'Membership';

    if (!isPlus) {
      // Paywall remains the same
      return Scaffold(
        backgroundColor: Colors.grey[900],
        appBar: AppBar(
            title: const Text('New Story'), backgroundColor: Colors.grey[900]),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_rounded, size: 80, color: Colors.amber),
                const SizedBox(height: 20),
                const Text('JOIN THE ALLOWANCE PLUS FAMILY',
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                        color: Colors.white)),
                const Text('to post Story Gist',
                    style: TextStyle(fontSize: 18, color: Colors.white70)),
                const SizedBox(height: 30),
                ElevatedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Subscribe to Plus')),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
          title: const Text('New Story'), backgroundColor: Colors.grey[900]),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            GestureDetector(
              onTap: _pickMedia,
              child: Container(
                height: 300,
                width: double.infinity,
                decoration: BoxDecoration(
                  color: Colors.grey[800],
                  borderRadius: BorderRadius.circular(16),
                ),
                child: _mediaBytes == null
                    ? const Center(
                        child: Text('Tap to pick photo or video',
                            style:
                                TextStyle(color: Colors.white70, fontSize: 18)))
                    : _mediaType == 'video'
                        ? const Center(
                            child: Icon(Icons.play_circle,
                                size: 80, color: Colors.white))
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: Image.memory(
                              _mediaBytes!,
                              fit: BoxFit.cover,
                              width: double.infinity,
                              height: 300,
                            ),
                          ),
              ),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _captionController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Caption (optional)',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white54)),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _urlController,
              style: const TextStyle(color: Colors.white),
              decoration: const InputDecoration(
                labelText: 'Optional URL',
                labelStyle: TextStyle(color: Colors.white70),
                enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: Colors.white54)),
              ),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isUploading ? null : _postStory,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4CAF50),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: _isUploading
                    ? const CircularProgressIndicator(color: Colors.white)
                    : const Text('Post Story',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
