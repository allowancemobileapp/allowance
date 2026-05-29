// lib/screens/home/media_editor_screen.dart
import 'dart:io';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/home/video_trimmer_screen.dart'; // Ensure this exists
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

class MediaEditorScreen extends StatefulWidget {
  final XFile file;
  final bool isVideo;
  final UserPreferences userPreferences;

  const MediaEditorScreen({
    super.key,
    required this.file,
    required this.isVideo,
    required this.userPreferences,
  });

  @override
  State<MediaEditorScreen> createState() => _MediaEditorScreenState();
}

class _MediaEditorScreenState extends State<MediaEditorScreen> {
  final TextEditingController _captionController = TextEditingController();
  late XFile _currentFile;
  late Color themeColor;
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    _currentFile = widget.file;
    themeColor = Color(widget.userPreferences.themeColorValue);
    _prepareMedia();
  }

  @override
  void dispose() {
    _videoController?.dispose();
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _prepareMedia() async {
    _videoController?.dispose(); // Clean up old controller if trimming

    if (widget.isVideo) {
      if (kIsWeb) {
        // Web uses networkUrl for blob data
        _videoController =
            VideoPlayerController.networkUrl(Uri.parse(_currentFile.path));
      } else {
        // Mobile uses standard file loader
        _videoController = VideoPlayerController.file(File(_currentFile.path));
      }

      await _videoController!.initialize();
      _videoController!.setLooping(true);
      _videoController!.play();
      if (mounted) setState(() {});
    } else {
      if (mounted) setState(() {});
    }
  }

  // =====================================
  // EDITING METHODS (Mobile Only)
  // =====================================
  Future<void> _cropImage() async {
    if (kIsWeb) return; // Cropping requires complex web setup, disable for now

    final croppedFile = await ImageCropper().cropImage(
      sourcePath: _currentFile.path,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop Image',
          toolbarColor: Colors.black,
          toolbarWidgetColor: themeColor,
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
        ),
        IOSUiSettings(title: 'Crop Image'),
      ],
    );

    if (croppedFile != null) {
      setState(() => _currentFile = XFile(croppedFile.path));
      _prepareMedia();
    }
  }

  Future<void> _trimVideo() async {
    if (kIsWeb) return; // video_trimmer package does not support web

    final String? trimmedPath = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VideoTrimmerScreen(file: File(_currentFile.path)),
      ),
    );

    if (trimmedPath != null) {
      setState(() => _currentFile = XFile(trimmedPath));
      _prepareMedia();
    }
  }

  // =====================================
  // BACKGROUND POSTING
  // =====================================
  void _startBackgroundUpload() async {
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser!.id;
    final caption = _captionController.text.trim();
    final fileToUpload = _currentFile;
    final isVideo = widget.isVideo;

    Navigator.pop(context);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content:
            Text('Uploading moment to your profile... 🚀'), // Updated string
        duration: Duration(seconds: 2),
      ),
    );

    try {
      final extension = isVideo ? '.mp4' : '.jpg';
      final fileName = '${DateTime.now().millisecondsSinceEpoch}$extension';

      final bytes = await fileToUpload.readAsBytes();

      await supabase.storage.from('memories-bucket').uploadBinary(
            fileName,
            bytes,
            fileOptions: const FileOptions(cacheControl: '3600', upsert: false),
          );

      final publicUrl =
          supabase.storage.from('memories-bucket').getPublicUrl(fileName);

      await supabase.from('moments').insert({
        // Changed insertion target to moments
        'user_id': userId,
        'media_url': publicUrl,
        'caption': caption,
        'media_type': isVideo ? 'video' : 'image',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ Moment posted successfully!'), // Updated string
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      debugPrint('Background Upload error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              '❌ Could not post moment. Please check your internet connection and try again.'), // Updated string
          backgroundColor: Colors.redAccent,
          duration: Duration(seconds: 4),
        ),
      );
    }
  }

  // =====================================
  // UI BUILDER
  // =====================================
  Widget _buildMediaPreview() {
    if (widget.isVideo) {
      return _videoController != null && _videoController!.value.isInitialized
          ? AspectRatio(
              aspectRatio: _videoController!.value.aspectRatio,
              child: VideoPlayer(_videoController!),
            )
          : const CircularProgressIndicator(color: Colors.white);
    } else {
      return kIsWeb
          ? Image.network(_currentFile.path, fit: BoxFit.contain)
          : Image.file(File(_currentFile.path), fit: BoxFit.contain);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          // Show Crop icon for images, Scissor icon for videos (Mobile only)
          if (!kIsWeb) ...[
            if (!widget.isVideo)
              IconButton(
                icon: const Icon(Icons.crop, color: Colors.white),
                onPressed: _cropImage,
              )
            else
              IconButton(
                icon: const Icon(Icons.content_cut, color: Colors.white),
                onPressed: _trimVideo,
              ),
          ],
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: _buildMediaPreview(),
          ),

          // Caption & Send Area
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Colors.black.withOpacity(0.8)],
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: Colors.grey[900],
                        borderRadius: BorderRadius.circular(25),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: TextField(
                        controller: _captionController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          hintText: "Add a caption...",
                          hintStyle: TextStyle(color: Colors.white54),
                          border: InputBorder.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _startBackgroundUpload, // Triggers background post
                    child: CircleAvatar(
                      backgroundColor: themeColor,
                      radius: 24,
                      child:
                          const Icon(Icons.send, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
