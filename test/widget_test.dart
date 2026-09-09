import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:attendance_assistant/main.dart';

void main() {
  testWidgets('App boots to the login screen when logged out', (WidgetTester tester) async {
    // Without this, SharedPreferences.getInstance() has no real platform
    // channel to answer it in the test environment and never resolves,
    // leaving AuthProvider.isLoading stuck true (and its
    // CircularProgressIndicator's spinner never "settles" either way).
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const AttendanceAssistantApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Attendance Assistant'), findsOneWidget);
    expect(find.text('Sign In'), findsOneWidget);
  });
}
