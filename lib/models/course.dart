class AttendanceCourse {
  final int id;
  final String title;
  final String? stage;
  final String? grade;
  final String? division;
  final String? subject;
  int? quizMaxMark;
  final int expectedCount;

  AttendanceCourse({
    required this.id,
    required this.title,
    this.stage,
    this.grade,
    this.division,
    this.subject,
    this.quizMaxMark,
    this.expectedCount = 0,
  });

  factory AttendanceCourse.fromJson(Map<String, dynamic> json) {
    return AttendanceCourse(
      id: json['id'] as int,
      title: json['title'] as String,
      stage: json['stage'] as String?,
      grade: json['grade'] as String?,
      division: json['division'] as String?,
      subject: json['subject'] as String?,
      quizMaxMark: json['quiz_max_mark'] as int?,
      expectedCount: (json['expected_count'] as int?) ?? 0,
    );
  }
}

class FilterOption {
  final String value;
  final String label;
  final String? stage;

  FilterOption({required this.value, required this.label, this.stage});

  factory FilterOption.fromJson(Map<String, dynamic> json) {
    return FilterOption(
      value: json['value'] as String,
      label: json['label'] as String,
      stage: json['stage'] as String?,
    );
  }
}
