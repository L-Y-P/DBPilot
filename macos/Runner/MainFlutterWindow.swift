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

    super.awakeFromNib()
  }
}
