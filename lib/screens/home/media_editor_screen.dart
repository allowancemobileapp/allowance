// lib/screens/home/media_editor_screen.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/home/video_trimmer_screen.dart'; // Ensure this exists
import 'package:allowance/screens/profile/profile_screen.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';

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
  static bool cancelUploadFlag = false;
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
    // 🔥 FIX: Enabled for Web! image_cropper_for_web will handle this safely.
    try {
      final croppedFile = await ImageCropper().cropImage(
        sourcePath: _currentFile.path,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Crop Image',
            toolbarColor: const Color(0xFF121212),
            toolbarWidgetColor: themeColor,
            initAspectRatio: CropAspectRatioPreset.original,
            lockAspectRatio: false,
          ),
          IOSUiSettings(title: 'Crop Image'),
          WebUiSettings(
            context: context,
            presentStyle: WebPresentStyle.dialog,
          ),
        ],
      );

      if (croppedFile != null) {
        setState(() => _currentFile = XFile(croppedFile.path));
        _prepareMedia();
      }
    } catch (e) {
      debugPrint("Crop error: $e");
    }
  }

  Future<void> _trimVideo() async {
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Video trimming on Web is coming soon!')));
      return;
    }

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
  // GLOBAL BACKGROUND POSTING (SMART COMPRESSION)
  // =====================================
  // --- UPDATED: VIDEO COMPRESSION FAIL-SAFE ---
  void _startBackgroundUpload() async {
    cancelUploadFlag = false;
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser!.id;
    final caption = _captionController.text.trim();
    final isVideo = widget.isVideo;
    final currentPath = _currentFile.path;

    ProfileScreen.pendingMomentUpload.value = {
      'local_path': currentPath,
      'is_video': isVideo,
      'progress': 0.05
    };
    Navigator.pop(context);

    final progressTimer =
        Timer.periodic(const Duration(milliseconds: 400), (timer) {
      if (cancelUploadFlag) {
        timer.cancel();
        return;
      }
      final current = ProfileScreen.pendingMomentUpload.value;
      if (current != null && current['progress'] != null) {
        double currentProg = current['progress'];
        if (currentProg < 0.90) {
          ProfileScreen.pendingMomentUpload.value = {
            ...current,
            'progress': currentProg + 0.05
          };
        }
      }
    });

    try {
      final extension = isVideo ? '.mp4' : '.jpg';
      final baseFileName = '${DateTime.now().millisecondsSinceEpoch}';
      final fileName = '$baseFileName$extension';
      final hdFileName = '${baseFileName}_hd$extension';

      Uint8List fastBytes;

      if (isVideo && !kIsWeb) {
        try {
          // 🔥 FIX: Changed to DefaultQuality to preserve playback
          final info = await VideoCompress.compressVideo(
            currentPath,
            quality: VideoQuality.DefaultQuality,
            deleteOrigin: false,
            includeAudio: true,
          );
          if (info != null &&
              info.file != null &&
              info.file!.lengthSync() > 1000) {
            fastBytes = await info.file!.readAsBytes();
          } else {
            throw 'Compression resulted in empty file';
          }
        } catch (e) {
          debugPrint("Compression failed, using original video: $e");
          fastBytes = await _currentFile.readAsBytes();
        }
      } else {
        fastBytes = await _currentFile.readAsBytes();
      }

      if (cancelUploadFlag) throw 'Cancelled by user';

      await supabase.storage.from('memories-bucket').uploadBinary(
          fileName, fastBytes,
          fileOptions: const FileOptions(cacheControl: '3600', upsert: false));

      if (isVideo) {
        final hdBytes = await _currentFile.readAsBytes();
        supabase.storage
            .from('memories-bucket')
            .uploadBinary(hdFileName, hdBytes,
                fileOptions:
                    const FileOptions(cacheControl: '3600', upsert: false))
            .catchError((error) => '');
      }

      if (cancelUploadFlag) throw 'Cancelled by user';
      final publicUrl =
          supabase.storage.from('memories-bucket').getPublicUrl(fileName);

      await supabase.from('moments').insert({
        'user_id': userId,
        'media_url': publicUrl,
        'caption': caption,
        'media_type': isVideo ? 'video' : 'image',
        'created_at': DateTime.now().toUtc().toIso8601String(),
      });

      ProfileScreen.pendingMomentUpload.value = {
        ...ProfileScreen.pendingMomentUpload.value!,
        'progress': 1.0
      };
    } catch (e) {
      debugPrint('Upload Error/Cancelled: $e');
    } finally {
      progressTimer.cancel();
      if (isVideo && !kIsWeb) VideoCompress.deleteAllCache();
      Future.delayed(const Duration(milliseconds: 500), () {
        ProfileScreen.pendingMomentUpload.value = null;
      });
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
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          // 🔥 FIX: Removed `if (!kIsWeb)` so the buttons show everywhere!
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
                  colors: [
                    Colors.transparent,
                    Color(0xFF121212).withOpacity(0.8)
                  ],
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: Color(0xFF121212),
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
