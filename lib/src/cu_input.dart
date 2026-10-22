// Computer-Use 文本注入桥（默认关闭）。
//
// 背景：macOS 的 Computer-Use 驱动无法把合成键盘事件稳定地送进 Flutter 的
// EditableText（AX 写值只能落到可访问性节点，不会进 TextEditingController），
// 但驱动可以点按界面、读取状态。这里提供一个"只在一个地方拦截"的注入通道：
//
//   1. 监听全局焦点（FocusManager），拿到当前获得焦点的 EditableTextState；
//   2. 往它的 controller 里写入文本（替换选区 / 光标插入 / 整段替换）；
//   3. 只在本机回环地址上开一个极小的 HTTP 接口，且必须显式开启
//      （环境变量 RMA_CU_INPUT=1），默认完全不启动。
//
// 这样自动化脚本只需要：点一下目标输入框 → POST /text → 文本进入 controller，
// 不需要逐字符模拟键盘，也不受符号/中文输入法限制。
//
// 开关：
//   RMA_CU_INPUT=1  启用（默认关闭）
//   RMA_CU_PORT=47823  可选，监听端口（默认 47823，仅 127.0.0.1）
//
// 接口：
//   GET  /status        -> { enabled, port, focused, text }
//   POST /text?replace=1  请求体为 UTF-8 文本；replace=1 表示整段替换，否则在
//                         当前选区/光标处插入。返回 { ok, focused, text }

import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

/// Computer-Use 文本注入器（单例）。
class CuTextInput {
  CuTextInput._();

  static final CuTextInput instance = CuTextInput._();

  static const String envEnable = 'RMA_CU_INPUT';
  static const String envPort = 'RMA_CU_PORT';
  static const int defaultPort = 47823;

  bool _enabled = false;
  HttpServer? _server;

  /// 当前获得焦点的输入框。
  EditableTextState? _active;

  /// 最近一次获得焦点的输入框；点击「执行」等按钮后焦点会离开编辑器，
  /// 自动化仍希望能继续往刚才那个输入框写文本，所以保留它做兜底。
  EditableTextState? _lastFocused;

  bool get enabled => _enabled;
  int get port => _server?.port ?? 0;
  EditableTextState? get active => _active;

  /// 读取环境变量；只有显式要求时才启用（Computer Use 模式开关）。
  Future<void> bootstrapFromEnvironment() async {
    if (_enabled) return;
    if (Platform.environment[envEnable] != '1') return;
    _enabled = true;
    FocusManager.instance.addListener(_onFocusChanged);
    _onFocusChanged();
    final requested =
        int.tryParse(Platform.environment[envPort] ?? '') ?? defaultPort;
    try {
      // 只绑定回环地址，不对外网暴露。
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, requested);
      _server!.listen(_handleRequest, onError: (Object _) {});
    } catch (_) {
      _enabled = false;
      _server = null;
    }
  }

  /// 测试/自动化需要时可绕过环境变量直接启用（不会启动 HTTP）。
  @visibleForTesting
  void debugEnable() {
    _enabled = true;
    FocusManager.instance.addListener(_onFocusChanged);
    _onFocusChanged();
  }

  @visibleForTesting
  void debugDisable() {
    _enabled = false;
    _server?.close(force: true);
    _server = null;
    FocusManager.instance.removeListener(_onFocusChanged);
    _active = null;
  }

  /// 焦点变化时刷新"当前 EditableText"。
  void _onFocusChanged() {
    final found = _resolveFocusedEditable();
    if (found != null) {
      _active = found;
      _lastFocused = found;
    } else if (_active != null && !_active!.mounted) {
      _active = null;
    }
  }

  /// 注入目标：优先当前焦点，其次最近一次聚焦且仍然挂载的输入框。
  EditableTextState? get _target {
    if (_active != null && _active!.mounted) return _active;
    if (_lastFocused != null && _lastFocused!.mounted) return _lastFocused;
    return null;
  }

  EditableTextState? _resolveFocusedEditable() {
    final focus = FocusManager.instance.primaryFocus;
    final fromFocus = focus?.context?.findAncestorStateOfType<EditableTextState>();
    if (fromFocus != null) return fromFocus;
    // 兜底：从根元素遍历，按 focusNode.hasFocus 找到唯一获得焦点的输入框。
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;
    return _findFocusedIn(root);
  }

  EditableTextState? _findFocusedIn(Element element) {
    if (element is StatefulElement && element.state is EditableTextState) {
      final state = element.state as EditableTextState;
      if (state.widget.focusNode.hasFocus) return state;
    }
    EditableTextState? found;
    element.visitChildElements((Element child) {
      found ??= _findFocusedIn(child);
    });
    return found;
  }

  /// 把文本写进当前获得焦点的输入框。
  ///
  /// [replace] 为 true 时整段替换，否则替换当前选区/在光标处插入。
  bool inject(String text, {bool replace = false}) {
    if (!_enabled) return false;
    final state = _target;
    if (state == null) return false;
    final controller = state.widget.controller;
    if (replace) {
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      );
    } else {
      final value = controller.value;
      final selection = value.selection.isValid
          ? value.selection
          : TextSelection.collapsed(offset: value.text.length);
      controller.value = value.replaced(selection, text);
    }
    return true;
  }

  Map<String, Object?> status() {
    final focused = _active != null && _active!.mounted;
    final state = _target;
    final text = state?.widget.controller.text ?? '';
    return <String, Object?>{
      'enabled': _enabled,
      'port': port,
      'focused': focused,
      'target': state != null,
      'text': text,
    };
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    try {
      if (request.method == 'GET' && request.uri.path == '/status') {
        response.write(jsonEncode(status()));
      } else if (request.method == 'POST' && request.uri.path == '/text') {
        final body = await utf8.decoder.bind(request).join();
        final replace = request.uri.queryParameters['replace'] == '1';
        final ok = inject(body, replace: replace);
        response.statusCode = ok ? HttpStatus.ok : HttpStatus.conflict;
        response.write(jsonEncode(<String, Object?>{
          'ok': ok,
          'focused': _active != null && _active!.mounted,
          'text': _target?.widget.controller.text ?? '',
        }));
      } else {
        response.statusCode = HttpStatus.notFound;
        response.write(jsonEncode(<String, Object?>{'ok': false}));
      }
    } catch (error) {
      response.statusCode = HttpStatus.internalServerError;
      response.write(jsonEncode(<String, Object?>{'ok': false, 'error': '$error'}));
    } finally {
      await response.close();
    }
  }
}
