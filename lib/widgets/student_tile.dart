import 'package:flutter/material.dart';
import '../models/roster_student.dart';

/// One row in the roster: name + present/absent toggle, with homework and
/// quiz-mark inputs revealed once the student is marked present (matching
/// how the web/desktop attendance apps only ask for those once someone
/// actually showed up).
class StudentTile extends StatelessWidget {
  final RosterStudent student;
  final int? quizMaxMark;
  final VoidCallback onChanged;

  /// Marked present from a scan that has not been verified by the server yet (offline).
  final bool unverified;

  const StudentTile({
    super.key,
    required this.student,
    required this.quizMaxMark,
    required this.onChanged,
    this.unverified = false,
  });

  @override
  Widget build(BuildContext context) {
    final isPresent = student.status == 'present';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      color: student.isWalkIn ? Colors.amber.shade50 : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  backgroundColor: isPresent ? Colors.green.shade100 : Colors.grey.shade200,
                  child: Icon(
                    isPresent ? Icons.check : Icons.person_outline,
                    color: isPresent ? Colors.green.shade700 : Colors.grey.shade600,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(student.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (student.studentNumber != null)
                        Text('#${student.studentNumber}',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                      if (unverified)
                        Text('Waiting to be verified',
                            style: TextStyle(fontSize: 12, color: Colors.amber.shade900, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                Switch(
                  value: isPresent,
                  onChanged: (value) {
                    student.status = value ? 'present' : 'absent';
                    onChanged();
                  },
                ),
              ],
            ),
            if (isPresent) ...[
              const Divider(height: 20),
              Row(
                children: [
                  Expanded(
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          tristate: true,
                          value: student.homeworkDone,
                          onChanged: (value) {
                            student.homeworkDone = value;
                            onChanged();
                          },
                        ),
                        const Flexible(child: Text('Homework done')),
                      ],
                    ),
                  ),
                  if (quizMaxMark != null && quizMaxMark! > 0)
                    SizedBox(
                      width: 90,
                      child: TextFormField(
                        initialValue: student.quizMark?.toString() ?? '',
                        keyboardType: TextInputType.number,
                        decoration: InputDecoration(
                          labelText: 'Quiz /$quizMaxMark',
                          isDense: true,
                          border: const OutlineInputBorder(),
                        ),
                        onChanged: (value) {
                          student.quizMark = int.tryParse(value);
                          onChanged();
                        },
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
