import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    // 第一帧出现之前 FlutterView 的绘制面是黑的：窗口与 FlutterView 都用
    // 系统窗口底色垫底（FlutterViewController.backgroundColor 是引擎官方
    // 提供的首帧前底色），否则启动/缩放时会闪一下黑窗口。
    self.backgroundColor = NSColor.windowBackgroundColor
    flutterViewController.backgroundColor = NSColor.windowBackgroundColor

    RegisterGeneratedPlugins(registry: flutterViewController)
    NativeMenuBridge.register(with: flutterViewController)

    super.awakeFromNib()
  }
}

/// 右键菜单走原生 NSMenu。
///
/// Flutter 自绘的菜单无论怎么调参都不是"系统菜单"：字体、材质、强调色、键盘
/// 导航、边缘翻转、深浅色切换都要自己复刻一遍，而且永远差一点。这里直接把
/// 菜单项交给 AppKit，样式完全由系统决定；Dart 侧只负责传标签、回传选中项。
///
/// Dart 在 macOS 上优先走这里；拿不到 channel（widget 测试、其他平台）时回退
/// 到 Flutter 自绘的菜单，见 lib/src/app_menu.dart。
final class NativeMenuBridge: NSObject {
  private static var shared: NativeMenuBridge?

  private var selectedIndex: Int?
  private weak var view: NSView?

  static func register(with controller: FlutterViewController) {
    let bridge = NativeMenuBridge()
    bridge.view = controller.view
    shared = bridge
    let channel = FlutterMethodChannel(
      name: "dbpilot/menu",
      binaryMessenger: controller.engine.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "show" else {
        result(FlutterMethodNotImplemented)
        return
      }
      bridge.show(call: call, result: result)
    }
  }

  private func show(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let rawItems = args["items"] as? [[String: Any]],
          let view = view, let window = view.window else {
      result(nil)
      return
    }
    // 不需要重入保护：popUp 会把平台线程整个占住，菜单没关之前处理不了
    // 第二个 channel 调用。
    selectedIndex = nil

    let menu = NSMenu()
    menu.autoenablesItems = false

    for (index, raw) in rawItems.enumerated() {
      if raw["separator"] as? Bool == true, menu.items.count > 0 {
        menu.addItem(.separator())
      }
      let item = NSMenuItem()
      item.tag = index
      item.target = self
      item.action = #selector(handleSelect(_:))
      item.isEnabled = raw["enabled"] as? Bool ?? true
      let label = raw["label"] as? String ?? ""
      if raw["danger"] as? Bool == true {
        // 危险项用系统红，和 NSMenuItem 的默认文字度量保持一致。
        item.attributedTitle = NSAttributedString(
          string: label,
          attributes: [.foregroundColor: NSColor.systemRed]
        )
      } else {
        item.title = label
      }
      menu.addItem(item)
    }

    // Flutter 给的是逻辑像素、y 轴向下；NSView 坐标是 y 轴向上。
    let x = (args["x"] as? Double) ?? 0
    let y = (args["y"] as? Double) ?? 0
    let pointInView = NSPoint(x: x, y: view.isFlipped ? y : view.bounds.height - y)
    let pointInWindow = view.convert(pointInView, to: nil)
    let pointOnScreen = window.convertPoint(toScreen: pointInWindow)

    // 后台窗口里弹出的菜单点了没反应：先把 app 拉到前台再弹。
    NSApp.activate(ignoringOtherApps: true)

    // popUp 是**阻塞**的：它自己跑事件循环，直到菜单关闭才返回。所以
    //   * 不能在这里 await 任何东西；
    //   * 结果必须在它返回**之后**再交给 Flutter —— 在菜单自己的
    //     tracking 循环里调用 FlutterResult，reply 会被压住/丢弃，表现就是
    //     "菜单弹得出来，点了没反应"。
    menu.popUp(positioning: nil, at: pointOnScreen, in: nil)

    // 走到这里说明菜单已经关闭，选中项是最终值。
    // 取消（Esc / 点外面）时 selectedIndex 仍是 nil：必须回 -1 而不是 nil，
    // 否则 Dart 会当成"平台没有菜单桥"再弹一个自绘菜单。
    let index = selectedIndex ?? -1
    selectedIndex = nil
    result(index)
  }

  @objc private func handleSelect(_ sender: NSMenuItem) {
    selectedIndex = sender.tag
  }
}
