// lib/screens/home/create_story_screen.dart
import 'dart:async';
import 'dart:io';
import 'package:allowance/screens/home/video_trimmer_screen.dart';
import 'package:video_compress/video_compress.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:wechat_camera_picker/wechat_camera_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:flutter/foundation.dart';
// ignore: unnecessary_import
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../models/user_preferences.dart';

class MediaItem {
  XFile file;
  Uint8List bytes;
  String type; // 'image' or 'video'

  MediaItem({required this.file, required this.bytes, required this.type});
}

class CreateStoryScreen extends StatefulWidget {
  final UserPreferences userPreferences;

  // 🔥 NEW: Global state to track uploading stories from anywhere!
  static final ValueNotifier<Map<String, dynamic>?> pendingStoryUpload =
      ValueNotifier(null);
  const CreateStoryScreen({super.key, required this.userPreferences});

  @override
  State<CreateStoryScreen> createState() => _CreateStoryScreenState();
}

class _CreateStoryScreenState extends State<CreateStoryScreen> {
  List<MediaItem> _selectedMedia = [];
  int _currentCarouselIndex = 0;
  bool _isTextOnly = true;
  double _selectedDuration = 1.0; // Default to 1 day

  final _captionController = TextEditingController();
  final _urlController = TextEditingController();
  bool _isUploading = false;
  final PageController _pageController = PageController();
  final ImagePicker _imagePicker = ImagePicker();
  bool _shareToMoments = false;

  // ==================== PICK MEDIA ====================
  Future<void> _pickMedia() async {
    // --- 1. WEB IMPLEMENTATION ---
    if (kIsWeb) {
      // Use image_picker on the web
      final List<XFile> pickedFiles = await _imagePicker.pickMultipleMedia();

      if (pickedFiles.isNotEmpty) {
        setState(() => _isUploading = true);
        List<MediaItem> newItems = [];

        for (var file in pickedFiles) {
          final bytes = await file.readAsBytes();

          // Determine if it's a video based on mimeType or extension
          final isVideo = file.mimeType?.startsWith('video/') == true ||
              file.name.toLowerCase().endsWith('.mp4') ||
              file.name.toLowerCase().endsWith('.mov') ||
              file.name.toLowerCase().endsWith('.webm');

          newItems.add(MediaItem(
            file: file,
            bytes: bytes,
            type: isVideo ? 'video' : 'image',
          ));
        }

        setState(() {
          _selectedMedia = newItems;
          _isTextOnly = false;
          _currentCarouselIndex = 0;
          _isUploading = false;
        });
      }
      return; // Exit the function early so it doesn't run the mobile code below
    }

    // --- 2. MOBILE IMPLEMENTATION (Your existing logic) ---
    final List<AssetEntity>? result = await AssetPicker.pickAssets(
      context,
      pickerConfig: AssetPickerConfig(
        maxAssets: 10,
        requestType: RequestType.common,
        themeColor: const Color(0xFF4CAF50),
        specialItemPosition: SpecialItemPosition.prepend,
        specialItemBuilder: (context, _, __) {
          return GestureDetector(
            onTap: () async {
              final AssetEntity? cameraResult =
                  await CameraPicker.pickFromCamera(
                context,
                pickerConfig: const CameraPickerConfig(
                  enableRecording: true,
                  onlyEnableRecording: false,
                  enableAudio: true,
                  textDelegate: EnglishCameraPickerTextDelegate(),
                ),
              );
              if (cameraResult != null) {
                _processPickedAssets([cameraResult]);
              }
            },
            child: const Center(
              child: Icon(Icons.camera_alt, size: 42, color: Colors.grey),
            ),
          );
        },
      ),
    );

    if (result != null && result.isNotEmpty) {
      _processPickedAssets(result);
    }
  }

  Future<void> _processPickedAssets(List<AssetEntity> assets) async {
    setState(() => _isUploading = true);
    List<MediaItem> newItems = [];
    for (var asset in assets) {
      final file = await asset.file;
      if (file != null) {
        final bytes = await file.readAsBytes();
        final isVideo = asset.type == AssetType.video;
        newItems.add(MediaItem(
          file: XFile(file.path),
          bytes: bytes,
          type: isVideo ? 'video' : 'image',
        ));
      }
    }
    setState(() {
      _selectedMedia = newItems;
      _isTextOnly = false;
      _currentCarouselIndex = 0;
      _isUploading = false;
    });
  }

  void _editCurrentMedia() async {
    if (_selectedMedia.isEmpty) return;
    final currentItem = _selectedMedia[_currentCarouselIndex];

    if (currentItem.type == 'image') {
      final croppedFile = await ImageCropper().cropImage(
        sourcePath: currentItem.file.path,
        uiSettings: [
          AndroidUiSettings(
            toolbarTitle: 'Crop Image',
            toolbarColor: Colors.black,
            toolbarWidgetColor: Colors.white,
            activeControlsWidgetColor: const Color(0xFF4CAF50),
          ),
          IOSUiSettings(title: 'Crop Image'),
        ],
      );
      if (croppedFile != null) {
        final newFile = XFile(croppedFile.path);
        final newBytes = await newFile.readAsBytes();
        setState(() {
          _selectedMedia[_currentCarouselIndex] = MediaItem(
            file: newFile,
            bytes: newBytes,
            type: 'image',
          );
        });
      }
    } else if (currentItem.type == 'video') {
      final videoFile = File(currentItem.file.path);
      final String? trimmedPath = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => VideoTrimmerScreen(file: videoFile),
        ),
      );
      if (trimmedPath != null) {
        final newFile = XFile(trimmedPath);
        final newBytes = await newFile.readAsBytes();
        setState(() {
          _selectedMedia[_currentCarouselIndex] = MediaItem(
            file: newFile,
            bytes: newBytes,
            type: 'video',
          );
        });
      }
    }
  }

  // ==================== DURATION PICKER (NEW) ====================
  // ==================== DURATION PICKER (NEW) ====================
  void _showDurationPicker() {
    final isPlus = widget.userPreferences.subscriptionTier == 'Membership';

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      isScrollControlled: true, // Allows sheet to expand fully
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              // Prevents keyboard overlap and overflow
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(context).viewInsets.bottom,
              ),
              child: DraggableScrollableSheet(
                initialChildSize: 0.6,
                minChildSize: 0.4,
                maxChildSize: 0.9,
                expand: false,
                builder: (_, scrollController) => ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(24.0),
                  children: [
                    Center(
                      child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2))),
                    ),
                    const SizedBox(height: 20),
                    const Text('Story Duration',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    Text(
                      isPlus
                          ? 'This story will disappear after ${_selectedDuration.toInt()} days'
                          : 'Free users can only post 1-day stories.',
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 30),
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                          activeTrackColor: const Color(0xFF4CAF50),
                          inactiveTrackColor: Colors.white10,
                          thumbColor: isPlus ? Colors.white : Colors.grey,
                          overlayColor:
                              const Color(0xFF4CAF50).withOpacity(0.2)),
                      child: Slider(
                        value: isPlus ? _selectedDuration : 1.0,
                        min: 1,
                        max: 10,
                        divisions: 9,
                        label: isPlus
                            ? '${_selectedDuration.toInt()} Days'
                            : '1 Day',
                        onChanged: isPlus
                            ? (value) {
                                setModalState(() => _selectedDuration = value);
                                setState(() {});
                              }
                            : null,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: const [
                            Text('1 Day',
                                style: TextStyle(
                                    color: Colors.white54, fontSize: 12)),
                            Text('10 Days (Plus)',
                                style: TextStyle(
                                    color: Colors.amber,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold))
                          ]),
                    ),
                    const SizedBox(height: 20),
                    SwitchListTile(
                      title: const Text('Share to Moments simultaneously',
                          style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                      subtitle: const Text(
                          'When the story expires, it will remain permanently as a Moment on your profile.',
                          style:
                              TextStyle(color: Colors.white54, fontSize: 12)),
                      value: _shareToMoments,
                      activeColor: const Color(0xFF4CAF50),
                      onChanged: (val) {
                        setModalState(() => _shareToMoments = val);
                        setState(() => _shareToMoments = val);
                      },
                    ),
                    const SizedBox(height: 30),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          _handleFinalUpload();
                        },
                        style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF4CAF50),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12))),
                        child: const Text('Confirm & Post',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.black)),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ==================== POST STORY LOGIC ====================
  Future<void> _postStory() async {
    // 1. Validation
    if (_isTextOnly && _captionController.text.trim().isEmpty) {
      _showErrorSnackBar('Please write something for your text story');
      return;
    }
    if (!_isTextOnly && _selectedMedia.isEmpty) {
      _showErrorSnackBar('Please select at least one photo or video to post.');
      return;
    }

    // 2. Show the Duration Slide-up
    _showDurationPicker();
  }

  Future<void> _handleFinalUpload() async {
    final List<MediaItem> mediaToUpload = List.from(_selectedMedia);
    final String caption = _captionController.text.trim();
    final String? linkUrl =
        _urlController.text.trim().isEmpty ? null : _urlController.text.trim();
    final bool textOnly = _isTextOnly;
    final int durationDays = _selectedDuration.toInt();

    final supabase = Supabase.instance.client;
    final userId = supabase.auth.currentUser!.id;

    // Exit screen
    Navigator.pop(context);

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Uploading story...'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );

    _runBackgroundUpload(
      supabase: supabase,
      mediaList: mediaToUpload,
      caption: caption,
      linkUrl: linkUrl,
      userId: userId,
      isTextOnly: textOnly,
      durationDays: durationDays,
    );
  }

  Future<void> _runBackgroundUpload({
    required SupabaseClient supabase,
    required List<MediaItem> mediaList,
    required String caption,
    required String? linkUrl,
    required String userId,
    required bool isTextOnly,
    required int durationDays,
  }) async {
    const bucket = 'gist-images';
    final expiresAt =
        DateTime.now().add(Duration(days: durationDays)).toIso8601String();

    CreateStoryScreen.pendingStoryUpload.value = {'progress': 0.05};

    final progressTimer =
        Timer.periodic(const Duration(milliseconds: 300), (timer) {
      final current = CreateStoryScreen.pendingStoryUpload.value;
      if (current != null && current['progress'] != null) {
        double prog = current['progress'];
        if (prog < 0.90) {
          CreateStoryScreen.pendingStoryUpload.value = {
            ...current,
            'progress': prog + 0.05
          };
        }
      }
    });

    try {
      if (isTextOnly) {
        await _insertDatabaseRow(
            supabase, userId, null, 'text', caption, linkUrl, expiresAt);
        // 🔥 FIX: Inserts to moments if toggle is ON
        if (_shareToMoments) {
          await supabase.from('moments').insert({
            'user_id': userId,
            'media_url': null,
            'media_type': 'text',
            'caption': caption
          });
        }
      } else {
        for (var media in mediaList) {
          final ext = media.file.name.split('.').last;
          final baseFileName = const Uuid().v4();
          final path = 'stories/$baseFileName.$ext';
          final hdPath = 'stories/${baseFileName}_hd.$ext';

          Uint8List bytesToUpload = media.bytes;
          bool isHdAvailable = false;

          if (media.type == 'video' && !kIsWeb) {
            try {
              final mediaInfo =
                  await VideoCompress.getMediaInfo(media.file.path);
              final int width = mediaInfo.width ?? 0;
              final int height = mediaInfo.height ?? 0;
              final int maxRes = width > height ? width : height;
              final double sizeMb = (mediaInfo.filesize ?? 0) / (1024 * 1024);

              if (maxRes <= 1280 && sizeMb < 30) {
                bytesToUpload = media.bytes;
              } else {
                VideoQuality targetQuality = VideoQuality.Res1280x720Quality;
                if (sizeMb > 50) targetQuality = VideoQuality.Res960x540Quality;

                final info = await VideoCompress.compressVideo(media.file.path,
                    quality: targetQuality,
                    deleteOrigin: false,
                    includeAudio: true);

                if (info != null &&
                    info.file != null &&
                    info.file!.lengthSync() > 50000) {
                  bytesToUpload = await info.file!.readAsBytes();
                  isHdAvailable = true;
                } else {
                  throw 'Compression returned corrupted/empty file';
                }
              }
            } catch (e) {
              debugPrint("Story Video compression failed, using original: $e");
              bytesToUpload = media.bytes;
            }
          }

          await supabase.storage.from(bucket).uploadBinary(path, bytesToUpload,
              fileOptions: const FileOptions(upsert: true));
          final publicUrl = supabase.storage.from(bucket).getPublicUrl(path);

          if (isHdAvailable && media.type == 'video' && !kIsWeb) {
            supabase.storage
                .from(bucket)
                .uploadBinary(hdPath, media.bytes,
                    fileOptions: const FileOptions(upsert: true))
                .catchError((_) => null);
          }

          await _insertDatabaseRow(supabase, userId, publicUrl, media.type,
              caption, linkUrl, expiresAt);

          // 🔥 FIX: Inserts to moments if toggle is ON
          if (_shareToMoments) {
            await supabase.from('moments').insert({
              'user_id': userId,
              'media_url': publicUrl,
              'media_type': media.type,
              'caption': caption
            });
          }
        }
      }
      CreateStoryScreen.pendingStoryUpload.value = {
        ...CreateStoryScreen.pendingStoryUpload.value!,
        'progress': 1.0
      };
    } catch (e) {
      debugPrint("Background Upload Error: $e");
    } finally {
      progressTimer.cancel();
      if (!isTextOnly && !kIsWeb) VideoCompress.deleteAllCache();
      Future.delayed(const Duration(milliseconds: 500), () {
        CreateStoryScreen.pendingStoryUpload.value = null;
      });
    }
  }

  Future<void> _insertDatabaseRow(
      SupabaseClient supabase,
      String userId,
      String? publicUrl,
      String mediaType,
      String caption,
      String? linkUrl,
      String expiresAt) async {
    await supabase.from('stories').insert({
      'user_id': userId,
      'media_url': publicUrl,
      'media_type': mediaType,
      'caption': caption,
      'url': linkUrl,
      'expires_at': expiresAt, // Added expiry column
    });
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    // FIX: Completely removed the "Paywall Area" Scaffold return block.
    // Everyone can access this screen now!

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        title: const Text('New Story',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        // ... (Keep the rest of your body content exactly as it is)
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              GestureDetector(
                onTap: _selectedMedia.isEmpty ? _pickMedia : null,
                child: Container(
                  height: 320,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.grey[850],
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: Colors.grey[700]!, width: 2),
                  ),
                  child: _isTextOnly && _selectedMedia.isEmpty
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: const [
                            Icon(Icons.add_a_photo,
                                size: 80, color: Colors.white54),
                            SizedBox(height: 12),
                            Text('Tap to add photo or video',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 16)),
                          ],
                        )
                      : Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(18),
                              child: PageView.builder(
                                controller: _pageController,
                                itemCount: _selectedMedia.length,
                                onPageChanged: (index) => setState(
                                    () => _currentCarouselIndex = index),
                                itemBuilder: (context, index) {
                                  final media = _selectedMedia[index];
                                  return media.type == 'video'
                                      ? const Center(
                                          child: Icon(Icons.play_circle_fill,
                                              size: 80, color: Colors.white))
                                      : Image.memory(media.bytes,
                                          fit: BoxFit.cover,
                                          width: double.infinity);
                                },
                              ),
                            ),
                            if (_selectedMedia.length > 1)
                              Positioned(
                                top: 10,
                                right: 0,
                                left: 0,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: List.generate(_selectedMedia.length,
                                      (index) {
                                    return Container(
                                      margin: const EdgeInsets.symmetric(
                                          horizontal: 4),
                                      width: 8,
                                      height: 8,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: _currentCarouselIndex == index
                                            ? Colors.blue
                                            : Colors.white54,
                                      ),
                                    );
                                  }),
                                ),
                              ),
                            Positioned(
                              bottom: 10,
                              right: 10,
                              child: Material(
                                color: Colors.black54,
                                shape: const CircleBorder(),
                                child: IconButton(
                                  icon: Icon(
                                    _selectedMedia[_currentCarouselIndex]
                                                .type ==
                                            'image'
                                        ? Icons.crop
                                        : Icons.content_cut,
                                    color: Colors.white,
                                  ),
                                  onPressed: _editCurrentMedia,
                                ),
                              ),
                            ),
                            Positioned(
                              top: 10,
                              right: 10,
                              child: Material(
                                color: Colors.black54,
                                shape: const CircleBorder(),
                                child: IconButton(
                                  icon: const Icon(Icons.edit,
                                      color: Colors.white, size: 20),
                                  onPressed: _pickMedia,
                                ),
                              ),
                            ),
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
                  hintText: 'Write your story here...',
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
