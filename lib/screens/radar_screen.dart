import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/scan.dart';
import '../providers/attendance_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/radar_provider.dart';
import '../services/api_client.dart';
import '../services/ble_scanner.dart';
import '../services/reply_advertiser.dart';
import '../services/reply_queue.dart';
import '../services/radar_book.dart';

/// Classroom Radar: students' phones broadcast their rotating code over Bluetooth; this screen lists
/// everyone in range so the whole class can be confirmed at once instead of scanning one by one.
class RadarScreen extends StatefulWidget {
  const RadarScreen({super.key, this.scanner, this.replyAdvertiser});

  /// Injectable for tests.
  final BleScanner? scanner;
  final ReplyAdvertiser? replyAdvertiser;

  @override
  State<RadarScreen> createState() => _RadarScreenState();
}

class _RadarScreenState extends State<RadarScreen> {
  late final RadarProvider _radar;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    final attendance = context.read<AttendanceProvider>();
    _radar = RadarProvider(
      scanner: widget.scanner ?? PlusScanner(),
      serverNow: ApiClient.serverNow,
      threshold: attendance.rssiThreshold,
      replies: ReplyQueue(widget.replyAdvertiser ?? PluginReplyAdvertiser()),
    )..onNewDetection = (_) {
        HapticFeedback.mediumImpact();
        SystemSound.play(SystemSoundType.click);
      };
    WidgetsBinding.instance.addPostFrameCallback((_) => _radar.start());
  }

  @override
  void dispose() {
    _radar.dispose();
    super.dispose();
  }

  String _nameOf(int studentNo) =>
      context.read<AttendanceProvider>().roster.where((s) => s.studentNumber == studentNo).firstOrNull?.name ??
      'Student #$studentNo';

  Future<void> _confirm() async {
    final token = context.read<AuthProvider>().token;
    final toSend = _radar.selected;
    if (token == null || toSend.isEmpty || _confirming) return;

    setState(() => _confirming = true);
    final outcome = await context.read<AttendanceProvider>().confirmDetections(token, toSend);
    if (!mounted) return;
    _radar.applyOutcome(outcome);
    setState(() => _confirming = false);
    await _showOutcome(outcome);
  }

  Future<void> _showOutcome(BulkOutcome o) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (o.failureMessage != null)
                _line(Icons.error_outline_rounded, Colors.red.shade700, o.failureMessage!),
              if (o.accepted.isNotEmpty)
                _line(Icons.verified_rounded, Colors.green.shade700,
                    '${o.accepted.length} verified and marked present'),
              if (o.alreadyPresent.isNotEmpty)
                _line(Icons.check_circle_outline_rounded, Colors.green.shade700,
                    '${o.alreadyPresent.length} already marked present'),
              if (o.queued.isNotEmpty)
                _line(Icons.schedule_rounded, Colors.amber.shade900,
                    '${o.queued.length} saved - will be verified when you are online'),
              if (o.rejected.isNotEmpty) ...[
                _line(Icons.warning_amber_rounded, Colors.red.shade700,
                    '${o.rejected.length} could not be verified:'),
                for (final r in o.rejected)
                  Padding(
                    padding: const EdgeInsets.only(left: 34, top: 2),
                    child: Text('${r.name ?? 'Student #${r.studentNo}'} - ${r.message}',
                        style: TextStyle(color: Colors.grey.shade800, fontSize: 13)),
                  ),
                const Padding(
                  padding: EdgeInsets.only(left: 34, top: 8),
                  child: Text('You can still add them with Scan QR or Add Walk-in.', style: TextStyle(fontSize: 12.5)),
                ),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _line(IconData icon, Color color, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600))),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<RadarProvider>.value(
      value: _radar,
      child: Consumer<RadarProvider>(
        builder: (context, radar, _) {
          final pending = radar.pending;
          final selected = radar.selected;
          final confirmed = radar.confirmed;

          return Scaffold(
            appBar: AppBar(
              title: const Text('Classroom Radar'),
              actions: [
                if (radar.book.totalSeen > 0)
                  IconButton(
                    tooltip: 'Clear list',
                    icon: const Icon(Icons.layers_clear_outlined),
                    onPressed: radar.clear,
                  ),
              ],
            ),
            body: Column(
              children: [
                _StatusCard(radar: radar, inRoom: pending.length + confirmed.length),
                _RangeSlider(radar: radar),
                const Divider(height: 1),
                Expanded(
                  child: (pending.isEmpty && confirmed.isEmpty)
                      ? _Empty(radar: radar)
                      : ListView(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                          children: [
                            for (final d in pending)
                              _DetectionTile(
                                key: ValueKey('p${d.studentNo}'),
                                detection: d,
                                name: _nameOf(d.studentNo),
                                checked: !radar.excluded.contains(d.studentNo),
                                onToggle: () => radar.toggle(d.studentNo),
                              ),
                            if (confirmed.isNotEmpty) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(4, 14, 4, 6),
                                child: Text('Confirmed (${confirmed.length})',
                                    style: TextStyle(fontWeight: FontWeight.w700, color: Colors.grey.shade700)),
                              ),
                              for (final d in confirmed)
                                _DetectionTile(
                                  key: ValueKey('c${d.studentNo}'),
                                  detection: d,
                                  name: _nameOf(d.studentNo),
                                  checked: true,
                                  done: true,
                                ),
                            ],
                          ],
                        ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: FilledButton.icon(
                        key: const Key('radar_confirm'),
                        onPressed: (selected.isEmpty || _confirming) ? null : _confirm,
                        icon: _confirming
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.done_all_rounded),
                        label: Text(selected.isEmpty
                            ? 'Nobody to confirm yet'
                            : 'Confirm ${selected.length} student${selected.length == 1 ? '' : 's'}'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.radar, required this.inRoom});
  final RadarProvider radar;
  final int inRoom;

  @override
  Widget build(BuildContext context) {
    final scanning = radar.isScanning;
    String text;
    Color color = Colors.green.shade700;
    switch (radar.status) {
      case RadarStatus.scanning:
        text = inRoom == 0 ? 'Listening for students...' : '$inRoom in the room';
        break;
      case RadarStatus.starting:
        text = 'Starting Bluetooth...';
        break;
      case RadarStatus.bluetoothOff:
        text = 'Bluetooth is off';
        color = Colors.amber.shade900;
        break;
      case RadarStatus.needsPermission:
        text = 'Bluetooth permission needed';
        color = Colors.amber.shade900;
        break;
      case RadarStatus.unsupported:
        text = 'This phone has no Bluetooth LE';
        color = Colors.red.shade700;
        break;
      case RadarStatus.error:
        text = 'Could not start scanning';
        color = Colors.red.shade700;
        break;
      case RadarStatus.idle:
        text = 'Paused';
        color = Colors.grey.shade700;
        break;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), shape: BoxShape.circle),
          child: scanning
              ? Icon(Icons.radar_rounded, color: color)
              : Icon(Icons.bluetooth_disabled_rounded, color: color),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(text, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: color)),
        ),
        if (radar.status == RadarStatus.bluetoothOff)
          TextButton(onPressed: radar.turnBluetoothOn, child: const Text('Turn on')),
        if (radar.status == RadarStatus.needsPermission || radar.status == RadarStatus.error)
          TextButton(onPressed: radar.start, child: const Text('Retry')),
      ]),
    );
  }
}

class _RangeSlider extends StatelessWidget {
  const _RangeSlider({required this.radar});
  final RadarProvider radar;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Range', style: TextStyle(fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('${radar.threshold} dBm', style: TextStyle(color: Colors.grey.shade700, fontSize: 12.5)),
        ]),
        Slider(
          key: const Key('radar_range'),
          // left = wide (weak signals count), right = near only
          min: -95,
          max: -45,
          divisions: 50,
          value: radar.threshold.clamp(-95, -45).toDouble(),
          onChanged: (v) => radar.setThreshold(v.round()),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Wide', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
          Text('Very near', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
        ]),
      ]),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.radar});
  final RadarProvider radar;

  @override
  Widget build(BuildContext context) {
    final hidden = radar.book.totalSeen;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.bluetooth_searching_rounded, size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text(
            hidden > 0
                ? '$hidden student${hidden == 1 ? ' is' : 's are'} outside the range. Move the slider towards "Wide" to include them.'
                : 'Ask students to open the Mostafa Solaiman app. Their phones broadcast automatically.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey.shade700, height: 1.45),
          ),
        ]),
      ),
    );
  }
}

class _DetectionTile extends StatelessWidget {
  const _DetectionTile({
    super.key,
    required this.detection,
    required this.name,
    required this.checked,
    this.onToggle,
    this.done = false,
  });

  final Detection detection;
  final String name;
  final bool checked;
  final VoidCallback? onToggle;
  final bool done;

  int get _bars {
    final r = detection.bestRssi;
    if (r > -55) return 4;
    if (r > -65) return 3;
    if (r > -75) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: done ? Colors.green.shade50 : null,
      child: ListTile(
        onTap: done ? null : onToggle,
        leading: done
            ? Icon(Icons.verified_rounded, color: Colors.green.shade700)
            : Checkbox(value: checked, onChanged: (_) => onToggle?.call()),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('#${detection.studentNo}  -  ${detection.bestRssi} dBm'),
        trailing: _SignalBars(bars: _bars, color: done ? Colors.green.shade700 : Theme.of(context).colorScheme.primary),
      ),
    );
  }
}

class _SignalBars extends StatelessWidget {
  const _SignalBars({required this.bars, required this.color});
  final int bars;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
      for (var i = 1; i <= 4; i++)
        Container(
          width: 5,
          height: 6.0 + i * 5,
          margin: const EdgeInsets.only(left: 2),
          decoration: BoxDecoration(
            color: i <= bars ? color : Colors.grey.shade300,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
    ]);
  }
}
