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
      final bytes = await picked.readAsBytes();

      setState(() {
        _mediaFile = picked;
        _mediaBytes = bytes;
        _mediaType = picked.name.toLowerCase().contains('.mp4') ||
                picked.name.toLowerCase().contains('.mov') ||
                picked.name.toLowerCase().contains('.avi')
            ? 'video'
            : 'image';
      });
    }
  }

  Future<void> _postStory() async {
    if (_mediaBytes == null) return;
    setState(() => _isUploading = true);

    final supabase = Supabase.instance.client;
    final bucket =
        'gist-images'; // change if you use a different bucket for stories

    try {
      final ext = _mediaFile!.name.split('.').last;
      final path = 'stories/${const Uuid().v4()}.$ext';

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
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Upload failed: $e'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
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
      return Scaffold(
        backgroundColor: Colors.grey[900],
        appBar: AppBar(
          title: const Text('New Story',
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: Colors.grey[850],
                borderRadius: BorderRadius.circular(24),
                border:
                    Border.all(color: Colors.amber.withOpacity(0.3), width: 1),
                boxShadow: const [
                  BoxShadow(
                    color: Colors.black26,
                    blurRadius: 10,
                    offset: Offset(0, 4),
                  )
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.amber.withOpacity(0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.workspace_premium_rounded,
                        size: 64, color: Colors.amber),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Unlock Story Gists',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Join the Allowance Plus family to start sharing your stories with the community.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 15, color: Colors.white70, height: 1.4),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.amber,
                        foregroundColor: Colors.black87,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                        elevation: 0,
                      ),
                      child: const Text('Subscribe to Plus',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.bold)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
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
                  child: _mediaBytes == null
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.add_photo_alternate_outlined,
                                size: 64, color: Colors.grey[500]),
                            const SizedBox(height: 12),
                            const Text('Tap to add photo or video',
                                style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500)),
                          ],
                        )
                      : _mediaType == 'video'
                          ? const Center(
                              child: Icon(Icons.play_circle_fill,
                                  size: 80, color: Colors.white))
                          : ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: Image.memory(
                                _mediaBytes!,
                                fit: BoxFit.cover,
                                width: double.infinity,
                                height: 320,
                              ),
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
                maxLength: 100, // Optional: limits caption length
                decoration: InputDecoration(
                  filled: true,
                  fillColor: Colors.grey[850],
                  hintText: 'Write a caption...',
                  hintStyle: const TextStyle(color: Colors.white38),
                  prefixIcon: const Icon(Icons.short_text_rounded,
                      color: Colors.white54),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none),
                  counterStyle: const TextStyle(color: Colors.white38),
                ),
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
                    disabledBackgroundColor: Colors.grey[800],
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  child: _isUploading
                      ? const SizedBox(
                          height: 24,
                          width: 24,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2),
                        )
                      : const Text(
                          'Post Story',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
