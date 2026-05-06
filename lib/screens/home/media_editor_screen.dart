import 'dart:io';
import 'package:allowance/models/user_preferences.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:image_cropper/image_cropper.dart';

class MediaEditorScreen extends StatefulWidget {
  final AssetEntity asset;
  final UserPreferences userPreferences; // Use the actual class name here

  const MediaEditorScreen(
      {super.key, required this.asset, required this.userPreferences});

  @override
  State<MediaEditorScreen> createState() => _MediaEditorScreenState();
}

class _MediaEditorScreenState extends State<MediaEditorScreen> {
  final TextEditingController _captionController = TextEditingController();
  File? _processedFile;
  late Color themeColor;
  VideoPlayerController? _videoController;
  bool _isUploading = false;

  @override
  void dispose() {
    _videoController?.dispose();
    _captionController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();

    // This is exactly where you use it!
    themeColor = Color(widget.userPreferences.themeColorValue);

    _prepareMedia();
  }

  Future<void> _prepareMedia() async {
    final file = await widget.asset.file;
    if (file == null) return;

    setState(() => _processedFile = file);

    // Initialize video player if it's a video
    if (widget.asset.type == AssetType.video) {
      _videoController = VideoPlayerController.file(file)
        ..initialize().then((_) {
          setState(() {});
          _videoController!.play();
          _videoController!.setLooping(true);
        });
    }
  }

  Widget _buildMediaPreview() {
    if (_processedFile == null) {
      return const CircularProgressIndicator();
    }

    if (widget.asset.type == AssetType.video) {
      return _videoController != null && _videoController!.value.isInitialized
          ? AspectRatio(
              aspectRatio: _videoController!.value.aspectRatio,
              child: VideoPlayer(_videoController!),
            )
          : const CircularProgressIndicator(color: Colors.white);
    } else {
      return Image.file(_processedFile!, fit: BoxFit.contain);
    }
  }

  Future<void> _uploadMemory() async {
    if (_processedFile == null || _isUploading) return;
    setState(() => _isUploading = true);

    try {
      final supabase = Supabase.instance.client;
      final userId = supabase.auth.currentUser!.id;
      final isVideo = widget.asset.type == AssetType.video;

      // Create unique filename with correct extension
      final extension = isVideo ? '.mp4' : '.jpg';
      final fileName = '${DateTime.now().millisecondsSinceEpoch}$extension';

      // 1. Upload to storage bucket (Ensure 'memories-bucket' is created in Supabase)
      await supabase.storage.from('memories-bucket').upload(
            fileName,
            _processedFile!,
            fileOptions: const FileOptions(cacheControl: '3600', upsert: false),
          );

      final publicUrl =
          supabase.storage.from('memories-bucket').getPublicUrl(fileName);

      // 2. Insert into memories table - MATCHING SCHEMA
      await supabase.from('memories').insert({
        'user_id': userId,
        'media_url': publicUrl,
        'caption':
            _captionController.text.trim(), // Added .trim() for cleanliness
        'media_type':
            isVideo ? 'video' : 'image', // FIX: Matches media_type in schema
        'created_at': DateTime.now()
            .toUtc()
            .toIso8601String(), // Using UTC for consistency
      });

      if (mounted) Navigator.pop(context);
    } catch (e) {
      debugPrint('Upload error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploading = false);
    }
  }

// UPDATE: The _cropImage method with the corrected API
  Future<void> _cropImage() async {
    if (_processedFile == null) return;

    final croppedFile = await ImageCropper().cropImage(
      sourcePath: _processedFile!.path,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Edit Media',
          toolbarColor: Colors.black,
          toolbarWidgetColor: themeColor,
          initAspectRatio: CropAspectRatioPreset.original,
          lockAspectRatio: false,
          // Move presets here for Android
          aspectRatioPresets: [
            CropAspectRatioPreset.square,
            CropAspectRatioPreset.ratio3x2,
            CropAspectRatioPreset.original,
            CropAspectRatioPreset.ratio4x3,
            CropAspectRatioPreset.ratio16x9,
          ],
        ),
        IOSUiSettings(
          title: 'Edit Media',
          // Move presets here for iOS
          aspectRatioPresets: [
            CropAspectRatioPreset.square,
            CropAspectRatioPreset.ratio3x2,
            CropAspectRatioPreset.original,
            CropAspectRatioPreset.ratio4x3,
            CropAspectRatioPreset.ratio16x9,
          ],
        ),
      ],
    );

    if (croppedFile != null) {
      setState(() => _processedFile = File(croppedFile.path));
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
          if (widget.asset.type == AssetType.image)
            IconButton(
              icon: const Icon(Icons.crop, color: Colors.white),
              onPressed: _cropImage,
            ),
          IconButton(
            icon: const Icon(Icons.text_fields, color: Colors.white),
            onPressed: () {/* Add text overlay logic here */},
          ),
        ],
      ),
      body: Stack(
        children: [
          // Media Preview - Uses the new method
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
                    // Calls the upload method
                    onTap: _uploadMemory,
                    child: CircleAvatar(
                      backgroundColor: themeColor,
                      radius: 24,
                      child: _isUploading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.send,
                              color: Colors.white, size: 20),
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
