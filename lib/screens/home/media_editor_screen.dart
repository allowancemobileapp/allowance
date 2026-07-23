// lib/screens/home/media_editor_screen.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:allowance/models/user_preferences.dart';
import 'package:allowance/screens/home/video_trimmer_screen.dart';
import 'package:allowance/screens/profile/profile_screen.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_compress/video_compress.dart';

class MediaEditorScreen extends StatefulWidget {
  final List<XFile> files; // 🔥 NOW ACCEPTS A LIST FOR CAROUSEL!
  final bool isVideo;
  final UserPreferences userPreferences;

  const MediaEditorScreen({
    super.key,
    required this.files,
    required this.isVideo,
    required this.userPreferences,
  });

  @override
  State<MediaEditorScreen> createState() => _MediaEditorScreenState();
}

class _MediaEditorScreenState extends State<MediaEditorScreen> {
  final TextEditingController _captionController = TextEditingController();
  late List<XFile> _currentFiles;
  int _currentIndex = 0;
  late Color themeColor;
  static bool cancelUploadFlag = false;
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    _currentFiles = List.from(widget.files);
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
    _videoController?.dispose();

    if (widget.isVideo && _currentFiles.isNotEmpty) {
      if (kIsWeb) {
        _videoController = VideoPlayerController.networkUrl(
            Uri.parse(_currentFiles.first.path));
      } else {
        _videoController =
            VideoPlayerController.file(File(_currentFiles.first.path));
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
  // EDITING METHODS
  // =====================================
  Future<void> _cropImage() async {
    try {
      final croppedFile = await ImageCropper().cropImage(
        sourcePath: _currentFiles[_currentIndex].path,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Crop Image ${_currentIndex + 1}',
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
        setState(() {
          _currentFiles[_currentIndex] = XFile(croppedFile.path);
        });
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
        builder: (context) =>
            VideoTrimmerScreen(file: File(_currentFiles.first.path)),
      ),
    );

    if (trimmedPath != null) {
      setState(() => _currentFiles[0] = XFile(trimmedPath));
      _prepareMedia();
    }
  }

  // =====================================
  // GLOBAL BACKGROUND POSTING
  // =====================================
  void _startBackgroundUpload(String selectedTag) async {
    cancelUploadFlag = false;
    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser!.id;
    final caption = _captionController.text.trim();
    final isVideo = widget.isVideo;

    ProfileScreen.pendingMomentUpload.value = {
      'local_path': _currentFiles.first.path,
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
      List<String> uploadedUrls = [];
      String mainUrl = '';

      if (isVideo) {
        final extension = '.mp4';
        final baseFileName = '${DateTime.now().millisecondsSinceEpoch}';
        final fileName = '$baseFileName$extension';
        final hdFileName = '${baseFileName}_hd$extension';
        final currentPath = _currentFiles.first.path;

        Uint8List fastBytes;
        bool uploadHd = false;

        if (!kIsWeb) {
          try {
            final mediaInfo = await VideoCompress.getMediaInfo(currentPath);
            final int width = mediaInfo.width ?? 0;
            final int height = mediaInfo.height ?? 0;
            final int maxRes = width > height ? width : height;

            // 🧠 STRICTLY NEVER BELOW 720p
            if (maxRes <= 1280) {
              // If it's already 720p or lower, DO NOT COMPRESS. Just send as is.
              fastBytes = await _currentFiles.first.readAsBytes();
              uploadHd = false;
            } else {
              // High res video (1080p, 4K, etc). Compress to exactly 720p.
              final info = await VideoCompress.compressVideo(
                currentPath,
                quality: VideoQuality.Res1280x720Quality, // ALWAYS 720p
                deleteOrigin: false,
                includeAudio: true,
              );

              if (info != null &&
                  info.file != null &&
                  info.file!.lengthSync() > 50000) {
                fastBytes = await info.file!.readAsBytes();
                uploadHd = true; // Save the original HD copy too!
              } else {
                throw 'Compression corrupted';
              }
            }
          } catch (e) {
            fastBytes = await _currentFiles.first.readAsBytes();
          }
        } else {
          fastBytes = await _currentFiles.first.readAsBytes();
        }

        if (cancelUploadFlag) throw 'Cancelled by user';
        await supabase.storage.from('memories-bucket').uploadBinary(
            fileName, fastBytes,
            fileOptions:
                const FileOptions(cacheControl: '3600', upsert: false));

        if (uploadHd && !kIsWeb) {
          final hdBytes = await _currentFiles.first.readAsBytes();
          supabase.storage
              .from('memories-bucket')
              .uploadBinary(hdFileName, hdBytes,
                  fileOptions:
                      const FileOptions(cacheControl: '3600', upsert: false))
              .catchError((_) => null);
        }

        mainUrl =
            supabase.storage.from('memories-bucket').getPublicUrl(fileName);
      } else {
        // IMAGE CAROUSEL UPLOAD (Up to 10 images)
        for (int i = 0; i < _currentFiles.length; i++) {
          if (cancelUploadFlag) throw 'Cancelled by user';
          final bytes = await _currentFiles[i].readAsBytes();
          final fileName = '${DateTime.now().millisecondsSinceEpoch}_$i.jpg';

          await supabase.storage.from('memories-bucket').uploadBinary(
              fileName, bytes,
              fileOptions:
                  const FileOptions(cacheControl: '3600', upsert: false));
          final url =
              supabase.storage.from('memories-bucket').getPublicUrl(fileName);
          uploadedUrls.add(url);
        }
        mainUrl = uploadedUrls.first;
      }

      await supabase.from('moments').insert({
        'user_id': userId,
        'media_url': mainUrl,
        'image_urls': uploadedUrls,
        'caption': caption,
        'category': selectedTag,
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
      return Stack(
        children: [
          PageView.builder(
            itemCount: _currentFiles.length,
            onPageChanged: (index) => setState(() => _currentIndex = index),
            itemBuilder: (context, index) {
              return kIsWeb
                  ? Image.network(_currentFiles[index].path,
                      fit: BoxFit.contain)
                  : Image.file(File(_currentFiles[index].path),
                      fit: BoxFit.contain);
            },
          ),
          if (_currentFiles.length > 1)
            Positioned(
              top: 16,
              right: 16,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20)),
                child: Text("${_currentIndex + 1} / ${_currentFiles.length}",
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold)),
              ),
            ),
        ],
      );
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
                    const Color(0xFF121212).withOpacity(0.8)
                  ],
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF121212),
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
                    onTap: () {
                      final tags = [
                        'Random',
                        'Tech',
                        'Food',
                        'Football',
                        'Wildlife',
                        'Deep Sea',
                        'Religion',
                        'Relationship',
                        'Comics',
                        'Anime',
                        'Wealth'
                      ];
                      showModalBottomSheet(
                        context: context,
                        backgroundColor: const Color(0xFF1E1E1E),
                        shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.vertical(
                                top: Radius.circular(20))),
                        builder: (ctx) => Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Padding(
                              padding: EdgeInsets.all(16.0),
                              child: Text('Select a Tag',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold)),
                            ),
                            Expanded(
                              child: ListView.builder(
                                itemCount: tags.length,
                                itemBuilder: (context, index) => ListTile(
                                  title: Text(tags[index],
                                      style:
                                          const TextStyle(color: Colors.white)),
                                  trailing: const Icon(Icons.chevron_right,
                                      color: Colors.white54),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    _startBackgroundUpload(tags[index]);
                                  },
                                ),
                              ),
                            )
                          ],
                        ),
                      );
                    },
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
