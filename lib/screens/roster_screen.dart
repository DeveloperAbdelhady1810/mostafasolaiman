import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config.dart';
import '../models/course.dart';
import '../providers/attendance_provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/student_tile.dart';
import 'qr_scan_screen.dart';
import 'student_search_screen.dart';
import 'summary_screen.dart';

class RosterScreen extends StatefulWidget {
  final AttendanceCourse course;

  const RosterScreen({super.key, required this.course});

  @override
  State<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends State<RosterScreen> {
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  String? get _token => context.read<AuthProvider>().token;

  Future<void> _load() async {
    final token = _token;
    if (token == null) return;
    await context.read<AttendanceProvider>().loadRoster(token, widget.course);
  }

  Future<void> _scanQr() async {
    final scanned = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (scanned == null || !mounted) return;

    if (!scanned.startsWith(qrCodePrefix)) {
      _showSnack('That code is not a recognized student QR code.', isError: true);
      return;
    }

    final numberPart = scanned.substring(qrCodePrefix.length);
    final studentNumber = int.tryParse(numberPart);
    if (studentNumber == null) {
      _showSnack('That code is not a recognized student QR code.', isError: true);
      return;
    }

    final attendance = context.read<AttendanceProvider>();
    final match = attendance.markPresentByStudentNumber(studentNumber);
    if (match != null) {
      _showSnack('${match.name} marked present.');
    } else {
      // Not on this course's expected roster (wrong grade/center, or a
      // walk-in never assigned a center) - fall back to a real search so
      // the assistant can still add them.
      _showSnack('Student #$studentNumber isn\'t on this roster - searching…');
      final token = _token;
      if (token != null) {
        final results = await attendance.searchStudents(token, studentNumber.toString());
        final found = results.where((s) => s.studentNumber == studentNumber).firstOrNull;
        if (found != null) {
          attendance.addOrMarkPresent(found);
          _showSnack('${found.name} added and marked present.');
        } else {
          _showSnack('No student found with that QR code.', isError: true);
        }
      }
    }
  }

  Future<void> _addWalkIn() async {
    final picked = await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const StudentSearchScreen()),
    );
    if (picked == null || !mounted) return;
    context.read<AttendanceProvider>().addOrMarkPresent(picked);
  }

  Future<void> _editQuizMaxMark() async {
    final attendance = context.read<AttendanceProvider>();
    final controller = TextEditingController(
      text: attendance.selectedCourse?.quizMaxMark?.toString() ?? '',
    );

    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Quiz Scale for This Course'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Max mark (e.g. 10)'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(int.tryParse(controller.text)),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (result == null || result <= 0) return;
    final token = _token;
    if (token == null) return;
    final success = await attendance.updateQuizMaxMark(token, result);
    if (!mounted) return;
    if (success) {
      setState(() {});
    } else if (attendance.error != null) {
      _showSnack(attendance.error!, isError: true);
    }
  }

  Future<void> _submit() async {
    final attendance = context.read<AttendanceProvider>();
    if (attendance.roster.isEmpty) {
      _showSnack('No students to submit.', isError: true);
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Submit Attendance?'),
        content: Text(
          '${attendance.roster.where((s) => s.status == "present").length} present, '
          '${attendance.roster.where((s) => s.status == "absent").length} absent. '
          'This can be edited later by resubmitting.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Submit')),
        ],
      ),
    );
    if (confirmed != true) return;

    final token = _token;
    if (token == null) return;

    setState(() => _submitting = true);
    final result = await attendance.submitAttendance(token);
    setState(() => _submitting = false);

    if (!mounted) return;
    if (result != null) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SummaryScreen(result: result)),
      );
    } else if (attendance.error != null) {
      _showSnack(attendance.error!, isError: true);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: isError ? Colors.red.shade600 : null),
    );
  }

  @override
  Widget build(BuildContext context) {
    final attendance = context.watch<AttendanceProvider>();
    final quizMaxMark = attendance.selectedCourse?.quizMaxMark;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.course.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.rule),
            tooltip: 'Quiz scale',
            onPressed: _editQuizMaxMark,
          ),
        ],
      ),
      body: attendance.isLoading
          ? const Center(child: CircularProgressIndicator())
          : attendance.error != null
              ? Center(child: Text(attendance.error!))
              : Column(
                  children: [
                    if (attendance.sessionStatus == 'submitted')
                      Container(
                        width: double.infinity,
                        color: Colors.blue.shade50,
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          'This session was already submitted - editing and resubmitting will update it.',
                          style: TextStyle(color: Colors.blue.shade800, fontSize: 13),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _scanQr,
                              icon: const Icon(Icons.qr_code_scanner),
                              label: const Text('Scan QR'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _addWalkIn,
                              icon: const Icon(Icons.person_add_alt),
                              label: const Text('Add Walk-in'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: attendance.roster.isEmpty
                          ? const Center(child: Text('No students expected for this course/center yet.'))
                          : ListView.builder(
                              padding: const EdgeInsets.symmetric(horizontal: 12),
                              itemCount: attendance.roster.length,
                              itemBuilder: (context, index) {
                                final student = attendance.roster[index];
                                return StudentTile(
                                  student: student,
                                  quizMaxMark: quizMaxMark,
                                  onChanged: () => setState(() {}),
                                );
                              },
                            ),
                    ),
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: FilledButton.icon(
                            onPressed: _submitting ? null : _submit,
                            icon: _submitting
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Icon(Icons.check),
                            label: const Text('Submit Attendance'),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}
