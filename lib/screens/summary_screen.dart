import 'dart:async';
import 'dart:io';
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
              homeworkDone: e['homework_done'] as bool?,
              quizMark: e['quiz_mark'],
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
        sendCampaign: ({required templateId, required sessionKey, required title, required recipients, required context, required variables}) async {
          return _postCampaignResilient(api, token, {
            'template_id': templateId,
            'session_key': sessionKey,
            'title': title,
            'recipients': recipients,
            'context': context,
            'variables': variables,
          });
        },
        sendPerson: ({required templateId, required senderId, required sessionKey, required phone, required student, required context, required variables}) async {
          await api.post('/assistant/whatsapp/send-one', token: token, body: {
            'template_id': templateId,
            'sender_id': senderId,
            'session_key': sessionKey,
            'phone': phone,
            'student': student,
            'context': context,
            'variables': variables,
          });
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

/// Asks the server to send the WhatsApp campaigns IN THE BACKGROUND and then only watches its progress, so a slow
/// provider can never time the phone out. The server keeps retrying until every campaign is created and started
/// (and never creates one twice), so this just waits for "done". An older server that has no background mode
/// answers with the finished result straight away, which is returned as is.
Future<Map<String, dynamic>> _postCampaignResilient(ApiClient api, String? token, Map<String, dynamic> body) async {
  Object? lastError;
  Map<String, dynamic>? queued;
  for (var attempt = 0; attempt < 6 && queued == null; attempt++) {
    try {
      final d = await api.post('/assistant/whatsapp/campaign', token: token, timeout: const Duration(seconds: 60), body: {...body, 'async': true});
      final m = Map<String, dynamic>.from(d as Map);
      if (m['busy'] == true) {
        await Future.delayed(const Duration(seconds: 5));
        continue;
      }
      if (m['queued'] != true) return m;
      queued = m;
    } on TimeoutException catch (e) {
      lastError = e;
      await Future.delayed(const Duration(seconds: 5));
    } on SocketException catch (e) {
      lastError = e;
      await Future.delayed(const Duration(seconds: 5));
    }
  }
  if (queued == null) {
    throw Exception('Could not reach the server (${lastError ?? 'busy'}). Check the connection and tap Send again - nothing was sent twice.');
  }

  // Poll up to ~30 minutes. A dropped connection or a slow answer here is not an error: just ask again.
  for (var i = 0; i < 360; i++) {
    await Future.delayed(const Duration(seconds: 5));
    Map<String, dynamic>? s;
    try {
      final d = await api.get('/assistant/whatsapp/send-status/${queued['job']}', token: token);
      s = Map<String, dynamic>.from(d as Map);
    } catch (_) {
      // dropped connection / slow answer / server hiccup: not an error, just ask again
    }
    if (s == null) continue;
    if (s['status'] == 'done') return {...queued, ...s};
    if (s['status'] == 'failed') {
      throw Exception('The server could not send the messages: ${s['error'] ?? 'unknown error'}. Tap Send again to retry.');
    }
  }
  throw Exception('The server is still sending in the background. Open this screen again in a few minutes - nothing is lost or duplicated.');
}
