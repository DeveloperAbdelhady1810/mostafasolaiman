import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../models/scan.dart';

/// Full-screen camera that STAYS OPEN while the assistant scans a whole line of
/// students: every code is handed to [onCode], the result is shown as a banner
/// (with a haptic tick), and the camera keeps going. Pops with the number of
/// students marked when the assistant taps Done or goes back.
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key, required this.onCode, this.secureCodesEnabled = false});

  /// Called once per newly detected code; returns what to show.
  final Future<ScanFeedback> Function(String raw) onCode;

  /// Server has the rotating student codes switched on (shown as a hint).
  final bool secureCodesEnabled;

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController();

  bool _busy = false;
  int _marked = 0;
  ScanFeedback? _feedback;
  Timer? _hideTimer;

  /// Same code seen again within this window is the camera still looking at the same phone.
  final Map<String, DateTime> _recent = {};
  static const _repeatWindow = Duration(seconds: 6);

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) return;
    final raw = capture.barcodes.map((b) => b.rawValue).whereType<String>().where((v) => v.isNotEmpty).firstOrNull;
    if (raw == null) return;

    final now = DateTime.now();
    _recent.removeWhere((_, t) => now.difference(t) > _repeatWindow);
    if (_recent.containsKey(raw)) return;
    _recent[raw] = now;

    _busy = true;
    ScanFeedback feedback;
    try {
      feedback = await widget.onCode(raw);
    } catch (_) {
      feedback = const ScanFeedback(ScanKind.rejected, 'Something went wrong. Try scanning again.');
    }
    _busy = false;
    if (!mounted) return;

    if (feedback.isSuccess) {
      HapticFeedback.mediumImpact();
      SystemSound.play(SystemSoundType.click);
      _marked++;
    } else if (feedback.isError) {
      HapticFeedback.heavyImpact();
      // a rejected code may be retried right away (e.g. after the student refreshes their code)
      _recent.remove(raw);
    }

    setState(() => _feedback = feedback);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 2800), () {
      if (mounted) setState(() => _feedback = null);
    });
  }

  Color _color(ScanFeedback f) {
    if (f.isSuccess) return Colors.green.shade600;
    if (f.isWarning) return Colors.amber.shade800;
    return Colors.red.shade600;
  }

  IconData _icon(ScanFeedback f) {
    if (f.kind == ScanKind.verified) return Icons.verified_rounded;
    if (f.kind == ScanKind.pending) return Icons.schedule_rounded;
    if (f.isWarning) return Icons.info_outline_rounded;
    return Icons.error_outline_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final feedback = _feedback;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) Navigator.of(context).pop(_marked);
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Scan Student QR Codes'),
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          actions: [
            IconButton(
              icon: ValueListenableBuilder<MobileScannerState>(
                valueListenable: _controller,
                builder: (context, state, child) {
                  return Icon(state.torchState == TorchState.on ? Icons.flash_on : Icons.flash_off);
                },
              ),
              onPressed: () => _controller.toggleTorch(),
            ),
          ],
        ),
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            MobileScanner(controller: _controller, onDetect: _onDetect),
            Center(
              child: Container(
                width: 260,
                height: 260,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: feedback == null ? Colors.white : _color(feedback),
                    width: 4,
                  ),
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
            ),
            if (feedback != null)
              Positioned(
                top: 16,
                left: 16,
                right: 16,
                child: Material(
                  color: _color(feedback),
                  elevation: 6,
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    child: Row(
                      children: [
                        Icon(_icon(feedback), color: Colors.white),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            feedback.message,
                            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Positioned(
              bottom: 24,
              left: 16,
              right: 16,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.secureCodesEnabled
                          ? 'Secure codes are on - point at each student\'s live code'
                          : 'Point the camera at the student\'s QR code',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: FilledButton.icon(
                        onPressed: () => Navigator.of(context).pop(_marked),
                        icon: const Icon(Icons.check),
                        label: Text(_marked == 0 ? 'Done' : 'Done  ($_marked marked)'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
