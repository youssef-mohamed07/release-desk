import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // The macOS build is for development; Windows and Linux are the targets.
    self.title = "Release Desk"
    self.minSize = NSSize(width: 1000, height: 680)
    self.setContentSize(NSSize(width: 1380, height: 880))
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
