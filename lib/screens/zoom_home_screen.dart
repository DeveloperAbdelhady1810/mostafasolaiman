import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/api_client.dart';
import '../services/api_exception.dart';
import 'zoom_session_screen.dart';

/// Zoom students section: separate from center courses. Lists the Zoom
/// lessons; tapping one asks which Zoom group's session to run.
class ZoomHomeScreen extends StatefulWidget {
  const ZoomHomeScreen({super.key, this.api});

  /// Injectable for tests.
  final ApiClient? api;

  @override
  State<ZoomHomeScreen> createState() => _ZoomHomeScreenState();
}

class _ZoomHomeScreenState extends State<ZoomHomeScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  List<Map<String, dynamic>> _lessons = [];
  List<Map<String, dynamic>> _groups = [];
  bool _loading = true;
  String? _error;

  String? get _token => context.read<AuthProvider>().token;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  String _msg(Object e) => e is ApiException ? e.message : "Couldn't reach the server. Check your connection.";

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final lessons = await _api.get('/assistant/zoom/lessons', token: _token);
      final groups = await _api.get('/assistant/zoom/groups', token: _token);
      if (!mounted) return;
      setState(() {
        _lessons = List<Map<String, dynamic>>.from(lessons['lessons'] as List);
        _groups = List<Map<String, dynamic>>.from(groups['groups'] as List);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _msg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _newLesson() async {
    final title = TextEditingController();
    final quiz = TextEditingController();
    var date = DateTime.now();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('New Zoom lesson'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: title, decoration: const InputDecoration(labelText: 'Lesson title')),
              const SizedBox(height: 12),
              TextField(
                controller: quiz,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Quiz max mark (optional)'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(date.toIso8601String().substring(0, 10)),
                onPressed: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: date,
                    firstDate: DateTime(2024),
                    lastDate: DateTime(2035),
                  );
                  if (picked != null) setD(() => date = picked);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create')),
          ],
        ),
      ),
    );
    if (ok != true || title.text.trim().isEmpty || !mounted) return;
    try {
      await _api.post('/assistant/zoom/lessons', token: _token, body: {
        'title': title.text.trim(),
        'lesson_date': date.toIso8601String().substring(0, 10),
        'quiz_max_mark': int.tryParse(quiz.text),
      });
      await _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_msg(e))));
    }
  }

  Future<void> _pickGroup(Map<String, dynamic> lesson) async {
    if (_groups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No Zoom groups yet - create them from the desktop app.')),
      );
      return;
    }
    final sessions = {
      for (final s in (lesson['sessions'] as List? ?? [])) (s['group_id'] as int): s['status'] as String,
    };
    final group = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('${lesson['title']} - which group?'),
        children: [
          for (final g in _groups)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, g),
              child: Row(
                children: [
                  Expanded(child: Text('Group ${g['name']}  (${g['students_count']})')),
                  if (sessions[g['id']] != null)
                    Text(sessions[g['id']] == 'submitted' ? 'submitted' : 'open',
                        style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                ],
              ),
            ),
        ],
      ),
    );
    if (group == null || !mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ZoomSessionScreen(
        lessonId: lesson['id'] as int,
        lessonTitle: lesson['title'] as String,
        quizMax: lesson['quiz_max_mark'] as int?,
        groupId: group['id'] as int,
        groupName: group['name'] as String,
        api: widget.api,
      ),
    ));
    if (mounted) _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Zoom Students')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _newLesson,
        icon: const Icon(Icons.add),
        label: const Text('New lesson'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(_error!),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _load, child: const Text('Retry')),
                  ]),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _lessons.isEmpty
                      ? ListView(children: const [SizedBox(height: 120), Center(child: Text('No Zoom lessons yet.'))])
                      : ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                          itemCount: _lessons.length,
                          itemBuilder: (context, i) {
                            final l = _lessons[i];
                            final done = (l['sessions'] as List? ?? []).where((s) => s['status'] == 'submitted').length;
                            return Card(
                              margin: const EdgeInsets.only(bottom: 12),
                              child: ListTile(
                                title: Text(l['title'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                                subtitle: Text('${(l['lesson_date'] as String).substring(0, 10)}  -  $done/${_groups.length} groups submitted'),
                                trailing: const Icon(Icons.chevron_right),
                                onTap: () => _pickGroup(l),
                              ),
                            );
                          },
                        ),
                ),
    );
  }
}
