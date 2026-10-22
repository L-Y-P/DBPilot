// Connection opening must never look like a frozen button.
//
// Contract under test (round 37, user report): the progress dialog appears
// immediately, admits the connection is slow after 5 s, offers 取消 only after
// 15 s, and a cancelled attempt can never apply a late result.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/connection_progress_dialog.dart';

Widget harness({
  required Future<void> Function() connect,
  void Function(Object error)? onError,
}) =>
    MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open'),
              onPressed: () => showConnectionProgress(
                context,
                label: 'MySQL local sakila · 127.0.0.1:3306',
                connect: connect,
                onError: onError ?? (_) {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('0-5s: connecting only, no cancel button', (tester) async {
    final pending = Completer<void>();
    await tester.pumpWidget(harness(connect: () => pending.future));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump(); // dialog route

    expect(find.byKey(const ValueKey('conn-progress')), findsOneWidget);
    expect(find.byKey(const ValueKey('conn-progress-status')), findsOneWidget);
    expect(find.byKey(const ValueKey('conn-progress-elapsed')), findsNothing);
    expect(find.byKey(const ValueKey('conn-progress-cancel')), findsNothing);
    // The target is named, so the user knows what is being opened.
    expect(find.textContaining('127.0.0.1:3306'), findsOneWidget);

    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('conn-progress-elapsed')), findsNothing);
    expect(find.byKey(const ValueKey('conn-progress-cancel')), findsNothing);

    pending.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('>=5s: elapsed counter appears and ticks', (tester) async {
    final pending = Completer<void>();
    await tester.pumpWidget(harness(connect: () => pending.future));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();

    await tester.pump(const Duration(seconds: 6));
    // The app renders through its own translating Text, so read the label via
    // the finder rather than casting to flutter/material's Text.
    final first = find.byKey(const ValueKey('conn-progress-elapsed'));
    expect(first, findsOneWidget);
    expect(find.descendant(of: first, matching: find.textContaining('6')),
        findsOneWidget);
    // From 5s on, cancelling is allowed (same threshold as the hint).
    expect(find.byKey(const ValueKey('conn-progress-cancel')), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(find.descendant(of: first, matching: find.textContaining('7')),
        findsOneWidget);

    pending.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('>=5s: the slow hint and the cancel button appear together',
      (tester) async {
    final pending = Completer<void>();
    await tester.pumpWidget(harness(connect: () => pending.future));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();

    // 4s: neither yet - a fast connection must not flash a cancel button.
    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('conn-progress-elapsed')), findsNothing);
    expect(find.byKey(const ValueKey('conn-progress-cancel')), findsNothing);

    // 5s: both appear at the same moment, which is the user's rule.
    await tester.pump(const Duration(seconds: 1));
    expect(find.byKey(const ValueKey('conn-progress-elapsed')), findsOneWidget);
    expect(find.byKey(const ValueKey('conn-progress-cancel')), findsOneWidget);

    pending.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('a late success after cancelling is dropped', (tester) async {
    final pending = Completer<void>();
    ConnectionProgressResult? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () async {
                result = await showConnectionProgress(
                  context,
                  label: 'MySQL',
                  connect: () => pending.future,
                  onError: (_) {},
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));

    await tester.tap(find.byKey(const ValueKey('conn-progress-cancel')));
    await tester.pumpAndSettle();
    expect(result, ConnectionProgressResult.cancelled);
    expect(find.byKey(const ValueKey('conn-progress')), findsNothing);

    // The attempt finishing later must not reopen anything or crash.
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conn-progress')), findsNothing);
  });

  testWidgets('failure turns the dialog into an error state', (tester) async {
    Object? reported;
    await tester.pumpWidget(harness(
      connect: () async => throw Exception('connection refused'),
      onError: (error) => reported = error,
    ));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('conn-progress-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('conn-progress-close')), findsOneWidget);
    expect(find.byKey(const ValueKey('conn-progress-cancel')), findsNothing);
    expect(reported, isNotNull, reason: 'the page keeps its own error banner');

    await tester.tap(find.byKey(const ValueKey('conn-progress-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conn-progress')), findsNothing);
  });

  testWidgets('a fast success closes the dialog by itself', (tester) async {
    await tester.pumpWidget(harness(connect: () async {}));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conn-progress')), findsNothing);
  });

  testWidgets('a second open while one is pending does not stack dialogs',
      (tester) async {
    // Two clicks (or two entry points) must not put one dialog on top of the
    // other: each would own a timer, so the visible counter would belong to the
    // wrong attempt and the covered dialog's buttons would be unreachable.
    final pending = Completer<void>();
    await tester.pumpWidget(harness(connect: () => pending.future));
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    // The modal barrier now covers the button, so this second tap is expected
    // to miss - that is exactly the double click being guarded against.
    await tester.tap(find.byKey(const ValueKey('open')), warnIfMissed: false);
    await tester.pump();

    expect(find.byKey(const ValueKey('conn-progress')), findsOneWidget);

    // The counter belongs to a single dialog, so it advances by exactly the
    // wall clock, not by the number of clicks.
    await tester.pump(const Duration(seconds: 6));
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('conn-progress-elapsed')),
            matching: find.textContaining('6')),
        findsOneWidget);

    pending.complete();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('conn-progress')), findsNothing);
  });
}
