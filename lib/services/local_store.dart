import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/roster_student.dart';

/// What the phone remembers so attendance survives the app being closed or the
/// connection dropping: the roster with every mark (present/absent, homework,
/// quiz mark, walk-ins) for one course/center/day, kept until it is submitted.
/// Small data, so plain shared preferences - no database needed.
class LocalStore {
  static String _rosterKey(int courseId, int centerId, String date) => 'roster_${courseId}_${centerId}_$date';

  static Map<String, dynamic> _toJson(RosterStudent s) => {
        'id': s.id,
        'name': s.name,
        'email': s.email,
        'phone': s.phone,
        'student_number': s.studentNumber,
        'parent_phone': s.parentPhone,
        'status': s.status,
        'homework_done': s.homeworkDone,
        'quiz_mark': s.quizMark,
        'is_walk_in': s.isWalkIn,
        'is_makeup': s.isMakeup,
        'attended_elsewhere': s.attendedElsewhere,
        'group_name': s.groupName,
      };

  static RosterStudent _fromJson(Map<String, dynamic> j) => RosterStudent(
        id: j['id'] as int,
        name: j['name'] as String,
        email: j['email'] as String?,
        phone: j['phone'] as String?,
        studentNumber: j['student_number'] as int?,
        parentPhone: j['parent_phone'] as String?,
        status: (j['status'] as String?) ?? 'absent',
        homeworkDone: j['homework_done'] as bool?,
        quizMark: j['quiz_mark'] as int?,
        isWalkIn: j['is_walk_in'] == true,
        isMakeup: j['is_makeup'] == true,
        attendedElsewhere: j['attended_elsewhere'] == true,
        groupName: j['group_name'] as String?,
      );

  static Future<void> saveRoster(int courseId, int centerId, String date, List<RosterStudent> students) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_rosterKey(courseId, centerId, date), jsonEncode(students.map(_toJson).toList()));
    } catch (_) {}
  }

  /// The saved roster, or null when nothing was saved for it.
  static Future<List<RosterStudent>?> loadRoster(int courseId, int centerId, String date) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_rosterKey(courseId, centerId, date));
      if (raw == null) return null;
      final list = (jsonDecode(raw) as List).map((e) => _fromJson(Map<String, dynamic>.from(e as Map))).toList();
      return list.isEmpty ? null : list;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearRoster(int courseId, int centerId, String date) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_rosterKey(courseId, centerId, date));
    } catch (_) {}
  }

  // ── lists shown before a roster is opened (centers, filters, courses) ──

  static Future<void> saveCache(String key, Map<String, dynamic> value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cache_$key', jsonEncode(value));
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> loadCache(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('cache_$key');
      return raw == null ? null : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  // ── which session is open (so reopening the app lands back in it) ──

  static const _sessionKey = 'open_session';

  static Future<void> saveSession(Map<String, dynamic> value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_sessionKey, jsonEncode(value));
    } catch (_) {}
  }

  static Future<Map<String, dynamic>?> loadSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_sessionKey);
      return raw == null ? null : Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clearSession() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionKey);
    } catch (_) {}
  }
}
