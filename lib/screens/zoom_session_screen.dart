import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/roster_student.dart';
import '../providers/auth_provider.dart';
import '../services/api_client.dart';
import '../services/api_exception.dart';
import '../widgets/student_tile.dart';
import 'summary_screen.dart';

/// One Zoom lesson for one Zoom group. Members are the roster; a student
/// from another group who missed their own session can be added as a
/// makeup visitor (the server flags it and counts the lesson as attended).
class ZoomSessionScreen extends StatefulWidget {
  final int lessonId;
  final String lessonTitle;
  final int? quizMax;
  final int groupId;
  final String groupName;

  /// Injectable for tests.
  final ApiClient? api;

  const ZoomSessionScreen({
    super.key,
    required this.lessonId,
    required this.lessonTitle,
    required this.quizMax,
    required this.groupId,
    required this.groupName,
    this.api,
  });

  @override
  State<ZoomSessionScreen> createState() => _ZoomSessionScreenState();
}

class _ZoomSessionScreenState extends State<ZoomSessionScreen> {
  late final ApiClient _api = widget.api ?? ApiClient();
  List<RosterStudent> _roster = [];
  bool _loading = true;
  bool _submitting = false;
  bool _alreadySubmitted = false;
  String? _error;
  String _query = '';

  String get _base => '/assistant/zoom/lessons/${widget.lessonId}/groups/${widget.groupId}';
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
      final data = await _api.get('$_base/roster', token: _token);
      if (!mounted) return;
      setState(() {
        _roster = (data['students'] as List).map((e) => RosterStudent.fromJson(e as Map<String, dynamic>)).toList();
        _alreadySubmitted = data['session_status'] == 'submitted';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _msg(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _present => _roster.where((s) => s.status == 'present').length;

  List<RosterStudent> get _filtered {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return _roster;
    return _roster.where((s) => s.name.toLowerCase().contains(q) || (s.phone ?? '').contains(q)).toList();
  }

  Future<void> _addMakeup() async {
    final token = _token;
    final picked = await showDialog<RosterStudent>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        List<RosterStudent> results = [];
        String? msg;
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: const Text('Add a makeup student'),
            content: SizedBox(
              width: double.maxFinite,
              height: 320,
              child: Column(
                children: [
                  TextField(
                    controller: ctrl,
                    autofocus: true,
                    decoration: const InputDecoration(hintText: 'Search name, phone or email', prefixIcon: Icon(Icons.search)),
                    onChanged: (v) async {
                      if (v.trim().length < 2) {
                        setD(() => results = []);
                        return;
                      }
                      try {
                        final data = await _api.get('/assistant/zoom/students/search', token: token, query: {'q': v.trim()});
                        final r = (data['students'] as List).map((e) => RosterStudent.fromJson(e as Map<String, dynamic>)).toList();
                        setD(() {
                          results = r;
                          msg = r.isEmpty ? 'No Zoom student found.' : null;
                        });
                      } catch (_) {
                        setD(() => msg = "Couldn't search. Check your connection.");
                      }
                    },
                  ),
                  if (msg != null) Padding(padding: const EdgeInsets.all(12), child: Text(msg!)),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final s in results)
                          ListTile(
                            title: Text(s.name),
                            subtitle: Text(s.groupName != null ? 'Group ${s.groupName}' : 'No group'),
                            onTap: () => Navigator.pop(ctx, s),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
          ),
        );
      },
    );
    if (picked == null || !mounted) return;
    if (_roster.any((s) => s.id == picked.id)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Already in this session.')));
      return;
    }
    setState(() {
      picked.status = 'present';
      picked.isMakeup = true;
      _roster.add(picked);
    });
  }

  Future<void> _submit() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(_alreadySubmitted ? 'Update this session?' : 'Submit this session?'),
        content: Text('$_present present out of ${_roster.length} on the list.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(_alreadySubmitted ? 'Update' : 'Submit')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _submitting = true);
    try {
      final result = await _api.post('$_base/submit', token: _token, body: {
        'records': _roster.map((s) => s.toRecordJson()).toList(),
      });
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (_) => SummaryScreen(result: result as Map<String, dynamic>)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_msg(e))));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.lessonTitle} - ${widget.groupName}', overflow: TextOverflow.ellipsis),
        actions: [
          if (!_loading && _error == null)
            IconButton(icon: const Icon(Icons.swap_horiz), tooltip: 'Add makeup student', onPressed: _addMakeup),
        ],
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
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: Row(children: [
                        Text('$_present present / ${_roster.length}', style: const TextStyle(fontWeight: FontWeight.w600)),
                        const Spacer(),
                        if (_alreadySubmitted) Text('already submitted', style: TextStyle(color: Colors.orange.shade800, fontSize: 12)),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: TextField(
                        decoration: const InputDecoration(
                          hintText: 'Search',
                          prefixIcon: Icon(Icons.search),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() => _query = v),
                      ),
                    ),
                    Expanded(
                      child: _roster.isEmpty
                          ? const Center(child: Text('This group has no students yet.'))
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 96),
                              itemCount: _filtered.length,
                              itemBuilder: (context, i) {
                                final s = _filtered[i];
                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (s.isMakeup)
                                      Padding(
                                        padding: const EdgeInsets.only(left: 4, bottom: 2),
                                        child: Text('Makeup - from another group',
                                            style: TextStyle(color: Colors.green.shade700, fontSize: 12, fontWeight: FontWeight.w600)),
                                      ),
                                    if (!s.isMakeup && s.attendedElsewhere && s.status != 'present')
                                      Padding(
                                        padding: const EdgeInsets.only(left: 4, bottom: 2),
                                        child: Text('Already attended this lesson in another group',
                                            style: TextStyle(color: Colors.orange.shade800, fontSize: 12, fontWeight: FontWeight.w600)),
                                      ),
                                    StudentTile(student: s, quizMaxMark: widget.quizMax, onChanged: () => setState(() {})),
                                  ],
                                );
                              },
                            ),
                    ),
                  ],
                ),
      floatingActionButton: (_loading || _error != null)
          ? null
          : FloatingActionButton.extended(
              onPressed: _submitting ? null : _submit,
              icon: const Icon(Icons.check_circle),
              label: Text(_submitting ? 'Submitting...' : (_alreadySubmitted ? 'Update Session' : 'Submit Session')),
            ),
    );
  }
}
