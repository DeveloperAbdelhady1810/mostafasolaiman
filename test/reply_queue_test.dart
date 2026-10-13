import 'package:attendance_assistant/services/ble_packet.dart';
import 'package:attendance_assistant/services/reply_advertiser.dart';
import 'package:attendance_assistant/services/reply_queue.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAdvertiser implements ReplyAdvertiser {
  bool canAdvertise = true;
  int prepares = 0;
  final List<String> started = [];
  int stops = 0;
  bool onAir = false;
  int maxConcurrent = 0;

  @override
  Future<bool> prepare() async {
    prepares++;
    return canAdvertise;
  }

  @override
  Future<bool> start(String serviceUuid) async {
    expect(onAir, isFalse, reason: 'only one packet may be on air at a time');
    onAir = true;
    maxConcurrent = 1;
    started.add(serviceUuid);
    return true;
  }

  @override
  Future<void> stop() async {
    stops++;
    onAir = false;
  }
}

const _mac = 'b4a0fdce853f03dfc5';
Future<void> _wait([int ms = 120]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late FakeAdvertiser adv;
  late DateTime clock;

  ReplyQueue make({int maxQueue = 80}) => ReplyQueue(
        adv,
        burst: const Duration(milliseconds: 10),
        spacing: const Duration(seconds: 8),
        maxPerSession: 3,
        sessionGap: const Duration(seconds: 70),
        maxQueue: maxQueue,
        now: () => clock,
      );

  setUp(() {
    adv = FakeAdvertiser();
    clock = DateTime(2026, 10, 13, 20);
  });

  test('replies with the echo packet: "MA" marker, the student and the MAC that was heard', () async {
    final q = make();
    q.maybeReply(10001, _mac);
    await _wait();

    expect(adv.started, ['4d410100-0027-11b4-a0fd-ce853f03dfc5']);
    final p = BlePacket.parse(adv.started.single)!;
    expect(p.isReply, isTrue);
    expect(p.studentNo, 10001);
    expect(p.macHex, _mac);
    expect(adv.onAir, isFalse); // taken off the air after the burst
    await q.dispose();
  });

  test('a whole class is answered one packet at a time, in order', () async {
    final q = make();
    for (var i = 0; i < 5; i++) {
      q.maybeReply(10001 + i, _mac);
    }
    await _wait(300);

    expect(adv.started.map((u) => BlePacket.parse(u)!.studentNo), [10001, 10002, 10003, 10004, 10005]);
    expect(q.repliesSent, 5);
    await q.dispose();
  });

  test('a student heard continuously is not answered more than once every 8 s', () async {
    final q = make();
    q.maybeReply(10001, _mac);
    await _wait();
    q.maybeReply(10001, _mac); // heard again a moment later
    clock = clock.add(const Duration(seconds: 3));
    q.maybeReply(10001, _mac);
    await _wait();

    expect(adv.started, hasLength(1));
    await q.dispose();
  });

  test('a missed reply is repeated: up to 3 per broadcast, spaced out', () async {
    final q = make();
    for (var i = 0; i < 6; i++) {
      q.maybeReply(10001, _mac);
      await _wait();
      clock = clock.add(const Duration(seconds: 9)); // student still being heard 9 s later
    }

    expect(adv.started, hasLength(3), reason: 'capped so a student never blocks the air for the rest of the class');
    await q.dispose();
  });

  test('after the student goes quiet and broadcasts again, replies start over', () async {
    final q = make();
    for (var i = 0; i < 4; i++) {
      q.maybeReply(10001, _mac);
      await _wait();
      clock = clock.add(const Duration(seconds: 9));
    }
    expect(adv.started, hasLength(3));

    clock = clock.add(const Duration(seconds: 80)); // silence longer than a broadcast session
    q.maybeReply(10001, 'aabbccddeeff001122'); // "Broadcast again": new code
    await _wait();

    expect(adv.started, hasLength(4));
    expect(BlePacket.parse(adv.started.last)!.macHex, 'aabbccddeeff001122');
    await q.dispose();
  });

  test('while waiting, the freshest code for a student replaces the older one', () async {
    final q = make();
    q.maybeReply(10001, _mac); // starts immediately
    q.maybeReply(10002, '000000000000000001');
    q.maybeReply(10002, '000000000000000002'); // newer code while still queued
    await _wait(200);

    final second = BlePacket.parse(adv.started[1])!;
    expect(second.studentNo, 10002);
    expect(second.macHex, '000000000000000002');
    expect(adv.started, hasLength(2));
    await q.dispose();
  });

  test('phone that cannot advertise: no replies, no errors, radar unaffected', () async {
    adv.canAdvertise = false;
    final q = make();
    q.maybeReply(10001, _mac);
    q.maybeReply(10002, _mac);
    await _wait();

    expect(adv.started, isEmpty);
    expect(adv.prepares, 1); // asked once, not on every student
    await q.dispose();
  });

  test('the queue is bounded', () async {
    final q = make(maxQueue: 3);
    for (var i = 0; i < 10; i++) {
      q.maybeReply(10001 + i, _mac);
    }
    expect(q.waiting, lessThanOrEqualTo(3));
    await q.dispose();
  });

  test('dispose stops everything', () async {
    final q = make();
    q.maybeReply(10001, _mac);
    q.maybeReply(10002, _mac);
    await q.dispose();
    await _wait(100);

    expect(adv.onAir, isFalse);
    expect(adv.started.length, lessThanOrEqualTo(1));
  });
}
