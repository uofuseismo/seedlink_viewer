import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Taken from the bundle rather than written out again, so the title
    // follows PRODUCT_NAME in AppInfo.xcconfig instead of being a second place
    // to change.  The xib ships a placeholder.
    if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName")
      as? String
    {
      self.title = name
    }

    super.awakeFromNib()
  }
}
