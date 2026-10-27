// The README's Flutter quick start (lib/readme/quick_start_flutter.dart,
// written from README.md by tool/docs.dart), driven as a user would, against
// a live Plexivo Postgres over real HTTP and WebSockets:
//
//   flutter test --dart-define=PLEXIVO_URL=… --dart-define=PLEXIVO_PUBLISHABLE_KEY=…
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plexivo_flutter_example/readme/quick_start_flutter.dart' as app;

const _url = String.fromEnvironment('PLEXIVO_URL');

/// Lets real network I/O happen, then rebuilds, until [finder] matches.
Future<void> pumpUntil(WidgetTester tester, Finder finder, {Duration timeout = const Duration(seconds: 30)}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('timed out waiting for $finder');
}

void main() {
  testWidgets('the README quick start: guest sign-in, add a todo, see it live, tick it', (tester) async {
    if (_url.isEmpty) {
      markTestSkipped('pass --dart-define=PLEXIVO_URL=… and PLEXIVO_PUBLISHABLE_KEY=…');
      return;
    }
    // flutter_test answers every HTTP request with 400; this test talks to the real backend.
    HttpOverrides.global = null;

    await tester.pumpWidget(const app.TodoApp());
    expect(find.text('Continue as guest'), findsOneWidget);

    await tester.tap(find.text('Continue as guest'));
    await pumpUntil(tester, find.byType(TextField));
    expect(app.db.currentUser?['is_anonymous'], isTrue);

    final title = 'Milk ${DateTime.now().microsecondsSinceEpoch}';
    await tester.enterText(find.byType(TextField), title);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    // The list is a StreamBuilder over realtime changes: the new row arrives by itself.
    await pumpUntil(tester, find.text(title));

    await tester.tap(find.byType(Checkbox).last);
    await pumpUntil(tester, find.byWidgetPredicate((w) => w is Checkbox && w.value == true));
    final rows = await tester.runAsync(() => app.db.from('todos').eq('title', title));
    expect(rows!.single['done'], isTrue);

    await tester.tap(find.byIcon(Icons.logout));
    await pumpUntil(tester, find.text('Continue as guest'));
    expect(app.db.session, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    // Let the HTTP client's idle keep-alive timers (created in the test's fake time) run out.
    await tester.pump(const Duration(seconds: 30));
  });
}
