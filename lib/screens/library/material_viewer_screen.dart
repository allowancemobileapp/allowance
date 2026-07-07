// lib/screens/library/material_viewer_screen.dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:syncfusion_flutter_pdfviewer/pdfviewer.dart';
import 'package:http/http.dart' as http;
import '../../models/user_preferences.dart';
import 'quiz_screen.dart';

const Color _themeColor = Color(0xFF4CAF50);
const Color _bg = Color(0xFF121212);

class MaterialViewerScreen extends StatefulWidget {
  final Map<String, dynamic> material;
  final UserPreferences userPreferences;

  const MaterialViewerScreen({
    super.key,
    required this.material,
    required this.userPreferences,
  });

  @override
  State<MaterialViewerScreen> createState() => _MaterialViewerScreenState();
}

class _MaterialViewerScreenState extends State<MaterialViewerScreen> {
  Uint8List? _pdfBytes;
  bool _isLoadingPdf = false;
  String? _pdfError;

  @override
  void initState() {
    super.initState();
    _prepareFile();
  }

  Future<void> _prepareFile() async {
    final rawFileUrl = widget.material['file_url'] as String? ?? '';
    final isPdf = rawFileUrl.toLowerCase().split('?').first.endsWith('.pdf');

    if (isPdf && rawFileUrl.isNotEmpty) {
      setState(() => _isLoadingPdf = true);
      try {
        // Encode URL to handle spaces safely
        final encodedUrl = Uri.encodeFull(rawFileUrl);
        final response = await http.get(Uri.parse(encodedUrl));

        if (response.statusCode == 200) {
          // Verify it's actually a PDF by checking the Magic Number (%PDF)
          if (response.bodyBytes.length > 4 &&
              response.bodyBytes[0] == 0x25 && // %
              response.bodyBytes[1] == 0x50 && // P
              response.bodyBytes[2] == 0x44 && // D
              response.bodyBytes[3] == 0x46) {
            // F

            if (mounted) {
              setState(() {
                _pdfBytes = response.bodyBytes;
                _isLoadingPdf = false;
              });
            }
          } else {
            // It downloaded successfully, but the file is corrupted or is an HTML/JSON error page
            if (mounted) {
              setState(() {
                _pdfError =
                    'The uploaded file is corrupted or not a valid PDF document.';
                _isLoadingPdf = false;
              });
            }
          }
        } else {
          // Server returned a 404, 403, etc.
          if (mounted) {
            setState(() {
              _pdfError =
                  'Server error: ${response.statusCode}. Make sure the Supabase bucket is public.';
              _isLoadingPdf = false;
            });
          }
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _pdfError =
                'Could not download PDF. Please check your internet connection.';
            _isLoadingPdf = false;
          });
          debugPrint("PDF Download Error: $e");
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final rawFileUrl = widget.material['file_url'] as String? ?? '';
    final encodedUrl = Uri.encodeFull(rawFileUrl);
    final isPdf = rawFileUrl.toLowerCase().split('?').first.endsWith('.pdf');

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(widget.material['title'] ?? 'Document',
            style: const TextStyle(color: Colors.white, fontSize: 16)),
      ),
      body: rawFileUrl.isEmpty
          ? const Center(
              child: Text('Invalid file URL',
                  style: TextStyle(color: Colors.white)))
          : isPdf
              ? _buildPdfViewer()
              : Center(
                  child: InteractiveViewer(
                    child: Image.network(
                      encodedUrl,
                      fit: BoxFit.contain,
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return const CircularProgressIndicator(
                            color: _themeColor);
                      },
                      errorBuilder: (context, error, stackTrace) => const Icon(
                          Icons.broken_image,
                          color: Colors.white54,
                          size: 60),
                    ),
                  ),
                ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: Colors.blueAccent,
        icon: const Icon(Icons.flash_on, color: Colors.white),
        label: const Text('POP QUIZ',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        onPressed: () => QuizSetupSheet.show(
          context,
          courseId: widget.material['course_id'],
          materialId: widget.material['id'],
          userPreferences: widget.userPreferences,
          isExam: false,
        ),
      ),
    );
  }

  Widget _buildPdfViewer() {
    if (_isLoadingPdf) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: _themeColor),
            SizedBox(height: 16),
            Text('Downloading Document...',
                style: TextStyle(color: Colors.white54, fontSize: 14))
          ],
        ),
      );
    }

    if (_pdfError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Text(
            _pdfError!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.redAccent, fontSize: 16),
          ),
        ),
      );
    }

    if (_pdfBytes != null) {
      return SfPdfViewer.memory(
        _pdfBytes!,
        canShowScrollHead: false,
        pageSpacing: 4,
        onDocumentLoadFailed: (details) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Failed to render PDF: ${details.error}')),
          );
        },
      );
    }

    return const Center(
        child: Text("Unknown Error", style: TextStyle(color: Colors.white)));
  }
}

// ==========================================
// QUIZ SETUP BOTTOM SHEET (Shared by both)
// ==========================================
class QuizSetupSheet extends StatefulWidget {
  final int? courseId;
  final int? materialId;
  final UserPreferences userPreferences;
  final bool isExam;

  const QuizSetupSheet({
    super.key,
    this.courseId,
    this.materialId,
    required this.userPreferences,
    required this.isExam,
  });

  static void show(BuildContext context,
      {int? courseId,
      int? materialId,
      required UserPreferences userPreferences,
      required bool isExam}) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => QuizSetupSheet(
        courseId: courseId,
        materialId: materialId,
        userPreferences: userPreferences,
        isExam: isExam,
      ),
    );
  }

  @override
  State<QuizSetupSheet> createState() => _QuizSetupSheetState();
}

class _QuizSetupSheetState extends State<QuizSetupSheet> {
  int _questionCount = 10;
  int _durationMins = 10;
  late bool _isPlus;

  @override
  void initState() {
    super.initState();
    _isPlus = widget.userPreferences.subscriptionTier == 'Membership';
  }

  @override
  Widget build(BuildContext context) {
    final maxQs = _isPlus ? (widget.isExam ? 100 : 30) : 10;
    final maxTime = _isPlus ? 120 : 10;

    return SingleChildScrollView(
      child: Padding(
        padding: EdgeInsets.only(
          left: 24.0,
          right: 24.0,
          top: 24.0,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24.0,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2))),
            const SizedBox(height: 20),
            Text(widget.isExam ? 'Exam Quiz Setup' : 'Pop Quiz Setup',
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            if (!_isPlus)
              const Text('Free users are locked to 10 questions in 10 minutes.',
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Number of Questions:',
                    style: TextStyle(color: Colors.white70)),
                Text('$_questionCount',
                    style: const TextStyle(
                        color: _themeColor,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                  activeTrackColor: _themeColor, thumbColor: Colors.white),
              child: Slider(
                value: _questionCount.toDouble(),
                min: 10,
                max: maxQs.toDouble(),
                divisions: (maxQs - 10) > 0 ? (maxQs - 10) : 1,
                onChanged: _isPlus
                    ? (val) => setState(() => _questionCount = val.toInt())
                    : null,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Time Limit (Minutes):',
                    style: TextStyle(color: Colors.white70)),
                Text('$_durationMins',
                    style: const TextStyle(
                        color: _themeColor,
                        fontSize: 18,
                        fontWeight: FontWeight.bold)),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                  activeTrackColor: _themeColor, thumbColor: Colors.white),
              child: Slider(
                value: _durationMins.toDouble(),
                min: 5,
                max: maxTime.toDouble() > 5 ? maxTime.toDouble() : 10,
                divisions: maxTime > 5 ? (maxTime - 5) : 1,
                onChanged: _isPlus
                    ? (val) => setState(() => _durationMins = val.toInt())
                    : null,
              ),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: _themeColor,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16))),
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => QuizScreen(
                                courseId: widget.courseId,
                                materialId: widget.materialId,
                                questionCount: _questionCount,
                                durationMins: _durationMins,
                                isExam: widget.isExam,
                              )));
                },
                child: const Text('START',
                    style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 18)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
