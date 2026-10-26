// The macOS path hands the menu to AppKit over a method channel. Widget tests
// run with the target platform stubbed to android, so without this file the
// native branch would never execute in CI.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/app_menu.dart';
import 'package:rust_myadmin_desktop/src/native_menu.dart';

/// Run [body] with the platform stubbed to macOS.
///
/// The override has to be cleared *inside* the test body: the binding checks
/// that no foundation debug variable was left set at the end of the body,
/// before tearDown runs.
/// The AppKit menu is opt-in (see native_menu.dart: popUp blocks the platform
/// thread), so these tests switch it on explicitly.
Future<T> onMacOS<T>(Future<T> Function() body) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  debugNativeMenuEnabled = true;
  try {
    return await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
    debugNativeMenuEnabled = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final calls = <MethodCall>[];
  var nextIndex = 0;

  void mockMenu(int index) {
    nextIndex = index;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeMenuChannel, (call) async {
      calls.add(call);
      return nextIndex;
    });
  }

  setUp(() {
    calls.clear();
    mockMenu(0);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeMenuChannel, null);
  });

  test('macOS is reported as having a native menu', () async {
    await onMacOS(() async {
      expect(hasNativeMenu, isTrue);
    });
  });

  test('non-macOS platforms never take the native path', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      expect(hasNativeMenu, isFalse);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the native menu receives the labels and returns the choice',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          ctx = context;
          return const SizedBox();
        }),
      ),
    ));

    mockMenu(2);
    var picked = '';
    final chosen = await onMacOS(() => showAppContextMenu(
          ctx,
          <AppMenuEntry>[
            AppMenuEntry(label: '刷新', onSelected: () => picked = '刷新'),
            AppMenuEntry(
              label: '新建表',
              separatorBefore: true,
              onSelected: () => picked = '新建表',
            ),
            AppMenuEntry(label: '关系图', onSelected: () => picked = '关系图'),
          ],
          position: const Offset(40, 60),
        ));

    expect(calls, hasLength(1));
    expect(calls.single.method, 'show');
    final args = calls.single.arguments as Map<Object?, Object?>;
    expect(args['x'], 40.0);
    expect(args['y'], 60.0);
    final items = (args['items'] as List).cast<Map<Object?, Object?>>();
    expect(
      items.map((i) => i['label']).toList(),
      <String>['刷新', '新建表', '关系图'],
    );
    expect(items[0]['separator'], isFalse);
    expect(items[1]['separator'], isTrue);
    expect(items.every((i) => i['enabled'] == true), isTrue);

    // Index 2 is 关系图: the callback runs and the label comes back.
    expect(chosen, '关系图');
    expect(picked, '关系图');
  });

  testWidgets('a dismissed native menu runs nothing', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          ctx = context;
          return const SizedBox();
        }),
      ),
    ));

    mockMenu(-1);
    var picked = 0;
    final chosen = await onMacOS(() => showAppContextMenu(
          ctx,
          <AppMenuEntry>[
            AppMenuEntry(label: '刷新', onSelected: () => picked++),
          ],
          position: const Offset(10, 10),
        ));
    expect(chosen, isNull);
    expect(picked, 0);
  });

  testWidgets('an unavailable channel yields null instead of throwing',
      (tester) async {
    // Simulates a build whose runner has no handler: the engine answers with
    // MissingPluginException. (Removing the mock would hang instead — in a
    // widget test an unhandled channel is never answered at all.)
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeMenuChannel, (call) async {
      throw MissingPluginException('no handler');
    });

    final result = await onMacOS(() => showNativeMenu(
          <Map<String, Object?>>[
            <String, Object?>{'label': 'a', 'enabled': true},
          ],
          0,
          0,
        ));
    expect(result, isNull, reason: 'the failure must not escape');
  });

  testWidgets('an unavailable channel falls back to the Flutter menu',
      (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(nativeMenuChannel, (call) async {
      throw MissingPluginException('no handler');
    });

    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          ctx = context;
          return const SizedBox();
        }),
      ),
    ));

    final future = onMacOS(() => showAppContextMenu(
          ctx,
          <AppMenuEntry>[AppMenuEntry(label: '刷新', onSelected: () {})],
          position: const Offset(20, 20),
        ));
    await tester.pumpAndSettle();
    // The Flutter-drawn menu took over, so its row is on screen.
    expect(find.text('刷新'), findsOneWidget);
    await tester.tap(find.text('刷新'));
    await tester.pumpAndSettle();
    expect(await future, '刷新');
  });

  testWidgets('a dismissed native menu does NOT fall back', (tester) async {
    // -1 means 'shown and cancelled': drawing a second menu would be wrong.
    mockMenu(-1);
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) {
          ctx = context;
          return const SizedBox();
        }),
      ),
    ));

    final chosen = await onMacOS(() => showAppContextMenu(
          ctx,
          <AppMenuEntry>[AppMenuEntry(label: '刷新', onSelected: () {})],
          position: const Offset(20, 20),
        ));
    await tester.pumpAndSettle();
    expect(chosen, isNull);
    expect(find.text('刷新'), findsNothing,
        reason: 'cancelling the native menu must not open the Flutter one');
  });
}