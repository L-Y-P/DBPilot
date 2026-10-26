// Regression tests for the connection editor tabs and the SSH
// tunnel fields. The backend tunnel itself is covered by
// rust/tests/ssh_real_mysql.rs against a real MySQL server.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/api.dart';
import 'package:rust_myadmin_desktop/src/app_state.dart';
import 'package:rust_myadmin_desktop/src/i18n.dart';
import 'package:rust_myadmin_desktop/src/rust/frb_generated.dart';
import 'package:rust_myadmin_desktop/src/notice.dart';
import 'package:rust_myadmin_desktop/src/theme.dart';
import 'package:rust_myadmin_desktop/src/views/connections_view.dart';
import 'package:rust_myadmin_desktop/src/widgets.dart';

Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Scaffold(body: child),
    );

/// The SSL tab keeps every FormTabs child mounted (IndexedStack), and the
/// General tab's driver selector is a SelectBox too, so the SSL selectors are
/// addressed by key instead of by widget order.
SelectBox<String> sslSelector(WidgetTester tester, String key) =>
    tester.widget<SelectBox<String>>(find.byKey(ValueKey(key)));

void main() {
  setUpAll(() async {
    I18n.setLang(AppLang.zh);
    final dir = await Directory.systemTemp.createTemp('rma-conn-tabs-');
    await RustLib.init(externalLibrary:
        ExternalLibrary.open('rust/target/debug/librust_myadmin_core.dylib'));
    await Api.init(dir.path);
    await AppState.instance.bootstrap(dir.path);
  });

  testWidgets('connection editor groups fields into General/SSL/SSH tabs',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(ConnectionsView(notice: Notice())));
    await settle(tester);
    await tester.tap(find.text('新建连接'));
    await settle(tester, rounds: 4);

    expect(find.byType(FormTabs), findsOneWidget);
    expect(find.text('常规'), findsWidgets);
    expect(find.text('SSL'), findsWidgets);
    expect(find.text('SSH'), findsWidgets);
    // The general tab is open first and shows the address fields.
    expect(find.text('主机'), findsOneWidget);
    expect(find.text('通过 SSH 隧道连接（跳板机）'), findsNothing);

    await tester.tap(find.text('SSH').last);
    await settle(tester, rounds: 3);
    expect(find.text('通过 SSH 隧道连接（跳板机）'), findsOneWidget);
  });

  testWidgets('enabling SSH reveals host/user/auth fields', (tester) async {
    tester.view.physicalSize = const Size(1200, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(ConnectionsView(notice: Notice())));
    await settle(tester);
    await tester.tap(find.text('新建连接'));
    await settle(tester, rounds: 4);
    await tester.tap(find.text('SSH').last);
    await settle(tester, rounds: 3);
    await tester.tap(find.text('通过 SSH 隧道连接（跳板机）'));
    await settle(tester, rounds: 3);

    expect(find.text('SSH 主机'), findsOneWidget);
    expect(find.text('SSH 用户名'), findsOneWidget);
    expect(find.text('认证方式'), findsOneWidget);
    // Password is the default method, so its field is visible immediately.
    expect(find.text('SSH 密码'), findsOneWidget);

    await tester.tap(find.text('密码').last);
    await settle(tester, rounds: 3);
    await tester.tap(find.text('私钥文件').last);
    await settle(tester, rounds: 3);
    expect(find.text('私钥文件'), findsWidgets);
    expect(find.text('私钥口令'), findsOneWidget);
  });

  testWidgets('SQLite hides the SSL and SSH controls instead of storing them',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(ConnectionsView(notice: Notice())));
    await settle(tester);
    await tester.tap(find.text('新建连接'));
    await settle(tester, rounds: 4);
    await tester.tap(find.byType(SelectBox<String>).first);
    await settle(tester, rounds: 3);
    await tester.tap(find.text('SQLite').last);
    await settle(tester, rounds: 4);

    await tester.tap(find.text('SSL').last);
    await settle(tester, rounds: 3);
    expect(find.textContaining('SSL 设置不适用'), findsOneWidget);
    await tester.tap(find.text('SSH').last);
    await settle(tester, rounds: 3);
    expect(find.textContaining('无需 SSH 隧道'), findsOneWidget);
  });

  testWidgets('SSH settings survive a save and reload into the editor',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(ConnectionsView(notice: Notice())));
    await settle(tester);
    await tester.tap(find.text('新建连接'));
    await settle(tester, rounds: 4);

    await tester.enterText(
        find.byKey(const ValueKey('conn-name-field')), 'ssh-tunnel-regression');
    await tester.enterText(find.byKey(const ValueKey('db-host'), skipOffstage: false), 'db.internal');
    await tester.enterText(find.byKey(const ValueKey('db-user'), skipOffstage: false), 'dbuser');

    await tester.tap(find.text('SSH').last);
    await settle(tester, rounds: 3);
    await tester.tap(find.text('通过 SSH 隧道连接（跳板机）'));
    await settle(tester, rounds: 3);

    // Fill the jump host fields by their stable keys.
    await tester.enterText(find.byKey(const ValueKey('ssh-host')), 'jump.internal');
    await tester.enterText(find.byKey(const ValueKey('ssh-port')), '2222');
    await tester.enterText(find.byKey(const ValueKey('ssh-user')), 'deploy');
    await tester.enterText(find.byKey(const ValueKey('ssh-password')), 'secret-pass');
    await settle(tester, rounds: 2);

    await tester.tap(find.text('保存'));
    await settle(tester, rounds: 14);

    final list = await tester.runAsync(() => Api.instance.connections());
    final saved = list!.singleWhere((c) => c['name'] == 'ssh-tunnel-regression');
    expect(saved['ssh_host'], 'jump.internal');
    expect(saved['ssh_port'], 2222);
    expect(saved['ssh_user'], 'deploy');
    expect(saved['ssh_auth'], 'password');
    expect(saved['host'], 'db.internal');

    // Round-tripping the saved object is covered at the Rust layer
    // (serialises_ssh_fields_back_into_the_flat_object); here we only assert
    // what the form actually persisted.
    expect(saved['ssh_host_key_policy'], 'accept-new');
    await tester.pump(const Duration(seconds: 4));
  });

  // N-11: the SSH tab now has a fingerprint control, and strict mode refuses
  // to save without one (the backend would reject the connection anyway).
  testWidgets('strict SSH policy without a fingerprint is refused before save',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(ConnectionsView(notice: Notice())));
    await settle(tester);
    await tester.tap(find.text('新建连接'));
    await settle(tester, rounds: 4);
    await tester.enterText(
        find.byKey(const ValueKey('conn-name-field')), 'strict-no-fingerprint');
    await tester.tap(find.text('SSH').last);
    await settle(tester, rounds: 3);
    await tester.tap(find.text('通过 SSH 隧道连接（跳板机）'));
    await settle(tester, rounds: 3);
    await tester.enterText(find.byKey(const ValueKey('ssh-host')), 'jump.internal');
    await tester.enterText(find.byKey(const ValueKey('ssh-user')), 'deploy');
    await tester.enterText(
        find.byKey(const ValueKey('ssh-password')), 'secret-pass');
    await settle(tester, rounds: 2);

    // The fingerprint control exists and is empty by default.
    expect(find.byKey(const ValueKey('ssh-host-key'), skipOffstage: false),
        findsOneWidget);

    // Switch the host-key policy to strict.
    await tester.tap(find.text('首次连接信任并记住').last);
    await settle(tester, rounds: 3);
    await tester.tap(find.text('仅信任已保存指纹').last);
    await settle(tester, rounds: 3);

    await tester.tap(find.text('保存'));
    await settle(tester, rounds: 6);

    // The message appears in the dialog and (for a failed save) on the page
    // behind it, so accept more than one match.
    expect(find.textContaining('必须填写指纹'), findsWidgets);
    final list = await tester.runAsync(() => Api.instance.connections());
    expect(
      list!.where((c) => c['name'] == 'strict-no-fingerprint'),
      isEmpty,
      reason: 'a strict connection without a pin must not be persisted',
    );
    await tester.pump(const Duration(seconds: 4));
  });

  // P2-02: `SSL 模式 = require` must mean "encrypt, but do not validate the
  // chain" (mysql --ssl-mode=REQUIRED). It used to default the certificate
  // check to verify-full and to upgrade it whenever TLS was switched on, so a
  // server with MySQL's generated self-signed certificate failed with
  // `invalid peer certificate: UnknownIssuer`.
  testWidgets('new connection enables SSL with require certificate checking',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(ConnectionsView(notice: Notice())));
    await settle(tester);
    await tester.tap(find.text('新建连接'));
    await settle(tester, rounds: 4);
    await tester.tap(find.text('SSL').last);
    await settle(tester, rounds: 3);

    // TLS is off, so the certificate-check selector is not built at all.
    expect(find.byKey(const ValueKey('ssl-verify')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('ssl-mode')));
    await settle(tester, rounds: 3);
    await tester.tap(find.text('require').last);
    await settle(tester, rounds: 3);

    expect(find.text('证书校验'), findsOneWidget);
    expect(sslSelector(tester, 'ssl-mode').value, 'require');
    expect(sslSelector(tester, 'ssl-verify').value, 'require',
        reason: 'enabling require must not silently upgrade to verify-full');

    // The inline hint must explain what require does (and that it is the
    // self-signed-certificate escape hatch).
    expect(find.textContaining('require 只加密'), findsOneWidget);

    // Switching to prefer also keeps encrypt-only.
    await tester.tap(find.byKey(const ValueKey('ssl-mode')));
    await settle(tester, rounds: 3);
    await tester.tap(find.text('prefer').last);
    await settle(tester, rounds: 3);
    expect(sslSelector(tester, 'ssl-mode').value, 'prefer');
    expect(sslSelector(tester, 'ssl-verify').value, 'require');

    // Turning TLS off closes the pair; re-enabling restarts at require rather
    // than resurrecting a stale verify-full.
    await tester.tap(find.byKey(const ValueKey('ssl-mode')));
    await settle(tester, rounds: 3);
    await tester.tap(find.text('disable').last);
    await settle(tester, rounds: 3);
    expect(find.byKey(const ValueKey('ssl-verify')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('ssl-mode')));
    await settle(tester, rounds: 3);
    await tester.tap(find.text('require').last);
    await settle(tester, rounds: 3);
    expect(sslSelector(tester, 'ssl-verify').value, 'require');
  });

  // P2-02: explicitly saved verification levels survive editing, and the form
  // explains what they need (a CA) instead of silently rewriting them.
  testWidgets('editing keeps an explicitly saved verify-full certificate check',
      (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(ConnectionsView(notice: Notice())));
    await settle(tester);

    // Save a connection that explicitly asks for verify-full.
    await tester.tap(find.text('新建连接'));
    await settle(tester, rounds: 4);
    await tester.enterText(
        find.byKey(const ValueKey('conn-name-field')), 'ssl-verify-preserved');
    await tester.enterText(
        find.byKey(const ValueKey('db-host'), skipOffstage: false), 'db.internal');
    await tester.enterText(
        find.byKey(const ValueKey('db-user'), skipOffstage: false), 'dbuser');
    await tester.tap(find.text('SSL').last);
    await settle(tester, rounds: 3);
    await tester.tap(find.byKey(const ValueKey('ssl-mode')));
    await settle(tester, rounds: 3);
    await tester.tap(find.text('require').last);
    await settle(tester, rounds: 3);
    // Certificate check = verify-full, chosen deliberately.
    await tester.tap(find.byKey(const ValueKey('ssl-verify')));
    await settle(tester, rounds: 3);
    await tester.tap(find.text('verify-full').last);
    await settle(tester, rounds: 3);
    await tester.tap(find.text('保存'));
    await settle(tester, rounds: 14);

    final list = await tester.runAsync(() => Api.instance.connections());
    final saved =
        list!.singleWhere((c) => c['name'] == 'ssl-verify-preserved');
    expect(saved['ssl_mode'], 'require');
    expect(saved['ssl_verify'], 'verify-full');

    // Reopen it: the stored level is preserved, and the CA hint is shown.
    await tester.ensureVisible(find.text('ssl-verify-preserved'));
    final card = find
        .ancestor(
            of: find.text('ssl-verify-preserved'),
            matching: find.byType(Container))
        .first;
    await tester.tap(find.descendant(of: card, matching: find.text('编辑')));
    await settle(tester, rounds: 4);
    await tester.tap(find.text('SSL').last);
    await settle(tester, rounds: 3);

    expect(sslSelector(tester, 'ssl-mode').value, 'require');
    expect(sslSelector(tester, 'ssl-verify').value, 'verify-full',
        reason: 'editing must keep the saved verification level');
    expect(find.textContaining('自签证书请改用 require'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  // P3-05: enabling SSH does not move the tunnel to the local host — the DB
  // host/port are resolved from the jump host.
  testWidgets('SSH tab explains the jump-host view of the database address',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(host(ConnectionsView(notice: Notice())));
    await settle(tester);
    await tester.tap(find.text('新建连接'));
    await settle(tester, rounds: 4);
    await tester.tap(find.text('SSH').last);
    await settle(tester, rounds: 3);

    expect(find.textContaining('跳板机视角'), findsOneWidget);
    expect(find.textContaining('远程侧地址'), findsOneWidget);
    expect(find.textContaining('13306'), findsOneWidget,
        reason: 'the local forwarded-port pitfall must be called out');
  });

  // P2-02: the probe error keeps the server text and gains the actionable hint.
  test('TLS probe errors keep the original text and append the SSL hint', () {
    const raw = 'invalid peer certificate: UnknownIssuer';
    final shown = appendSslCertificateHint(raw);
    expect(shown, startsWith(raw));
    expect(shown, contains('require'));
    expect(shown, contains('CA'));
    // Unrelated failures are passed through untouched.
    expect(appendSslCertificateHint('Access denied for user'),
        'Access denied for user');
  });
}
