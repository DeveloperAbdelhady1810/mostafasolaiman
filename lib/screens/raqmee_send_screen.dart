import 'dart:async';

import 'package:flutter/material.dart';

/// Official WhatsApp sending for a submitted attendance session (second option besides the assistant's own
/// linked number). The assistant picks one of the REAL approved templates of the school's WhatsApp account,
/// fills its variables once and presses Send; the Balance server builds the audience (this session's
/// parents), creates the campaign and starts it. The app never talks to the provider and never sees its
/// credentials.
///
/// This file is identical in the desktop and the mobile app on purpose - it only uses plain Material widgets
/// and callbacks, so each app plugs in its own ApiClient.

class RaqmeeRecipient {
  final String name;
  final String? phone;
  final String status; // present | absent
  const RaqmeeRecipient({required this.name, required this.phone, required this.status});
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
  final List<RaqmeeVar> vars;
  const RaqmeeTemplate(this.id, this.name, this.language, this.body, this.needsMedia, this.vars);

  factory RaqmeeTemplate.fromJson(Map<String, dynamic> j) => RaqmeeTemplate(
        j['id'],
        (j['name'] ?? '') as String,
        (j['language'] ?? '') as String,
        (j['body'] ?? '') as String,
        j['header_media_required'] == true,
        ((j['variables'] as List?) ?? [])
            .map((v) => RaqmeeVar((v['n'] as num).toInt(), (v['type'] ?? 'custom') as String, v['name'] as String?))
            .toList(),
      );
}

typedef RaqmeeLoadTemplates = Future<List<Map<String, dynamic>>> Function();

/// One call: the server builds the segment, creates the campaign and starts it.
/// `variables`: [{n, mode: 'text'|'field', value}]. `recipients`: [{name, phone}].
typedef RaqmeeSendCampaign = Future<Map<String, dynamic>> Function({
  required dynamic templateId,
  required String sessionKey,
  required String title,
  required List<Map<String, String>> recipients,
  required List<Map<String, dynamic>> variables,
});
typedef RaqmeeCampaignStatus = Future<Map<String, dynamic>> Function(dynamic campaignId);

class RaqmeeSendScreen extends StatefulWidget {
  final List<RaqmeeRecipient> recipients;
  final String courseTitle;
  final String date; // yyyy-MM-dd
  final String? centerName;
  final String sessionKey; // identifies this attendance session (course+center+date)
  final RaqmeeLoadTemplates loadTemplates;
  final RaqmeeSendCampaign sendCampaign;
  final RaqmeeCampaignStatus campaignStatus;

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
  });

  @override
  State<RaqmeeSendScreen> createState() => _RaqmeeSendScreenState();
}

class _RaqmeeSendScreenState extends State<RaqmeeSendScreen> {
  List<RaqmeeTemplate>? _templates;
  String? _loadError;
  RaqmeeTemplate? _selected;
  final Map<int, TextEditingController> _ctl = {};
  final Map<int, bool> _useParentName = {}; // custom variable -> use "ولي أمر الطالب <name>"
  late final List<bool> _picked;

  bool _sending = false;
  String? _sendError;
  dynamic _campaignId;
  int _sentCount = 0;
  int _skipped = 0;
  Map<String, dynamic>? _status;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _picked = widget.recipients.map((r) => (r.phone ?? '').trim().isNotEmpty).toList();
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
        if (_templates!.isNotEmpty) _select(_templates!.first);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e.toString());
    }
  }

  void _select(RaqmeeTemplate t) {
    _selected = t;
    for (final c in _ctl.values) {
      c.dispose();
    }
    _ctl.clear();
    _useParentName.clear();
    var first = true;
    for (final v in t.vars.where((v) => v.type == 'custom')) {
      _ctl[v.n] = TextEditingController();
      _useParentName[v.n] = first; // the first custom variable is usually the greeting name
      first = false;
    }
  }

  List<RaqmeeVar> get _customVars => _selected == null ? [] : _selected!.vars.where((v) => v.type == 'custom').toList();

  List<int> get _targets => [
        for (var i = 0; i < widget.recipients.length; i++)
          if (_picked[i]) i
      ];

  bool get _formReady =>
      _selected != null &&
      !_selected!.needsMedia &&
      _customVars.every((v) => _useParentName[v.n] == true || _ctl[v.n]!.text.trim().isNotEmpty);

  String _preview(RaqmeeTemplate t) {
    var out = t.body;
    for (final v in t.vars) {
      final String val;
      if (v.type == 'system') {
        val = v.name == 'store_name' ? '[اسم المتجر]' : '[اسم ولي الأمر]';
      } else if (_useParentName[v.n] == true) {
        val = 'ولي أمر الطالب ${widget.recipients.isNotEmpty ? widget.recipients.first.name : ''}';
      } else {
        final txt = _ctl[v.n]?.text.trim() ?? '';
        val = txt.isEmpty ? '{{${v.n}}}' : txt;
      }
      out = out.replaceAll(RegExp('\\{\\{\\s*${v.n}\\s*\\}\\}'), val);
    }
    return out;
  }

  Future<void> _send() async {
    final t = _selected!;
    final targets = _targets;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Send WhatsApp messages?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Template: ${t.name}'),
            Text('Parents: ${targets.length}'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(_preview(t), textDirection: TextDirection.rtl, style: const TextStyle(fontSize: 13)),
            ),
            const SizedBox(height: 10),
            const Text('This sends real WhatsApp messages to real parents.', style: TextStyle(fontWeight: FontWeight.w700)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Send')),
        ],
      ),
    );
    if (ok != true || !mounted) return;

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
          for (final i in targets) {'name': widget.recipients[i].name, 'phone': widget.recipients[i].phone!.trim()}
        ],
        variables: [
          for (final v in _customVars)
            _useParentName[v.n] == true
                ? {'n': v.n, 'mode': 'field', 'value': 'customer_name'}
                : {'n': v.n, 'mode': 'text', 'value': _ctl[v.n]!.text.trim()},
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
            Text('Campaign started for $_sentCount parents', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
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
                        DropdownMenuItem(value: x.id, child: Text('${x.name}  (${x.language})', overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: _sending ? null : (id) => setState(() => _select(_templates!.firstWhere((x) => x.id == id))),
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
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
                    Row(children: [
                      Expanded(child: Text('{{${v.n}}}', style: const TextStyle(fontWeight: FontWeight.w700))),
                      const Text('Parent name', style: TextStyle(fontSize: 12)),
                      Switch(
                        value: _useParentName[v.n] == true,
                        onChanged: _sending ? null : (x) => setState(() => _useParentName[v.n] = x),
                      ),
                    ]),
                    if (_useParentName[v.n] != true)
                      TextField(
                        controller: _ctl[v.n],
                        maxLength: 30,
                        enabled: !_sending,
                        onChanged: (_) => setState(() {}),
                        decoration: InputDecoration(labelText: 'Text for {{${v.n}}}', border: const OutlineInputBorder(), isDense: true),
                      )
                    else
                      const Text('Each parent sees: ولي أمر الطالب <student name> (shortened to fit 30 characters)', style: TextStyle(fontSize: 12)),
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
                  for (var i = 0; i < widget.recipients.length; i++) _tile(i),
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
                label: Text(_sending ? 'Starting campaign…' : 'Send to ${targets.length} parents'),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _tile(int i) {
    final r = widget.recipients[i];
    final hasPhone = (r.phone ?? '').trim().isNotEmpty;
    return CheckboxListTile(
      contentPadding: EdgeInsets.zero,
      controlAffinity: ListTileControlAffinity.leading,
      value: _picked[i],
      onChanged: (!hasPhone || _sending) ? null : (v) => setState(() => _picked[i] = v ?? false),
      title: Text('${r.name}${r.status == 'absent' ? '  (absent)' : ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(hasPhone ? r.phone! : 'No parent phone on file', style: const TextStyle(fontSize: 12)),
    );
  }
}
