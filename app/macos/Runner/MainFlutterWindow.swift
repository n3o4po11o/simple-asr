import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // 基于720p设计：默认 1280×720，居中；最小 960×600。
    self.setContentSize(NSSize(width: 1280, height: 720))
    self.contentMinSize = NSSize(width: 960, height: 600)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
