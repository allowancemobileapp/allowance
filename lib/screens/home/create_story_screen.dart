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
  Uint8List? _mediaBytes;
  String _mediaType = 'text'; // default = text-only story
  final _captionController = TextEditingController();
  final _urlController = TextEditingController();
  bool _isUploading = false;

  // ==================== PICK MEDIA ====================
  // ==================== PICK MEDIA ====================
  Future<void> _pickMedia() async {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Text Only
              ListTile(
                leading: const Icon(Icons.text_fields, color: Colors.white),
                title: const Text('Text Only',
                    style: TextStyle(color: Colors.white)),
                subtitle: const Text('Post just text & emojis',
                    style: TextStyle(color: Colors.white54)),
                onTap: () {
                  Navigator.pop(context);
                  setState(() {
                    _mediaFile = null;
                    _mediaBytes = null;
                    _mediaType = 'text';
                  });
                },
              ),
              const Divider(color: Colors.grey),

              // === NEW: CAMERA OPTIONS ===
              ListTile(
                leading: const Icon(Icons.camera_alt, color: Colors.white),
                title: const Text('Take Photo',
                    style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(context);
                  final picker = ImagePicker();
                  final picked = await picker.pickImage(
                    source: ImageSource.camera,
                    imageQuality: 85,
                  );
                  if (picked != null) _handlePickedMedia(picked, 'image');
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam, color: Colors.white),
                title: const Text('Record Video',
                    style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(context);
                  final picker = ImagePicker();
                  final picked = await picker.pickVideo(
                    source: ImageSource.camera,
                  );
                  if (picked != null) _handlePickedMedia(picked, 'video');
                },
              ),
              const Divider(color: Colors.grey),

              // Gallery options (kept as before)
              ListTile(
                leading: const Icon(Icons.photo_library, color: Colors.white),
                title: const Text('Pick Photo from Gallery',
                    style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(context);
                  final picker = ImagePicker();
                  final picked = await picker.pickImage(
                    source: ImageSource.gallery,
                    imageQuality: 85,
                  );
                  if (picked != null) _handlePickedMedia(picked, 'image');
                },
              ),
              ListTile(
                leading: const Icon(Icons.video_library, color: Colors.white),
                title: const Text('Pick Video from Gallery',
                    style: TextStyle(color: Colors.white)),
                onTap: () async {
                  Navigator.pop(context);
                  final picker = ImagePicker();
                  final picked = await picker.pickVideo(
                    source: ImageSource.gallery,
                  );
                  if (picked != null) _handlePickedMedia(picked, 'video');
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _handlePickedMedia(XFile picked, String type) async {
    final bytes = await picked.readAsBytes();
    setState(() {
      _mediaFile = picked;
      _mediaBytes = bytes;
      _mediaType = type;
    });
  }

  // ==================== POST STORY ====================
  Future<void> _postStory() async {
    if (_mediaType == 'text' && _captionController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text('Please write something for your text story')),
      );
      return;
    }

    setState(() => _isUploading = true);

    final supabase = Supabase.instance.client;
    final bucket = 'gist-images';

    try {
      String? publicUrl;

      if (_mediaBytes != null) {
        final ext = _mediaFile!.name.split('.').last;
        final path = 'stories/${const Uuid().v4()}.$ext';
        await supabase.storage.from(bucket).uploadBinary(path, _mediaBytes!);
        publicUrl = supabase.storage.from(bucket).getPublicUrl(path);
      }

      await supabase.from('stories').insert({
        'user_id': supabase.auth.currentUser!.id,
        'media_url': publicUrl, // now allowed to be null for text stories
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
            behavior: SnackBarBehavior.floating,
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
      // Paywall (unchanged)
      return Scaffold(
        backgroundColor: Colors.grey[900],
        appBar: AppBar(
            title: const Text('New Story'),
            backgroundColor: Colors.transparent),
        body: Center(/* your paywall UI remains the same */),
      );
    }

    return Scaffold(
      backgroundColor: Colors.grey[900],
      appBar: AppBar(
        title: const Text('New Story',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Preview Box
              // Preview Box
              GestureDetector(
                onTap: _pickMedia,
                child: Container(
                  height: 320,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.grey[850],
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.grey[700]!, width: 2),
                  ),
                  child: _mediaType == 'text' && _mediaBytes == null
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // CHANGED TO CAMERA + ICON
                            const Icon(Icons.add_a_photo,
                                size: 80, color: Colors.white54),
                            const SizedBox(height: 12),
                            const Text('Tap to take photo or video',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 16)),
                          ],
                        )
                      : _mediaType == 'video'
                          ? const Center(
                              child: Icon(Icons.play_circle_fill,
                                  size: 80, color: Colors.white))
                          : _mediaBytes != null
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(18),
                                  child: Image.memory(_mediaBytes!,
                                      fit: BoxFit.cover),
                                )
                              : Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.add_photo_alternate_outlined,
                                        size: 64, color: Colors.grey[500]),
                                    const SizedBox(height: 12),
                                    const Text('Tap to add photo or video',
                                        style: TextStyle(
                                            color: Colors.white70,
                                            fontSize: 16)),
                                  ],
                                ),
                ),
              ),

              const SizedBox(height: 32),

              const Text('Details',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),

              TextField(
                controller: _captionController,
                style: const TextStyle(color: Colors.white),
                maxLines: 4,
                maxLength: 200,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.grey[850],
                  hintText: 'Write your story here... (emojis allowed)',
                  hintStyle: const TextStyle(color: Colors.white38),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                ),
                onChanged: (_) => setState(() {}),
              ),

              const SizedBox(height: 12),

              TextField(
                controller: _urlController,
                style: const TextStyle(color: Colors.white),
                keyboardType: TextInputType.url,
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.grey[850],
                  hintText: 'Add a link (Optional)',
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon:
                      const Icon(Icons.link_rounded, color: Colors.white54),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                ),
              ),

              const SizedBox(height: 40),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _isUploading ? null : _postStory,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF4CAF50),
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isUploading
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2))
                      : const Text('Post Story',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
