import 'package:flutter/material.dart';
import '../services/api_client.dart';
import 'raqmee_send_screen.dart';

class SummaryScreen extends StatelessWidget {
  final Map<String, dynamic> result;
  // Only set for in-center sessions; the WhatsApp button is hidden when there is no token (e.g. Zoom).
  final String? token;
  final String courseTitle;
  final int courseId;
  final String? centerName;
  final int centerId;
  final String date;

  const SummaryScreen({
    super.key,
    required this.result,
    this.token,
    this.courseTitle = '',
    this.courseId = 0,
    this.centerName,
    this.centerId = 0,
    this.date = '',
  });

  void _openWhatsapp(BuildContext context) {
    final api = ApiClient();
    final token = this.token!;
    final parents = (result['parent_summaries'] as List? ?? [])
        .map((e) => RaqmeeRecipient(
              name: (e['name'] ?? '') as String,
              phone: e['parent_phone'] as String?,
              status: (e['status'] ?? 'absent') as String,
            ))
        .toList();
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RaqmeeSendScreen(
        recipients: parents,
        courseTitle: courseTitle,
        date: date,
        centerName: centerName,
        sessionKey: '$courseId-$centerId-$date',
        loadTemplates: () async {
          final d = await api.get('/assistant/whatsapp/templates', token: token) as Map<String, dynamic>;
          return (d['templates'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        },
        sendCampaign: ({required templateId, required sessionKey, required title, required recipients, required variables}) async {
          final d = await api.post('/assistant/whatsapp/campaign', token: token, body: {
            'template_id': templateId,
            'session_key': sessionKey,
            'title': title,
            'recipients': recipients,
            'variables': variables,
          });
          return Map<String, dynamic>.from(d as Map);
        },
        campaignStatus: (id) async {
          final d = await api.get('/assistant/whatsapp/campaigns/$id', token: token);
          return Map<String, dynamic>.from(d as Map);
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final summary = result['summary'] as Map<String, dynamic>? ?? {};
    final expected = summary['expected'] ?? 0;
    final present = summary['present'] ?? 0;
    final absent = summary['absent'] ?? 0;

    return Scaffold(
      appBar: AppBar(title: const Text('Attendance Submitted')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 16),
            Icon(Icons.check_circle, size: 72, color: Colors.green.shade600),
            const SizedBox(height: 16),
            const Text('Attendance saved successfully', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 32),
            Row(
              children: [
                _StatTile(label: 'Expected', value: expected, color: Colors.grey),
                const SizedBox(width: 12),
                _StatTile(label: 'Present', value: present, color: Colors.green),
                const SizedBox(width: 12),
                _StatTile(label: 'Absent', value: absent, color: Colors.red),
              ],
            ),
            const Spacer(),
            if (token != null) ...[
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: () => _openWhatsapp(context),
                  icon: const Icon(Icons.verified_rounded),
                  label: const Text('Send WhatsApp to parents (official)'),
                ),
              ),
              const SizedBox(height: 10),
            ],
            SizedBox(
              width: double.infinity,
              height: 50,
              child: FilledButton(
                onPressed: () => Navigator.of(context).popUntil((route) => route.isFirst),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final dynamic value;
  final MaterialColor color;

  const _StatTile({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: color.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.shade200),
        ),
        child: Column(
          children: [
            Text('$value', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color.shade700)),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: color.shade700)),
          ],
        ),
      ),
    );
  }
}
