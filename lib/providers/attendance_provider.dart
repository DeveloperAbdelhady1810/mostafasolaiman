import 'package:flutter/foundation.dart';
import '../models/center.dart';
import '../models/course.dart';
import '../models/roster_student.dart';
import '../services/api_client.dart';
import '../services/api_exception.dart';

class AttendanceProvider extends ChangeNotifier {
  final ApiClient _api = ApiClient();

  List<AttendanceCenter> centers = [];
  List<FilterOption> stages = [];
  List<FilterOption> grades = [];
  List<AttendanceCourse> courses = [];

  AttendanceCenter? selectedCenter;
  String? selectedStage;
  String? selectedGrade;
  AttendanceCourse? selectedCourse;

  List<RosterStudent> roster = [];
  int? sessionId;
  String? sessionStatus;

  bool isLoading = false;
  String? error;

  void _setLoading(bool value) {
    isLoading = value;
    notifyListeners();
  }

  Future<bool> loadCenters(String token) async {
    _setLoading(true);
    error = null;
    try {
      final result = await _api.get('/assistant/centers', token: token);
      centers = (result['centers'] as List)
          .map((c) => AttendanceCenter.fromJson(c as Map<String, dynamic>))
          .toList();
      _setLoading(false);
      return true;
    } catch (e) {
      error = e is ApiException ? e.message : 'Could not load centers.';
      _setLoading(false);
      return false;
    }
  }

  Future<bool> loadFilters(String token) async {
    _setLoading(true);
    error = null;
    try {
      final result = await _api.get('/assistant/filters', token: token);
      stages = (result['stages'] as List)
          .map((s) => FilterOption.fromJson(s as Map<String, dynamic>))
          .toList();
      grades = (result['grades'] as List)
          .map((g) => FilterOption.fromJson(g as Map<String, dynamic>))
          .toList();
      _setLoading(false);
      return true;
    } catch (e) {
      error = e is ApiException ? e.message : 'Could not load filters.';
      _setLoading(false);
      return false;
    }
  }

  Future<bool> loadCourses(String token) async {
    _setLoading(true);
    error = null;
    try {
      final result = await _api.get('/assistant/courses', token: token, query: {
        if (selectedStage != null) 'stage': selectedStage!,
        if (selectedGrade != null) 'grade': selectedGrade!,
        if (selectedCenter != null) 'center_id': selectedCenter!.id.toString(),
      });
      courses = (result['courses'] as List)
          .map((c) => AttendanceCourse.fromJson(c as Map<String, dynamic>))
          .toList();
      _setLoading(false);
      return true;
    } catch (e) {
      error = e is ApiException ? e.message : 'Could not load courses.';
      _setLoading(false);
      return false;
    }
  }

  Future<bool> loadRoster(String token, AttendanceCourse course) async {
    if (selectedCenter == null) return false;
    _setLoading(true);
    error = null;
    selectedCourse = course;
    try {
      final today = DateTime.now().toIso8601String().split('T').first;
      final result = await _api.get(
        '/assistant/courses/${course.id}/roster',
        token: token,
        query: {'center_id': selectedCenter!.id.toString(), 'date': today},
      );
      roster = (result['students'] as List)
          .map((s) => RosterStudent.fromJson(s as Map<String, dynamic>))
          .toList();
      sessionId = result['session_id'] as int?;
      sessionStatus = result['session_status'] as String?;
      _setLoading(false);
      return true;
    } catch (e) {
      error = e is ApiException ? e.message : 'Could not load the roster.';
      _setLoading(false);
      return false;
    }
  }

  /// Marks a student present by matching a scanned QR code's student number
  /// against the already-loaded roster - no extra API call needed, the
  /// roster response already carries every expected student's number.
  /// Returns the matched student, or null if nobody in the roster matches
  /// (the app then falls back to a manual server-side search).
  RosterStudent? markPresentByStudentNumber(int studentNumber) {
    final match = roster.where((s) => s.studentNumber == studentNumber).firstOrNull;
    if (match != null) {
      match.status = 'present';
      notifyListeners();
    }
    return match;
  }

  Future<List<RosterStudent>> searchStudents(String token, String query) async {
    if (query.trim().length < 2) return [];
    try {
      final result = await _api.get('/assistant/students/search', token: token, query: {'q': query});
      return (result['students'] as List)
          .map((s) => RosterStudent.fromSearchJson(s as Map<String, dynamic>))
          .toList();
    } catch (e) {
      error = e is ApiException ? e.message : 'Search failed.';
      return [];
    }
  }

  /// Adds a walk-in (from QR scan or manual search) to the roster if they're
  /// not already on it, marking them present either way.
  void addOrMarkPresent(RosterStudent student) {
    final existingIndex = roster.indexWhere((s) => s.id == student.id);
    if (existingIndex >= 0) {
      roster[existingIndex].status = 'present';
    } else {
      roster.add(student);
    }
    notifyListeners();
  }

  Future<bool> updateQuizMaxMark(String token, int maxMark) async {
    if (selectedCourse == null) return false;
    try {
      await _api.put(
        '/assistant/courses/${selectedCourse!.id}/quiz-max-mark',
        token: token,
        body: {'quiz_max_mark': maxMark},
      );
      selectedCourse!.quizMaxMark = maxMark;
      return true;
    } catch (e) {
      error = e is ApiException ? e.message : 'Could not update the quiz scale.';
      notifyListeners();
      return false;
    }
  }

  Future<Map<String, dynamic>?> submitAttendance(String token) async {
    if (selectedCourse == null || selectedCenter == null) return null;
    _setLoading(true);
    error = null;
    try {
      final today = DateTime.now().toIso8601String().split('T').first;
      final result = await _api.post(
        '/assistant/courses/${selectedCourse!.id}/submit',
        token: token,
        body: {
          'center_id': selectedCenter!.id,
          'date': today,
          'records': roster.map((s) => s.toRecordJson()).toList(),
        },
      );
      _setLoading(false);
      return result as Map<String, dynamic>;
    } catch (e) {
      error = e is ApiException ? e.message : 'Could not submit attendance.';
      _setLoading(false);
      return null;
    }
  }

  void resetCourseSelection() {
    selectedStage = null;
    selectedGrade = null;
    courses = [];
    notifyListeners();
  }

  void resetRoster() {
    roster = [];
    selectedCourse = null;
    sessionId = null;
    sessionStatus = null;
    notifyListeners();
  }
}
