/// A student row in a course's attendance roster. Fields below `status`
/// onward are mutable locally in the app before submit() sends the whole
/// roster back - see AssistantController::submit() on the backend, which
/// re-saves every record every time (not just changed ones).
class RosterStudent {
  final int id;
  final String name;
  final String? email;
  final String? phone;
  final int? studentNumber;
  final String? parentPhone;

  /// 'present' or 'absent'.
  String status;
  bool? homeworkDone;
  int? quizMark;

  /// True for a walk-in added via QR scan or manual search who wasn't in
  /// the original expected-roster response - purely a local UI marker
  /// (e.g. to visually flag them), the backend doesn't need to know.
  bool isWalkIn;

  RosterStudent({
    required this.id,
    required this.name,
    this.email,
    this.phone,
    this.studentNumber,
    this.parentPhone,
    this.status = 'absent',
    this.homeworkDone,
    this.quizMark,
    this.isWalkIn = false,
  });

  factory RosterStudent.fromJson(Map<String, dynamic> json) {
    return RosterStudent(
      id: json['id'] as int,
      name: json['name'] as String,
      email: json['email'] as String?,
      phone: json['phone'] as String?,
      studentNumber: json['student_number'] as int?,
      parentPhone: json['parent_phone'] as String?,
      status: (json['status'] as String?) ?? 'absent',
      homeworkDone: json['homework_done'] as bool?,
      quizMark: json['quiz_mark'] as int?,
    );
  }

  factory RosterStudent.fromSearchJson(Map<String, dynamic> json) {
    return RosterStudent(
      id: json['id'] as int,
      name: json['name'] as String,
      email: json['email'] as String?,
      phone: json['phone'] as String?,
      studentNumber: json['student_number'] as int?,
      parentPhone: json['parent_phone'] as String?,
      status: 'present',
      isWalkIn: true,
    );
  }

  Map<String, dynamic> toRecordJson() {
    return {
      'student_id': id,
      'status': status,
      'homework_done': homeworkDone,
      'quiz_mark': quizMark,
    };
  }
}
