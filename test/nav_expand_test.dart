// 侧边栏默认收起：连接成功后的首个路由不能顺手展开树。
//
// 用户反馈「应用打开时默认展开第一个数据库列表」：原因是 Navigation.go()
// 会把 route.db 加进 expanded，加上 _Sidebar 的 _autoOpenActive 又主动展开
// 数据库/默认 schema。现在 go() 支持 expandTree:false，连接流程用它；本测试
// 固定这条契约，避免以后又把默认展开加回来。

import 'package:flutter_test/flutter_test.dart';
import 'package:rust_myadmin_desktop/src/nav.dart';

void main() {
  setUp(() {
    final nav = Navigation.instance;
    nav.resetTree();
    nav.go(AppRoute.connections);
  });

  tearDown(() => Navigation.instance.resetTree());

  test('go(expandTree: false) opens the route without expanding the tree', () {
    final nav = Navigation.instance;
    nav.go(AppRoute.database('shop'), expandTree: false);
    expect(nav.route.db, 'shop');
    expect(nav.lastDatabase, 'shop');
    expect(nav.expanded, isEmpty,
        reason: '连接成功后的首个路由必须让侧边栏保持收起');
  });

  test('go() keeps expanding the tree for explicit clicks', () {
    final nav = Navigation.instance;
    nav.go(AppRoute.database('shop'));
    expect(nav.expanded, contains('shop'));
  });

  test('repeating the same route with expandTree: false never expands', () {
    final nav = Navigation.instance;
    nav.go(AppRoute.database('shop'), expandTree: false);
    nav.go(AppRoute.database('shop'), expandTree: false);
    expect(nav.expanded, isEmpty);
  });
}
