// lib/screens/library/quiz_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const Color _themeColor = Color(0xFF4CAF50);
const Color _bg = Color(0xFF121212);
const Color _card = Color(0xFF1E1E1E);

class QuizScreen extends StatefulWidget {
  final int? courseId;
  final int? materialId;
  final int questionCount;
  final int durationMins;
  final bool isExam;

  const QuizScreen({
    super.key,
    this.courseId,
    this.materialId,
    required this.questionCount,
    required this.durationMins,
    required this.isExam,
  });

  @override
  State<QuizScreen> createState() => _QuizScreenState();
}

class _QuizScreenState extends State<QuizScreen> {
  final supabase = Supabase.instance.client;
  bool _isLoading = true;
  List<dynamic> _questions = [];
  Map<int, String> _selectedAnswers =
      {}; // key: question index, value: option string (A, B, C)

  late int _secondsRemaining;
  Timer? _timer;
  bool _isFinished = false;
  int _score = 0;

  final PageController _pageController = PageController();

  @override
  void initState() {
    super.initState();
    _secondsRemaining = widget.durationMins * 60;
    _fetchQuestions();
  }

  Future<void> _fetchQuestions() async {
    try {
      List<dynamic> res = [];

      if (widget.isExam && widget.courseId != null) {
        // Exam Quiz: Fetch ALL questions for this course
        res = await supabase
            .from('quiz_questions')
            .select()
            .eq('course_id', widget.courseId!);
      } else if (!widget.isExam && widget.materialId != null) {
        // Pop Quiz: Try fetching for specific material first
        res = await supabase
            .from('quiz_questions')
            .select()
            .eq('material_id', widget.materialId!);

        // FALLBACK: If AI hasn't generated specific material questions yet, grab course questions
        if (res.isEmpty && widget.courseId != null) {
          res = await supabase
              .from('quiz_questions')
              .select()
              .eq('course_id', widget.courseId!);
        }
      }

      res.shuffle(); // Randomize the pool

      if (mounted) {
        setState(() {
          // Take the requested number of questions (or all if less exist)
          _questions = res.take(widget.questionCount).toList();
          _isLoading = false;
        });
        if (_questions.isNotEmpty) _startTimer();
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
      debugPrint("Quiz fetch error: $e");
    }
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 0 && !_isFinished) {
        setState(() => _secondsRemaining--);
      } else {
        _submitQuiz();
      }
    });
  }

  void _submitQuiz() {
    _timer?.cancel();
    int correct = 0;
    for (int i = 0; i < _questions.length; i++) {
      final q = _questions[i];
      if (_selectedAnswers[i] == q['correct_option']) {
        correct++;
      }
    }
    setState(() {
      _score = correct;
      _isFinished = true;
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  String _formatTime(int seconds) {
    final m = (seconds / 60).floor().toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
          backgroundColor: _bg,
          body: Center(child: CircularProgressIndicator(color: _themeColor)));
    }

    if (_questions.isEmpty) {
      return Scaffold(
        backgroundColor: _bg,
        appBar: AppBar(backgroundColor: _bg, elevation: 0),
        body: const Center(
            child: Text("No questions generated for this yet.",
                style: TextStyle(color: Colors.white54))),
      );
    }

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        automaticallyImplyLeading:
            false, // Force them to finish or explicitly exit
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Q: ${_selectedAnswers.length}/${_questions.length}',
                style: const TextStyle(color: Colors.white54, fontSize: 14)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                  color: _secondsRemaining < 60 && !_isFinished
                      ? Colors.redAccent
                      : _card,
                  borderRadius: BorderRadius.circular(20)),
              child: Text(
                  _isFinished ? "FINISHED" : _formatTime(_secondsRemaining),
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 16)),
            ),
            if (_isFinished)
              IconButton(
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.pop(context))
            else
              TextButton(
                  onPressed: _submitQuiz,
                  child: const Text("SUBMIT",
                      style: TextStyle(
                          color: _themeColor, fontWeight: FontWeight.bold))),
          ],
        ),
      ),
      body: Column(
        children: [
          if (_isFinished)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              color: _themeColor.withOpacity(0.1),
              child: Column(
                children: [
                  const Text('Your Score',
                      style: TextStyle(color: Colors.white54, fontSize: 16)),
                  const SizedBox(height: 8),
                  Text('$_score / ${_questions.length}',
                      style: const TextStyle(
                          color: _themeColor,
                          fontSize: 40,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text('Scroll to review answers below',
                      style: TextStyle(color: Colors.white70)),
                ],
              ),
            ),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: _questions.length,
              itemBuilder: (context, index) {
                final q = _questions[index];
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Question ${index + 1}',
                          style: const TextStyle(
                              color: _themeColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 14)),
                      const SizedBox(height: 12),
                      Text(q['question_text'],
                          style: const TextStyle(
                              color: Colors.white, fontSize: 22, height: 1.4)),
                      const SizedBox(height: 32),
                      _buildOptionTile(
                          index, 'A', q['option_a'], q['correct_option']),
                      _buildOptionTile(
                          index, 'B', q['option_b'], q['correct_option']),
                      _buildOptionTile(
                          index, 'C', q['option_c'], q['correct_option']),
                    ],
                  ),
                );
              },
            ),
          ),
          if (!_isFinished)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios, color: Colors.white),
                    onPressed: () => _pageController.previousPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut),
                  ),
                  IconButton(
                    icon: const Icon(Icons.arrow_forward_ios,
                        color: Colors.white),
                    onPressed: () => _pageController.nextPage(
                        duration: const Duration(milliseconds: 300),
                        curve: Curves.easeInOut),
                  ),
                ],
              ),
            )
        ],
      ),
    );
  }

  Widget _buildOptionTile(int questionIndex, String optionLetter,
      String optionText, String correctOption) {
    final bool isSelected = _selectedAnswers[questionIndex] == optionLetter;

    Color boxColor = _card;
    Color borderColor = Colors.transparent;
    Color textColor = Colors.white;

    if (_isFinished) {
      if (optionLetter == correctOption) {
        boxColor = Colors.green.withOpacity(0.2);
        borderColor = Colors.green;
        textColor = Colors.greenAccent;
      } else if (isSelected) {
        boxColor = Colors.red.withOpacity(0.2);
        borderColor = Colors.red;
        textColor = Colors.redAccent;
      }
    } else if (isSelected) {
      boxColor = _themeColor.withOpacity(0.2);
      borderColor = _themeColor;
    }

    return GestureDetector(
      onTap: _isFinished
          ? null
          : () {
              setState(() => _selectedAnswers[questionIndex] = optionLetter);
              // Auto advance after 500ms
              Future.delayed(const Duration(milliseconds: 500), () {
                if (mounted &&
                    _pageController.page!.round() < _questions.length - 1) {
                  _pageController.nextPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut);
                }
              });
            },
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: boxColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: borderColor, width: 2),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: borderColor == Colors.transparent
                  ? Colors.white10
                  : borderColor,
              child: Text(optionLetter,
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(width: 16),
            Expanded(
                child: Text(optionText,
                    style: TextStyle(color: textColor, fontSize: 16))),
            if (_isFinished && optionLetter == correctOption)
              const Icon(Icons.check_circle, color: Colors.green)
            else if (_isFinished && isSelected)
              const Icon(Icons.cancel, color: Colors.red)
          ],
        ),
      ),
    );
  }
}
