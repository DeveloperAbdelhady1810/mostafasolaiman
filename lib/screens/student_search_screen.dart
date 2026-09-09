import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/roster_student.dart';
import '../providers/attendance_provider.dart';
import '../providers/auth_provider.dart';

/// Pops with the picked RosterStudent, or null if the user backs out.
/// Used to find a walk-in who isn't on the expected roster (e.g. a student
/// whose home center doesn't match, or who registered but was never
/// assigned one) - see AssistantController::searchStudents() for why this
/// deliberately searches every student on the platform, not just this
/// course's expected roster.
class StudentSearchScreen extends StatefulWidget {
  const StudentSearchScreen({super.key});

  @override
  State<StudentSearchScreen> createState() => _StudentSearchScreenState();
}

class _StudentSearchScreenState extends State<StudentSearchScreen> {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<RosterStudent> _results = [];
  bool _searching = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _search(value));
  }

  Future<void> _search(String query) async {
    final token = context.read<AuthProvider>().token;
    if (token == null || query.trim().length < 2) {
      setState(() => _results = []);
      return;
    }

    setState(() => _searching = true);
    final results = await context.read<AttendanceProvider>().searchStudents(token, query);
    if (!mounted) return;
    setState(() {
      _results = results;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Find a Student'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _onChanged,
              decoration: const InputDecoration(
                labelText: 'Name, phone, email, or student number',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          if (_searching) const LinearProgressIndicator(),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Text(
                      _controller.text.trim().length < 2
                          ? 'Type at least 2 characters to search.'
                          : 'No students found.',
                      style: TextStyle(color: Colors.grey.shade600),
                    ),
                  )
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, index) {
                      final student = _results[index];
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.person)),
                        title: Text(student.name),
                        subtitle: Text([
                          if (student.studentNumber != null) '#${student.studentNumber}',
                          if (student.phone != null) student.phone!,
                        ].join(' · ')),
                        onTap: () => Navigator.of(context).pop(student),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
