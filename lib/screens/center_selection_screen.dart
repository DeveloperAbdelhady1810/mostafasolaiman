import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/center.dart';
import '../providers/attendance_provider.dart';
import '../providers/auth_provider.dart';
import 'course_list_screen.dart';
import 'zoom_home_screen.dart';

class CenterSelectionScreen extends StatefulWidget {
  const CenterSelectionScreen({super.key});

  @override
  State<CenterSelectionScreen> createState() => _CenterSelectionScreenState();
}

class _CenterSelectionScreenState extends State<CenterSelectionScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final token = context.read<AuthProvider>().token;
    if (token == null) return;
    await context.read<AttendanceProvider>().loadCenters(token);
  }

  void _selectCenter(AttendanceCenter center) {
    final attendance = context.read<AttendanceProvider>();
    attendance.selectedCenter = center;
    attendance.resetCourseSelection();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const CourseListScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final attendance = context.watch<AttendanceProvider>();
    final auth = context.watch<AuthProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a Center'),
        actions: [
          IconButton(
            icon: const Icon(Icons.videocam),
            tooltip: 'Zoom students',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ZoomHomeScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => auth.logout(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: attendance.isLoading
            ? const Center(child: CircularProgressIndicator())
            : attendance.error != null
                ? _ErrorState(message: attendance.error!, onRetry: _load)
                : attendance.centers.isEmpty
                    ? const Center(child: Text('No centers found for your account.'))
                    : ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: attendance.centers.length,
                        itemBuilder: (context, index) {
                          final center = attendance.centers[index];
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: ListTile(
                              leading: const CircleAvatar(child: Icon(Icons.location_city)),
                              title: Text(center.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                              subtitle: center.address != null ? Text(center.address!) : null,
                              trailing: const Icon(Icons.chevron_right),
                              onTap: () => _selectCenter(center),
                            ),
                          );
                        },
                      ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;

  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
