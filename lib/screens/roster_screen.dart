import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/course.dart';
import '../providers/attendance_provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/student_tile.dart';
import 'qr_scan_screen.dart';
import 'radar_screen.dart';
import 'student_search_screen.dart';
import 'summary_screen.dart';

class RosterScreen extends StatefulWidget {
  final AttendanceCourse course;

  /// Set when the app reopens an unsubmitted session from an earlier day.
  final String? resumeDate;

  const RosterScreen({super.key, required this.course, this.resumeDate});

  @override
  State<RosterScreen> createState() => _RosterScreenState();
}

class _RosterScreenState extends State<RosterScreen> {
  bool _submitting = false;
  late final AttendanceProvider _attendance;

  @override
  void initState() {
    super.initState();
    _attendance = context.read<AttendanceProvider>();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    // Leaving the roster on purpose closes the session; killing the app does not,
    // so the next launch reopens it.
    _attendance.clearSavedSession();
    super.dispose();
  }

  String? get _token => context.read<AuthProvider>().token;

  Future<void> _load() async {
    final token = _token;
    if (token == null) return;
    final attendance = context.read<AttendanceProvider>();
    await attendance.loadRoster(token, widget.course, resumeDate: widget.resumeDate);
    await attendance.loadFeatures(token);
  }

  /// Opens the camera and keeps it open: every code goes to the provider, which
  /// verifies rotating codes with the server and still accepts the old static ID codes.
  Future<void> _scanQr() async {
    final token = _token;
    if (token == null) return;
    final attendance = context.read<AttendanceProvider>();

    final marked = await Navigator.of(context).push<int>(
      MaterialPageRoute(
        builder: (_) => QrScanScreen(
          onCode: (raw) => attendance.handleScan(token, raw),
          secureCodesEnabled: attendance.bleEnabled,
        ),
      ),
    );
    if (!mounted) return;
    if (marked != null && marked > 0) {
      _showSnack('$marked student${marked == 1 ? '' : 's'} marked present.');
    }
  }

  Future<void> _openRadar() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const RadarScreen()));
    if (!mounted) return;
    setState(() {}); // the radar may have marked students present
  }

  Future<void> _retryPending() async {
    final token = _token;
    if (token == null) return;
    final attendance = context.read<AttendanceProvider>();
    final ok = await attendance.flushPending(token);
    if (!mounted) return;
    _showSnack(ok ? 'All scans verified.' : 'Still offline - scans will be verified later.', isError: !ok);
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

    final courseNow = attendance.selectedCourse;
    final centerNow = attendance.selectedCenter;
    final dateNow = attendance.sessionDate;
    setState(() => _submitting = true);
    final result = await attendance.submitAttendance(token);
    setState(() => _submitting = false);

    if (!mounted) return;
    if (result != null) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SummaryScreen(
            result: result,
            token: token,
            courseTitle: courseNow?.title ?? '',
            courseId: courseNow?.id ?? 0,
            centerName: centerNow?.name,
            centerId: centerNow?.id ?? 0,
            date: dateNow,
          ),
        ),
      );
    } else if (attendance.error != null) {
      _showSnack(attendance.error!, isError: true);
      // Keep the roster on screen so the assistant can fix the problem and submit again.
      attendance.clearError();
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
                    if (attendance.isOffline)
                      Container(
                        width: double.infinity,
                        color: Colors.red.shade50,
                        padding: const EdgeInsets.all(10),
                        child: Text(
                          'Offline - showing your last saved progress. Marks are still being saved; Submit needs a connection.',
                          style: TextStyle(color: Colors.red.shade700, fontSize: 12.5, fontWeight: FontWeight.w600),
                          textAlign: TextAlign.center,
                        ),
                      ),
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
                    if (attendance.pendingScans.isNotEmpty)
                      Container(
                        width: double.infinity,
                        color: Colors.amber.shade50,
                        padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                        child: Row(
                          children: [
                            Icon(Icons.schedule_rounded, size: 18, color: Colors.amber.shade900),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${attendance.pendingScans.length} scan(s) waiting to be verified',
                                style: TextStyle(color: Colors.amber.shade900, fontSize: 13),
                              ),
                            ),
                            TextButton(onPressed: _retryPending, child: const Text('Retry')),
                          ],
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
                    if (attendance.bleEnabled)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                        child: SizedBox(
                          width: double.infinity,
                          child: FilledButton.tonalIcon(
                            key: const Key('open_radar'),
                            onPressed: _openRadar,
                            icon: const Icon(Icons.radar_rounded),
                            label: const Text('Classroom Radar (Bluetooth)'),
                          ),
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
                                  unverified: attendance.unverifiedStudentIds.contains(student.id),
                                  onChanged: () {
                                    setState(() {});
                                    attendance.persistNow();
                                  },
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
