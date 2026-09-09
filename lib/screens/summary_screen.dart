import 'package:flutter/material.dart';

class SummaryScreen extends StatelessWidget {
  final Map<String, dynamic> result;

  const SummaryScreen({super.key, required this.result});

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
