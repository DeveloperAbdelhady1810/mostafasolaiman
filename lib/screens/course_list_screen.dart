import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/course.dart';
import '../providers/attendance_provider.dart';
import '../providers/auth_provider.dart';
import 'roster_screen.dart';

class CourseListScreen extends StatefulWidget {
  const CourseListScreen({super.key});

  @override
  State<CourseListScreen> createState() => _CourseListScreenState();
}

class _CourseListScreenState extends State<CourseListScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAll());
  }

  String? get _token => context.read<AuthProvider>().token;

  Future<void> _loadAll() async {
    final token = _token;
    if (token == null) return;
    final attendance = context.read<AttendanceProvider>();
    await attendance.loadFilters(token);
    await attendance.loadCourses(token);
  }

  Future<void> _onFilterChanged() async {
    final token = _token;
    if (token == null) return;
    await context.read<AttendanceProvider>().loadCourses(token);
  }

  void _openCourse(AttendanceCourse course) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RosterScreen(course: course)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final attendance = context.watch<AttendanceProvider>();

    // Only offer grades belonging to the currently-selected stage (or all,
    // if no stage is chosen yet).
    final gradeOptions = attendance.grades
        .where((g) => attendance.selectedStage == null || g.stage == attendance.selectedStage)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(attendance.selectedCenter?.name ?? 'Courses'),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: attendance.selectedStage,
                    decoration: const InputDecoration(labelText: 'Stage', border: OutlineInputBorder()),
                    items: attendance.stages
                        .map((s) => DropdownMenuItem(value: s.value, child: Text(s.label, overflow: TextOverflow.ellipsis)))
                        .toList(),
                    onChanged: (value) {
                      attendance.selectedStage = value;
                      attendance.selectedGrade = null;
                      _onFilterChanged();
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: attendance.selectedGrade,
                    decoration: const InputDecoration(labelText: 'Grade', border: OutlineInputBorder()),
                    items: gradeOptions
                        .map((g) => DropdownMenuItem(value: g.value, child: Text(g.label, overflow: TextOverflow.ellipsis)))
                        .toList(),
                    onChanged: (value) {
                      attendance.selectedGrade = value;
                      _onFilterChanged();
                    },
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _loadAll,
              child: attendance.isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : attendance.error != null
                      ? Center(child: Text(attendance.error!))
                      : attendance.courses.isEmpty
                          ? const Center(child: Text('No courses match this filter.'))
                          : ListView.builder(
                              padding: const EdgeInsets.all(16),
                              itemCount: attendance.courses.length,
                              itemBuilder: (context, index) {
                                final course = attendance.courses[index];
                                return Card(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  child: ListTile(
                                    leading: const CircleAvatar(child: Icon(Icons.menu_book_rounded)),
                                    title: Text(course.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                                    subtitle: Text('${course.expectedCount} students expected'),
                                    trailing: const Icon(Icons.chevron_right),
                                    onTap: () => _openCourse(course),
                                  ),
                                );
                              },
                            ),
            ),
          ),
        ],
      ),
    );
  }
}
