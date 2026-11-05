import 'dart:async';

import 'package:flutter/material.dart';

/// Official WhatsApp sending for a submitted attendance session (second option besides the assistant's own
/// linked number). The assistant picks one of the REAL approved templates of the school's WhatsApp account and
/// presses Send. Two modes, decided by the server for each template:
///  - person: sent one parent at a time, so every variable can use THAT student's own value (name, present /
///    absent, homework, quiz mark ...). Needs a one-time sender setup for the template.
///  - campaign: one text for everybody, sent as a single campaign.
/// The app never talks to the provider and never sees its credentials.
///
/// This file is identical in the desktop and the mobile app on purpose - it only uses plain Material widgets
/// and callbacks, so each app plugs in its own ApiClient.

class RaqmeeRecipient {
  final String name;
  final String? phone;
  final String status; // present | absent
  final bool? homeworkDone;
  final dynamic quizMark;
  const RaqmeeRecipient({
    required this.name,
    required this.phone,
    required this.status,
    this.homeworkDone,
    this.quizMark,
  });
}

class RaqmeeVar {
  final int n;
  final String type; // custom | system
  final String? name; // for system variables: customer_name, store_name
  const RaqmeeVar(this.n, this.type, this.name);
}

class RaqmeeTemplate {
  final dynamic id;
  final String name;
  final String language;
  final String body;
  final bool needsMedia;
  final String mode; // person | campaign
  final dynamic senderId;
  final List<RaqmeeVar> vars;
  const RaqmeeTemplate(this.id, this.name, this.language, this.body, this.needsMedia, this.mode, this.senderId, this.vars);

  bool get perPerson => mode == 'person' && senderId != null;

  factory RaqmeeTemplate.fromJson(Map<String, dynamic> j) => RaqmeeTemplate(
        j['id'],
        (j['name'] ?? '') as String,
        (j['language'] ?? '') as String,
        (j['body'] ?? '') as String,
        j['header_media_required'] == true,
        (j['mode'] ?? 'campaign') as String,
        j['sender_id'],
        ((j['variables'] as List?) ?? [])
            .map((v) => RaqmeeVar((v['n'] as num).toInt(), (v['type'] ?? 'custom') as String, v['name'] as String?))
            .toList(),
      );
}

typedef RaqmeeLoadTemplates = Future<List<Map<String, dynamic>>> Function();

/// Campaign mode: the server builds the segment, creates the campaign and starts it.
/// `variables`: [{n, mode: 'text'|'field', value}]. `recipients`: [{name, phone}].
typedef RaqmeeSendCampaign = Future<Map<String, dynamic>> Function({
  required dynamic templateId,
  required String sessionKey,
  required String title,
  required List<Map<String, dynamic>> recipients,
  required Map<String, String> context,
  required List<Map<String, dynamic>> variables,
});
typedef RaqmeeCampaignStatus = Future<Map<String, dynamic>> Function(dynamic campaignId);

/// Person mode: one parent, with that student's own values.
typedef RaqmeeSendPerson = Future<void> Function({
  required dynamic templateId,
  required dynamic senderId,
  required String sessionKey,
  required String phone,
  required Map<String, dynamic> student,
  required Map<String, String> context,
  required List<Map<String, dynamic>> variables,
});

enum _St { pending, sending, sent, failed }

const _personSources = <String, String>{
  'text': 'Fixed text',
  'student_name': 'Student name',
  'parent_name': 'Parent name (ولي أمر الطالب ...)',
  'date': 'Date',
  'course': 'Course',
  'center': 'Center',
  'status': 'Present / Absent',
  'homework': 'Homework (Done / Not done)',
  'quiz_mark': 'Quiz mark',
};

class RaqmeeSendScreen extends StatefulWidget {
  final List<RaqmeeRecipient> recipients;
  final String courseTitle;
  final String date; // yyyy-MM-dd
  final String? centerName;
  final String sessionKey; // identifies this attendance session (course+center+date)
  final RaqmeeLoadTemplates loadTemplates;
  final RaqmeeSendCampaign sendCampaign;
  final RaqmeeCampaignStatus campaignStatus;
  final RaqmeeSendPerson sendPerson;

  const RaqmeeSendScreen({
    super.key,
    required this.recipients,
    required this.courseTitle,
    required this.date,
    required this.centerName,
    required this.sessionKey,
    required this.loadTemplates,
    required this.sendCampaign,
    required this.campaignStatus,
    required this.sendPerson,
  });

  @override
  State<RaqmeeSendScreen> createState() => _RaqmeeSendScreenState();
}

class _RaqmeeSendScreenState extends State<RaqmeeSendScreen> {
  List<RaqmeeTemplate>? _templates;
  String? _loadError;
  RaqmeeTemplate? _selected;
  final Map<int, TextEditingController> _ctl = {};
  final Map<int, String> _src = {}; // custom variable -> 'text' | person field | 'parent_name' (campaign)
  late final List<bool> _picked;
  late final List<_St> _state;
  final Map<int, String> _error = {};

  bool _sending = false;
  String? _sendError;
  // campaign result
  dynamic _campaignId;
  int _sentCount = 0;
  int _skipped = 0;
  Map<String, dynamic>? _status;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _picked = widget.recipients.map((r) => (r.phone ?? '').trim().isNotEmpty).toList();
    _state = List.filled(widget.recipients.length, _St.pending);
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final raw = await widget.loadTemplates();
      if (!mounted) return;
      setState(() {
        _templates = raw.map(RaqmeeTemplate.fromJson).toList();
        // Templates that can carry each student's own values come first.
        _templates!.sort((a, b) => (b.perPerson ? 1 : 0) - (a.perPerson ? 1 : 0));
        if (_templates!.isNotEmpty) _select(_templates!.first);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e.toString());
    }
  }

  /// Guess what a variable means from the words just before it in the template text.
  String _guess(RaqmeeTemplate t, int n, bool first) {
    final m = RegExp('\\{\\{\\s*$n\\s*\\}\\}').firstMatch(t.body);
    var before = '';
    if (m != null) {
      final start = m.start - 22 < 0 ? 0 : m.start - 22;
      before = t.body.substring(start, m.start).replaceAll('\n', ' ');
    }
    if (before.contains('الكويز')) return 'quiz_mark';
    if (before.contains('الواجب')) return 'homework';
    if (before.contains('الحضور')) return 'status';
    if (before.contains('بتاريخ') || before.contains('يوم')) return 'date';
    if (before.contains('سنتر')) return 'center';
    if (before.contains('في ') || before.endsWith('في')) return 'course';
    if (before.contains('الطالب') || before.contains('ان ') || first) return 'student_name';
    return 'text';
  }

  void _select(RaqmeeTemplate t) {
    _selected = t;
    for (final c in _ctl.values) {
      c.dispose();
    }
    _ctl.clear();
    _src.clear();
    var first = true;
    for (final v in t.vars.where((v) => v.type == 'custom')) {
      _ctl[v.n] = TextEditingController();
      _src[v.n] = _guess(t, v.n, first);
      first = false;
    }
  }

  List<RaqmeeVar> get _customVars => _selected == null ? [] : _selected!.vars.where((v) => v.type == 'custom').toList();

  List<int> get _targets => [
        for (var i = 0; i < widget.recipients.length; i++)
          if (_picked[i] && _state[i] != _St.sent) i
      ];

  bool get _formReady =>
      _selected != null &&
      !_selected!.needsMedia &&
      _customVars.every((v) => _src[v.n] != 'text' || _ctl[v.n]!.text.trim().isNotEmpty);

  String _valueFor(String field, RaqmeeRecipient r) {
    switch (field) {
      case 'student_name':
        return r.name;
      case 'parent_name':
        return 'ولي أمر الطالب ${r.name}';
      case 'date':
        return widget.date;
      case 'course':
        return widget.courseTitle;
      case 'center':
        return widget.centerName ?? '-';
      case 'status':
        return r.status == 'present' ? 'Present' : 'Absent';
      case 'homework':
        return r.homeworkDone == true ? 'Done' : (r.homeworkDone == false ? 'Not done' : '-');
      case 'quiz_mark':
        return r.quizMark == null ? '-' : '${r.quizMark}';
    }
    return '';
  }

  String _preview(RaqmeeTemplate t) {
    var out = t.body;
    final sample = widget.recipients.isNotEmpty ? widget.recipients.first : null;
    for (final v in t.vars) {
      final String val;
      if (v.type == 'system') {
        val = v.name == 'store_name' ? '[اسم المتجر]' : '[اسم ولي الأمر]';
      } else if (_src[v.n] == 'parent_name') {
        val = 'ولي أمر الطالب ${sample?.name ?? ''}';
      } else if (_src[v.n] == 'text') {
        final txt = _ctl[v.n]?.text.trim() ?? '';
        val = txt.isEmpty ? '{{${v.n}}}' : txt;
      } else {
        val = sample == null ? '{{${v.n}}}' : _valueFor(_src[v.n]!, sample);
      }
      out = out.replaceAll(RegExp('\\{\\{\\s*${v.n}\\s*\\}\\}'), val);
    }
    return out;
  }

  Future<bool> _confirm(RaqmeeTemplate t, int count) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send WhatsApp messages?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Template: ${t.name}'),
              Text('Parents: $count'),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(_preview(t), textDirection: TextDirection.rtl, style: const TextStyle(fontSize: 13)),
              ),
              const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('Preview shows the first student; every parent gets their own student\'s values.',
                      style: TextStyle(fontSize: 11)),
                ),
              const SizedBox(height: 10),
              const Text('This sends real WhatsApp messages to real parents.', style: TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
        ],
      ),
    );
    return ok == true && mounted;
  }

  Future<void> _send() async {
    final t = _selected!;
    final targets = _targets;
    if (!await _confirm(t, targets.length)) return;
    if (t.perPerson) {
      await _sendPerPerson(t, targets);
    } else {
      await _sendCampaign(t, targets);
    }
  }

  Future<void> _sendPerPerson(RaqmeeTemplate t, List<int> targets) async {
    final vars = <Map<String, dynamic>>[
      for (final v in _customVars)
        _src[v.n] == 'text'
            ? {'n': v.n, 'mode': 'text', 'value': _ctl[v.n]!.text.trim()}
            : {'n': v.n, 'mode': 'field', 'value': _src[v.n]},
    ];
    setState(() {
      _sending = true;
      _sendError = null;
    });
    for (final i in targets) {
      if (!mounted) return;
      final r = widget.recipients[i];
      setState(() {
        _state[i] = _St.sending;
        _error.remove(i);
      });
      try {
        await widget.sendPerson(
          templateId: t.id,
          senderId: t.senderId,
          sessionKey: widget.sessionKey,
          phone: r.phone!.trim(),
          student: {
            'name': r.name,
            'status': r.status,
            'homework_done': r.homeworkDone,
            'quiz_mark': r.quizMark,
          },
          context: {
            'date': widget.date,
            'course': widget.courseTitle,
            'center': widget.centerName ?? '',
          },
          variables: vars,
        );
        if (!mounted) return;
        setState(() => _state[i] = _St.sent);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _state[i] = _St.failed;
          _error[i] = e.toString();
        });
      }
      await Future.delayed(const Duration(milliseconds: 600));
    }
    if (mounted) setState(() => _sending = false);
  }

  Future<void> _sendCampaign(RaqmeeTemplate t, List<int> targets) async {
    setState(() {
      _sending = true;
      _sendError = null;
    });
    try {
      final res = await widget.sendCampaign(
        templateId: t.id,
        sessionKey: widget.sessionKey,
        title: '${widget.courseTitle} ${widget.date}',
        recipients: [
          for (final i in targets)
            {
              'name': widget.recipients[i].name,
              'phone': widget.recipients[i].phone!.trim(),
              'status': widget.recipients[i].status,
              'homework_done': widget.recipients[i].homeworkDone,
              'quiz_mark': widget.recipients[i].quizMark,
            }
        ],
        context: {
          'date': widget.date,
          'course': widget.courseTitle,
          'center': widget.centerName ?? '',
        },
        variables: [
          for (final v in _customVars)
            _src[v.n] == 'text'
                ? {'n': v.n, 'mode': 'text', 'value': _ctl[v.n]!.text.trim()}
                : {'n': v.n, 'mode': 'field', 'value': _src[v.n]},
        ],
      );
      if (!mounted) return;
      setState(() {
        _campaignId = res['campaign_id'];
        _sentCount = (res['recipients'] as num?)?.toInt() ?? targets.length;
        _skipped = (res['skipped'] as num?)?.toInt() ?? 0;
      });
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() => _sendError = e.toString());
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _startPolling() {
    _poll?.cancel();
    Future<void> tick() async {
      try {
        final s = await widget.campaignStatus(_campaignId);
        if (mounted) setState(() => _status = s);
      } catch (_) {}
    }

    tick();
    _poll = Timer.periodic(const Duration(seconds: 10), (_) => tick());
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('WhatsApp to parents')),
      body: _campaignId != null ? _resultView(cs) : _body(cs),
    );
  }

  Widget _resultView(ColorScheme cs) {
    final d = (_status?['data'] is Map ? _status!['data'] : _status) as Map? ?? {};
    final f = (d['funnel'] is Map ? d['funnel'] : {}) as Map;
    Widget stat(String label, dynamic v) => Column(children: [
          Text('${v ?? 0}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          Text(label, style: const TextStyle(fontSize: 12)),
        ]);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.check_circle_rounded, size: 56, color: cs.primary),
            const SizedBox(height: 12),
            Text('WhatsApp started for $_sentCount parents', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            if (_skipped > 0) Text('$_skipped without a valid phone were skipped', style: TextStyle(color: cs.error)),
            const SizedBox(height: 6),
            Text('Status: ${d['status'] ?? '…'}'),
            const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              stat('Sent', f['sent']),
              stat('Delivered', f['delivered']),
              stat('Read', f['read']),
              stat('Failed', f['failed']),
            ]),
            const SizedBox(height: 8),
            const Text('Updates every 10 seconds.', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 20),
            FilledButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Done')),
          ]),
        ),
      ),
    );
  }

  Widget _body(ColorScheme cs) {
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.error_outline_rounded, size: 40, color: cs.error),
            const SizedBox(height: 12),
            Text(_loadError!, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: () {
                setState(() => _loadError = null);
                _load();
              },
              child: const Text('Retry'),
            ),
          ]),
        ),
      );
    }
    if (_templates == null) return const Center(child: CircularProgressIndicator());
    if (_templates!.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('No approved WhatsApp templates yet. Templates under review will appear here once approved.', textAlign: TextAlign.center),
        ),
      );
    }

    final t = _selected!;
    final sent = _state.where((s) => s == _St.sent).length;
    final failed = _state.where((s) => s == _St.failed).length;
    final targets = _targets;
    final selectable = [
      for (var i = 0; i < widget.recipients.length; i++)
        if ((widget.recipients[i].phone ?? '').trim().isNotEmpty) i
    ];
    final allOn = selectable.isNotEmpty && selectable.every((i) => _picked[i]);
    final noPhone = widget.recipients.length - selectable.length;

    return Column(
      children: [
        Expanded(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  const Text('Template', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<dynamic>(
                    initialValue: t.id,
                    isExpanded: true,
                    items: [
                      for (final x in _templates!)
                        DropdownMenuItem(
                          value: x.id,
                          child: Text('${x.name}  (${x.language})${x.perPerson ? '  · per student' : ''}', overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: _sending ? null : (id) => setState(() => _select(_templates!.firstWhere((x) => x.id == id))),
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    t.perPerson
                        ? 'Sent one by one: each parent gets their own student\'s values.'
                        : 'Students with the same values are sent together; each parent gets their own student\'s values.',
                    style: const TextStyle(fontSize: 12),
                  ),
                  if (t.needsMedia) ...[
                    const SizedBox(height: 8),
                    Text('This template needs a header image/file, which is not supported here yet.', style: TextStyle(color: cs.error)),
                  ],
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(10)),
                    child: Text(_preview(t), textDirection: TextDirection.rtl, style: const TextStyle(fontSize: 13)),
                  ),
                  const SizedBox(height: 14),
                  for (final v in _customVars) ...[
                    Text('{{${v.n}}}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    DropdownButtonFormField<String>(
                      initialValue: _src[v.n],
                      isExpanded: true,
                      items: [
                        for (final e in _personSources.entries) DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: _sending ? null : (x) => setState(() => _src[v.n] = x ?? 'text'),
                      decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, labelText: 'Fill with'),
                    ),
                    if (_src[v.n] == 'text') ...[
                      const SizedBox(height: 6),
                      TextField(
                        controller: _ctl[v.n],
                        maxLength: 30,
                        enabled: !_sending,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(labelText: 'Text for {{${v.n}}}', border: const OutlineInputBorder(), isDense: true),
                      ),
                    ],
                    const SizedBox(height: 10),
                  ],
                  if (_sendError != null) ...[
                    Text(_sendError!, style: TextStyle(color: cs.error)),
                    const SizedBox(height: 8),
                  ],
                  Row(children: [
                    const Text('Parents', style: TextStyle(fontWeight: FontWeight.w700)),
                    const Spacer(),
                    TextButton(
                      onPressed: _sending
                          ? null
                          : () => setState(() {
                                for (final i in selectable) {
                                  _picked[i] = !allOn;
                                }
                              }),
                      child: Text(allOn ? 'Deselect all' : 'Select all'),
                    ),
                  ]),
                  if (noPhone > 0) Text('$noPhone student(s) have no parent phone and will be skipped.', style: TextStyle(fontSize: 12, color: cs.error)),
                  for (var i = 0; i < widget.recipients.length; i++) _tile(i, cs),
                ],
              ),
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: (_sending || targets.isEmpty || !_formReady) ? null : _send,
                icon: _sending
                    ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded),
                label: Text(_sending
                    ? (t.perPerson ? 'Sending… ($sent sent${failed > 0 ? ', $failed failed' : ''})' : 'Starting campaign…')
                    : (failed > 0 && sent > 0 ? 'Send to ${targets.length} (retry failed)' : 'Send to ${targets.length} parents')),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tile(int i, ColorScheme cs) {
    final r = widget.recipients[i];
    final hasPhone = (r.phone ?? '').trim().isNotEmpty;
    Widget? trailing;
    switch (_state[i]) {
      case _St.sent:
        trailing = Icon(Icons.check_circle_rounded, color: cs.primary);
      case _St.failed:
        trailing = Icon(Icons.error_rounded, color: cs.error);
      case _St.sending:
        trailing = const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2));
      case _St.pending:
        trailing = null;
    }
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: _picked[i],
      onChanged: (!hasPhone || _sending || _state[i] == _St.sent) ? null : (v) => setState(() => _picked[i] = v ?? false),
      secondary: trailing,
      title: Text('${r.name}${r.status == 'absent' ? '  (absent)' : ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(
        _error[i] ?? (hasPhone ? r.phone! : 'No parent phone on file'),
        style: TextStyle(fontSize: 12, color: _error[i] != null ? cs.error : null),
      ),
    );
  }
}
