import 'dart:convert';

import 'package:attendance_assistant/providers/auth_provider.dart';
import 'package:attendance_assistant/screens/zoom_home_screen.dart';
import 'package:attendance_assistant/screens/zoom_session_screen.dart';
import 'package:attendance_assistant/models/roster_student.dart';
import 'package:attendance_assistant/services/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Future<void> _pump(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Widget _app(Widget home) => ChangeNotifierProvider(create: (_) => AuthProvider(), child: MaterialApp(home: home));

void main() {
  test('RosterStudent reads the Zoom flags', () {
    final s = RosterStudent.fromJson({'id': 1, 'name': 'A', 'is_makeup': 1, 'attended_elsewhere': true, 'group_name': 'B'});
    expect(s.isMakeup, isTrue);
    expect(s.attendedElsewhere, isTrue);
    expect(s.groupName, 'B');
    expect(RosterStudent.fromJson({'id': 2, 'name': 'C'}).isMakeup, isFalse);
  });

  testWidgets('lessons list, group picker, then the session opens', (tester) async {
    final seen = <String>[];
    final api = ApiClient(client: MockClient((r) async {
      seen.add('${r.method} ${r.url.path}');
      final p = r.url.path;
      if (p.endsWith('/zoom/lessons')) {
        return _json({'lessons': [{'id': 5, 'title': 'Limits', 'lesson_date': '2026-10-14 00:00:00', 'quiz_max_mark': 10, 'sessions': [{'group_id': 1, 'status': 'submitted'}]}]});
      }
      if (p.endsWith('/zoom/groups')) return _json({'groups': [{'id': 1, 'name': 'A', 'students_count': 3}, {'id': 2, 'name': 'B', 'students_count': 2}]});
      if (p.endsWith('/lessons/5/groups/2/roster')) {
        return _json({'session_status': null, 'students': [
          {'id': 11, 'name': 'Omar Zoom', 'status': 'absent', 'is_makeup': false, 'attended_elsewhere': true},
          {'id': 12, 'name': 'Sara Zoom', 'status': 'absent', 'is_makeup': false, 'attended_elsewhere': false},
        ]});
      }
      return _json({});
    }));
    await tester.pumpWidget(_app(ZoomHomeScreen(api: api)));
    await _pump(tester);
    expect(find.text('Limits'), findsOneWidget);
    expect(find.textContaining('1/2 groups submitted'), findsOneWidget);

    await tester.tap(find.text('Limits'));
    await _pump(tester, 5);
    expect(find.text('submitted'), findsOneWidget);
    await tester.tap(find.textContaining('Group B'));
    await _pump(tester, 15);
    expect(find.text('Omar Zoom'), findsOneWidget);
    expect(find.text('Already attended this lesson in another group'), findsOneWidget);
    expect(find.text('0 present / 2'), findsOneWidget);
  });

  testWidgets('submitting sends every student mark to the group endpoint', (tester) async {
    Map<String, dynamic>? body;
    final api = ApiClient(client: MockClient((r) async {
      final p = r.url.path;
      if (p.endsWith('/roster')) {
        return _json({'session_status': null, 'students': [{'id': 11, 'name': 'Omar Zoom', 'status': 'present'}]});
      }
      if (p.endsWith('/submit')) {
        body = jsonDecode(r.body) as Map<String, dynamic>;
        return _json({'summary': {'expected': 1, 'present': 1, 'absent': 0, 'makeup': 0}, 'parent_summaries': []});
      }
      return _json({});
    }));
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(ZoomSessionScreen(lessonId: 5, lessonTitle: 'Limits', quizMax: 10, groupId: 2, groupName: 'B', api: api)));
    await _pump(tester);
    await tester.tap(find.text('Submit Session'));
    await _pump(tester, 5);
    await tester.tap(find.text('Submit').last);
    await _pump(tester, 15);
    expect(body!['records'], [
      {'student_id': 11, 'status': 'present', 'homework_done': null, 'quiz_mark': null}
    ]);
  });

  testWidgets('a connection failure shows a retry instead of crashing', (tester) async {
    final api = ApiClient(client: MockClient((r) async => throw http.ClientException('offline')));
    await tester.pumpWidget(_app(ZoomHomeScreen(api: api)));
    await _pump(tester);
    expect(find.text('Retry'), findsOneWidget);
  });
}
