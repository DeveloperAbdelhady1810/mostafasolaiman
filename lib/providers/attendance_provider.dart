import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config.dart';
import '../models/center.dart';
import '../models/course.dart';
import '../models/roster_student.dart';
import '../models/scan.dart';
import '../services/api_client.dart';
import '../services/api_exception.dart';

class AttendanceProvider extends ChangeNotifier {
  AttendanceProvider({ApiClient? api}) : _api = api ?? ApiClient();

  final ApiClient _api;

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

  // ── rotating-code scanning ────────────────────────────────────────────────

  /// Server says the rotating student codes / Bluetooth attendance are switched on.
  bool bleEnabled = false;

  /// Detections that could not be verified yet (no connection). Persisted.
  final List<PendingScan> pendingScans = [];

  /// Roster students shown as present only because their scan is still waiting to be verified.
  final Set<int> unverifiedStudentIds = {};

  /// Student numbers the server confirmed during this roster session (for the duplicate check).
  final Set<int> _verifiedStudentNos = {};

  bool _pendingLoaded = false;
  static const _pendingKey = 'pending_scans';
  static const _bulkChunk = 300; // server limit per request

  void _setLoading(bool value) {
    isLoading = value;
    notifyListeners();
  }

  void clearError() {
    error = null;
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
      final today = _today();
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
      _verifiedStudentNos.clear();
      unverifiedStudentIds.clear();
      await _ensurePendingLoaded();
      _restorePendingOntoRoster();
      _setLoading(false);
      return true;
    } catch (e) {
      error = e is ApiException ? e.message : 'Could not load the roster.';
      _setLoading(false);
      return false;
    }
  }

  /// Asks the server which optional features are on (rotating codes / Bluetooth).
  /// Harmless on platforms without the endpoint: it simply stays off.
  Future<void> loadFeatures(String token) async {
    try {
      final result = await _api.get('/assistant/ble/features', token: token);
      bleEnabled = result['ble_enabled'] == true;
      notifyListeners();
    } on ApiException {
      bleEnabled = false;
      notifyListeners();
    } catch (_) {
      // offline: keep what we knew
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

  // ───────────────────────────── scanning ─────────────────────────────────

  /// Handles one scanned QR text: the new rotating code (verified by the server) or the
  /// old static `LQ-` ID code (matched against the roster, exactly as before).
  Future<ScanFeedback> handleScan(String token, String raw) async {
    final text = raw.trim();
    if (text.startsWith(rotatingQrPrefix)) return _handleRotating(token, text);
    if (text.startsWith(qrCodePrefix)) return _handleLegacy(token, text);
    return const ScanFeedback(ScanKind.invalid, 'That code is not a recognized student QR code.');
  }

  Future<ScanFeedback> _handleLegacy(String token, String text) async {
    final studentNumber = int.tryParse(text.substring(qrCodePrefix.length));
    if (studentNumber == null) {
      return const ScanFeedback(ScanKind.invalid, 'That code is not a recognized student QR code.');
    }

    final already = roster.where((s) => s.studentNumber == studentNumber && s.status == 'present').firstOrNull;
    if (already != null && !unverifiedStudentIds.contains(already.id)) {
      return ScanFeedback(ScanKind.duplicate, '${already.name} is already marked present.');
    }

    final match = markPresentByStudentNumber(studentNumber);
    if (match != null) return ScanFeedback(ScanKind.verified, '${match.name} marked present.');

    // Not on this course's expected roster (wrong grade/center, or a walk-in
    // never assigned a center) - fall back to a real search so the assistant can still add them.
    final results = await searchStudents(token, studentNumber.toString());
    error = null; // a failed search must not replace the roster with an error page
    final found = results.where((s) => s.studentNumber == studentNumber).firstOrNull;
    if (found == null) {
      return const ScanFeedback(ScanKind.rejected, 'No student found with that QR code.');
    }
    addOrMarkPresent(found);
    return ScanFeedback(ScanKind.verified, '${found.name} added and marked present.');
  }

  Future<ScanFeedback> _handleRotating(String token, String text) async {
    final code = RotatingCode.tryParse(text);
    if (code == null) {
      return const ScanFeedback(ScanKind.invalid, 'That code is not a recognized student QR code.');
    }
    final course = selectedCourse;
    final center = selectedCenter;
    if (course == null || center == null) {
      return const ScanFeedback(ScanKind.invalid, 'Open a course first, then scan.');
    }

    final known = roster.where((s) => s.studentNumber == code.studentNo).firstOrNull;
    final label = known?.name ?? 'Student #${code.studentNo}';

    if (_verifiedStudentNos.contains(code.studentNo)) {
      return ScanFeedback(ScanKind.duplicate, '$label is already marked present.');
    }
    if (pendingScans.any((p) => p.studentNo == code.studentNo && p.courseId == course.id && p.centerId == center.id)) {
      return ScanFeedback(ScanKind.duplicate, '$label is already waiting to be verified.');
    }

    final scan = PendingScan(
      courseId: course.id,
      centerId: center.id,
      date: _today(),
      studentNo: code.studentNo,
      mac: code.mac,
      detectedAt: ApiClient.serverNow(),
    );

    try {
      final result = await _sendBulk([scan], token);
      final feedback = _applyBulkResult([scan], result, single: scan);
      await _savePending();
      if (pendingScans.isNotEmpty) unawaited(flushPending(token)); // we are online: clear any backlog too
      return feedback;
    } on ApiException catch (e) {
      if (_cannotEverVerify(e)) {
        if (e.statusCode == 403) bleEnabled = false;
        notifyListeners();
        return ScanFeedback(
          ScanKind.rejected,
          e.statusCode == 403
              ? 'Secure codes are not enabled for this course yet.'
              : e.message,
        );
      }
      return ScanFeedback(ScanKind.rejected, e.message);
    } catch (_) {
      // No connection: remember it, show the student as present (unverified) and verify later.
      pendingScans.add(scan);
      if (known != null) {
        known.status = 'present';
        unverifiedStudentIds.add(known.id);
      }
      await _savePending();
      notifyListeners();
      return ScanFeedback(ScanKind.pending, '$label saved - will be verified when you are online.');
    }
  }

  /// 403 (not allowed / feature off), 404 or 422: retrying the same request can never succeed.
  bool _cannotEverVerify(ApiException e) => e.statusCode == 403 || e.statusCode == 404 || e.statusCode == 422;

  Future<Map<String, dynamic>> _sendBulk(List<PendingScan> scans, String token) async {
    final first = scans.first;
    final result = await _api.post('/assistant/attendance/bulk', token: token, body: {
      'course_id': first.courseId,
      'center_id': first.centerId,
      'date': first.date,
      'entries': scans.map((s) => s.toEntryJson()).toList(),
    });
    return Map<String, dynamic>.from(result as Map);
  }

  /// Applies the server's accepted/rejected lists to the roster and the pending queue.
  /// When [single] is given, returns the feedback for that one scan.
  ScanFeedback _applyBulkResult(List<PendingScan> sent, Map<String, dynamic> result, {PendingScan? single}) {
    final accepted = ((result['accepted'] as List?) ?? const []).whereType<Map>().toList();
    final rejected = ((result['rejected'] as List?) ?? const []).whereType<Map>().toList();
    ScanFeedback? feedback;

    for (final a in accepted) {
      final no = (a['student_no'] as num).toInt();
      final scan = sent.where((s) => s.studentNo == no).firstOrNull;
      if (scan == null) continue;
      final name = (a['name'] ?? 'Student #$no').toString();
      if (_isCurrentRoster(scan)) _markVerified((a['student_id'] as num).toInt(), no, name);
      if (single != null && no == single.studentNo) {
        feedback = ScanFeedback(ScanKind.verified, '$name verified and marked present.');
      }
    }

    for (final r in rejected) {
      final no = (r['student_no'] as num).toInt();
      final scan = sent.where((s) => s.studentNo == no).firstOrNull;
      if (scan != null && _isCurrentRoster(scan)) _revertUnverified(no);
      if (single != null && no == single.studentNo) {
        feedback = ScanFeedback(ScanKind.rejected, _rejectMessage((r['reason'] ?? '').toString(), no));
      }
    }

    // Everything we sent has an answer now: nothing stays queued.
    pendingScans.removeWhere((p) => sent.any((s) => s.studentNo == p.studentNo && s.groupKey == p.groupKey));
    notifyListeners();

    return feedback ?? const ScanFeedback(ScanKind.rejected, 'The server did not confirm that scan.');
  }

  String _rejectMessage(String reason, int studentNo) {
    switch (reason) {
      case 'bad_token':
        return 'Code expired or not valid - ask the student to show the live code on their phone.';
      case 'unknown_student':
        return 'Student #$studentNo was not found.';
      case 'no_secret':
        return 'Student #$studentNo has not signed in to the new app yet.';
      case 'stale_detection':
        return 'That scan was too old to verify - scan again.';
      default:
        return 'Could not verify student #$studentNo.';
    }
  }

  bool _isCurrentRoster(PendingScan s) =>
      s.courseId == selectedCourse?.id && s.centerId == selectedCenter?.id && s.date == _today();

  void _markVerified(int studentId, int studentNo, String name) {
    _verifiedStudentNos.add(studentNo);
    unverifiedStudentIds.remove(studentId);
    final index = roster.indexWhere((s) => s.id == studentId);
    if (index >= 0) {
      roster[index].status = 'present';
    } else {
      roster.add(RosterStudent(
        id: studentId,
        name: name,
        studentNumber: studentNo,
        status: 'present',
        isWalkIn: true,
      ));
    }
  }

  void _revertUnverified(int studentNo) {
    final student = roster.where((s) => s.studentNumber == studentNo).firstOrNull;
    if (student != null && unverifiedStudentIds.remove(student.id)) {
      student.status = 'absent';
    }
  }

  /// After a roster (re)load: scans still waiting for this course/center show as present again.
  void _restorePendingOntoRoster() {
    for (final p in pendingScans.where(_isCurrentRoster)) {
      final student = roster.where((s) => s.studentNumber == p.studentNo).firstOrNull;
      if (student != null) {
        student.status = 'present';
        unverifiedStudentIds.add(student.id);
      }
    }
  }

  /// Sends every waiting detection to the server. True when nothing is left waiting.
  Future<bool> flushPending(String token) async {
    await _ensurePendingLoaded();
    if (pendingScans.isEmpty) return true;

    final groups = <String, List<PendingScan>>{};
    for (final p in pendingScans) {
      groups.putIfAbsent(p.groupKey, () => []).add(p);
    }

    for (final group in groups.values) {
      for (var i = 0; i < group.length; i += _bulkChunk) {
        final chunk = group.sublist(i, i + _bulkChunk > group.length ? group.length : i + _bulkChunk);
        try {
          final result = await _sendBulk(chunk, token);
          _applyBulkResult(chunk, result);
          await _savePending();
        } on ApiException catch (e) {
          if (_cannotEverVerify(e)) {
            // These can never be verified: drop them and undo their tentative "present".
            for (final s in chunk) {
              if (_isCurrentRoster(s)) _revertUnverified(s.studentNo);
            }
            pendingScans.removeWhere((p) => chunk.any((s) => s.studentNo == p.studentNo && s.groupKey == p.groupKey));
            await _savePending();
            notifyListeners();
          } else {
            return false; // server hiccup: keep them and retry later
          }
        } catch (_) {
          return false; // offline
        }
      }
    }
    return pendingScans.isEmpty;
  }

  Future<void> _ensurePendingLoaded() async {
    if (_pendingLoaded) return;
    _pendingLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_pendingKey);
      if (raw == null) return;
      final list = jsonDecode(raw) as List;
      pendingScans
        ..clear()
        ..addAll(list.whereType<Map>().map((m) => PendingScan.fromJson(Map<String, dynamic>.from(m))));
    } catch (_) {}
  }

  Future<void> _savePending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingKey, jsonEncode(pendingScans.map((p) => p.toJson()).toList()));
    } catch (_) {}
  }

  String _today() => DateTime.now().toIso8601String().split('T').first;

  // ───────────────────────────── quiz / submit ────────────────────────────

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
      // Scans waiting for verification must be answered first, so nobody is submitted as present unverified.
      if (!await flushPending(token)) {
        error = '${pendingScans.length} scan(s) could not be verified yet. Check your connection and try again.';
        _setLoading(false);
        return null;
      }

      final today = _today();
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
    _verifiedStudentNos.clear();
    unverifiedStudentIds.clear();
    notifyListeners();
  }
}
