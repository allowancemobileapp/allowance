// lib/screens/library/library_screen.dart
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../models/user_preferences.dart';
import 'material_viewer_screen.dart';

const Color _themeColor = Color(0xFF4CAF50);
const Color _bg = Color(0xFF121212);
const Color _card = Color(0xFF1E1E1E);

// ==========================================
// 1. COLLEGES SCREEN
// ==========================================
class LibraryScreen extends StatefulWidget {
  final UserPreferences userPreferences;
  const LibraryScreen({super.key, required this.userPreferences});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final supabase = Supabase.instance.client;
  bool _isLoading = true;
  List<dynamic> _colleges = [];

  @override
  void initState() {
    super.initState();
    _fetchColleges();
  }

  Future<void> _fetchColleges() async {
    final schoolId = widget.userPreferences.schoolId;
    if (schoolId == null || schoolId.isEmpty) {
      setState(() => _isLoading = false);
      return;
    }
    try {
      final res = await supabase
          .from('colleges')
          .select('id, name')
          .eq('school_id', int.parse(schoolId))
          .order('name');
      if (mounted) {
        setState(() {
          _colleges = res;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        centerTitle: true,
        title: const Text('Campus Library 📚',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _themeColor))
          : _colleges.isEmpty
              ? const Center(
                  child: Text('No colleges found for your school yet.',
                      style: TextStyle(color: Colors.white54)))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _colleges.length,
                  itemBuilder: (context, index) {
                    final college = _colleges[index];
                    return GestureDetector(
                      onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => CoursesScreen(
                                  collegeId: college['id'],
                                  collegeName: college['name'],
                                  userPreferences: widget.userPreferences))),
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                            color: _card,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: Colors.white10)),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(
                              child: Text(college['name'],
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold)),
                            ),
                            const Icon(Icons.chevron_right, color: _themeColor),
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

// ==========================================
// 2. COURSES SCREEN
// ==========================================
class CoursesScreen extends StatefulWidget {
  final int collegeId;
  final String collegeName;
  final UserPreferences userPreferences;

  const CoursesScreen(
      {super.key,
      required this.collegeId,
      required this.collegeName,
      required this.userPreferences});

  @override
  State<CoursesScreen> createState() => _CoursesScreenState();
}

class _CoursesScreenState extends State<CoursesScreen> {
  final supabase = Supabase.instance.client;
  List<dynamic> _courses = [];
  List<dynamic> _filteredCourses = [];
  bool _isLoading = true;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _fetchCourses();
  }

  Future<void> _fetchCourses() async {
    try {
      final res = await supabase
          .from('courses')
          .select('*, library_materials(material_type)')
          .eq('college_id', widget.collegeId)
          .order('course_code');
      if (mounted) {
        setState(() {
          _courses = res;
          _filteredCourses = res;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _filterSearch(String query) {
    if (query.isEmpty) {
      setState(() => _filteredCourses = _courses);
      return;
    }
    final q = query.toLowerCase();
    setState(() {
      _filteredCourses = _courses.where((c) {
        final code = (c['course_code'] ?? '').toString().toLowerCase();
        final title = (c['course_title'] ?? '').toString().toLowerCase();
        return code.contains(q) || title.contains(q);
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(widget.collegeName,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: CupertinoSearchTextField(
              controller: _searchController,
              backgroundColor: _card,
              style: const TextStyle(color: Colors.white),
              placeholder: 'Search course code or title...',
              onChanged: _filterSearch,
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: _themeColor))
                : _filteredCourses.isEmpty
                    ? const Center(
                        child: Text('No courses found.',
                            style: TextStyle(color: Colors.white54)))
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        itemCount: _filteredCourses.length,
                        itemBuilder: (context, index) {
                          final course = _filteredCourses[index];
                          final materials =
                              course['library_materials'] as List<dynamic>? ??
                                  [];
                          final pqs = materials
                              .where(
                                  (m) => m['material_type'] == 'past_question')
                              .length;
                          final notes = materials
                              .where((m) => m['material_type'] == 'note')
                              .length;
                          final books = materials
                              .where((m) => m['material_type'] == 'book')
                              .length;

                          return GestureDetector(
                            onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => CourseDetailsScreen(
                                        course: course,
                                        userPreferences:
                                            widget.userPreferences))),
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 12),
                              padding: const EdgeInsets.all(16),
                              decoration: BoxDecoration(
                                  color: _card,
                                  borderRadius: BorderRadius.circular(16)),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                            color: _themeColor.withOpacity(0.2),
                                            borderRadius:
                                                BorderRadius.circular(8)),
                                        child: Text(
                                            course['course_code'].toUpperCase(),
                                            style: const TextStyle(
                                                color: _themeColor,
                                                fontWeight: FontWeight.bold)),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Text(course['course_title'],
                                            style: const TextStyle(
                                                color: Colors.white,
                                                fontSize: 16,
                                                fontWeight: FontWeight.bold),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (course['course_description'] != null)
                                    Padding(
                                      padding:
                                          const EdgeInsets.only(bottom: 8.0),
                                      child: Text(course['course_description'],
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                              color: Colors.white54,
                                              fontSize: 12)),
                                    ),
                                  const Divider(color: Colors.white10),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceAround,
                                    children: [
                                      _buildCountStat('PQs', pqs),
                                      _buildCountStat('Notes', notes),
                                      _buildCountStat('Books', books),
                                    ],
                                  )
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountStat(String label, int count) {
    return Row(
      children: [
        Text(count.toString(),
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
        const SizedBox(width: 4),
        Text(label,
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ],
    );
  }
}

// ==========================================
// 3. COURSE DETAILS SCREEN
// ==========================================
class CourseDetailsScreen extends StatefulWidget {
  final Map<String, dynamic> course;
  final UserPreferences userPreferences;

  const CourseDetailsScreen(
      {super.key, required this.course, required this.userPreferences});

  @override
  State<CourseDetailsScreen> createState() => _CourseDetailsScreenState();
}

class _CourseDetailsScreenState extends State<CourseDetailsScreen> {
  final supabase = Supabase.instance.client;
  int _selectedSegment = 0; // 0 = PQs, 1 = Notes, 2 = Books
  List<dynamic> _materials = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchMaterials();
  }

  Future<void> _fetchMaterials() async {
    try {
      final res = await supabase
          .from('library_materials')
          .select()
          .eq('course_id', widget.course['id'])
          .order('created_at', ascending: false);
      if (mounted) {
        setState(() {
          _materials = res;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    List<dynamic> displayedList = [];
    if (_selectedSegment == 0) {
      displayedList = _materials
          .where((m) => m['material_type'] == 'past_question')
          .toList();
    } else if (_selectedSegment == 1) {
      displayedList =
          _materials.where((m) => m['material_type'] == 'note').toList();
    } else {
      displayedList =
          _materials.where((m) => m['material_type'] == 'book').toList();
    }

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: Text(widget.course['course_code'],
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold)),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SizedBox(
              width: double.infinity,
              child: CupertinoSlidingSegmentedControl<int>(
                backgroundColor: _card,
                thumbColor: const Color(0xFF2A2A2A),
                groupValue: _selectedSegment,
                children: {
                  0: _buildSegText('Past Qs', 0),
                  1: _buildSegText('Notes', 1),
                  2: _buildSegText('Books', 2),
                },
                onValueChanged: (v) {
                  if (v != null) setState(() => _selectedSegment = v);
                },
              ),
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: _themeColor))
                : displayedList.isEmpty
                    ? const Center(
                        child: Text("No materials uploaded here yet.",
                            style: TextStyle(color: Colors.white54)))
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: displayedList.length,
                        itemBuilder: (context, index) {
                          final material = displayedList[index];
                          final price =
                              double.tryParse(material['price'].toString()) ??
                                  0.0;
                          final isPaid = price > 0;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            decoration: BoxDecoration(
                              color: _card,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: ListTile(
                              contentPadding: const EdgeInsets.all(12),
                              leading: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                    color: _themeColor.withOpacity(0.2),
                                    shape: BoxShape.circle),
                                child: Icon(
                                  _selectedSegment == 0
                                      ? Icons.help_outline
                                      : _selectedSegment == 1
                                          ? Icons.edit_document
                                          : Icons.menu_book,
                                  color: _themeColor,
                                ),
                              ),
                              title: Text(material['title'] ?? 'Untitled',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold)),
                              subtitle: Text(
                                  _selectedSegment == 0
                                      ? '${material['academic_year'] ?? 'N/A'} • ${material['semester'] ?? 'N/A'}'
                                      : (isPaid ? 'Premium' : 'Free'),
                                  style:
                                      const TextStyle(color: Colors.white54)),

                              // 🔥 FIX: Replaced Download Icon with standard arrow!
                              trailing: isPaid
                                  ? Text('₦${price.toInt()}',
                                      style: const TextStyle(
                                          color: Colors.amber,
                                          fontWeight: FontWeight.bold))
                                  : const Icon(Icons.arrow_forward_ios,
                                      size: 16, color: Colors.white54),

                              onTap: () {
                                if (isPaid) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                          content: Text(
                                              'Payment integration coming soon!')));
                                  return;
                                }
                                Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => MaterialViewerScreen(
                                            material: material,
                                            userPreferences:
                                                widget.userPreferences)));
                              },
                            ),
                          );
                        },
                      ),
          ),
          SafeArea(
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                  color: _card,
                  border: Border(top: BorderSide(color: Colors.white10))),
              child: ElevatedButton.icon(
                icon: const Icon(Icons.school, color: Colors.black),
                label: const Text('TAKE EXAM QUIZ',
                    style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.bold,
                        fontSize: 16)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _themeColor,
                  minimumSize: const Size(double.infinity, 56),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                ),
                onPressed: () => QuizSetupSheet.show(context,
                    courseId: widget.course['id'],
                    userPreferences: widget.userPreferences,
                    isExam: true),
              ),
            ),
          )
        ],
      ),
    );
  }

  Widget _buildSegText(String t, int index) {
    final sel = _selectedSegment == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(t,
          style: TextStyle(
              color: sel ? Colors.white : Colors.white54,
              fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
    );
  }
}
