import Cocoa
import FlutterMacOS
import Darwin

class MainFlutterWindow: NSWindow {
  private var qemuPid: pid_t?
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    let files = FlutterMethodChannel(name: "ae5i/files",
                                    binaryMessenger: flutterViewController.engine.binaryMessenger)
    files.setMethodCallHandler { call, result in
      if call.method == "trackQemu" {
        self.qemuPid = (call.arguments as? NSNumber).map { pid_t($0.int32Value) }
        result(nil)
        return
      }
      guard call.method == "saveLog",
            let args = call.arguments as? [String: String],
            let text = args["text"] else {
        result(FlutterMethodNotImplemented)
        return
      }
      let panel = NSSavePanel()
      panel.title = "导出仿真器日志"
      panel.nameFieldStringValue = args["name"] ?? "ae5i-emulator.log"
      panel.canCreateDirectories = true
      panel.beginSheetModal(for: self) { response in
        guard response == .OK, let url = panel.url else { result(nil); return }
        do {
          try text.write(to: url, atomically: true, encoding: .utf8)
          NSWorkspace.shared.activateFileViewerSelecting([url])
          result(url.path)
        } catch {
          result(FlutterError(code: "SAVE_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }

    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                          object: nil, queue: .main) { [weak self] _ in
      // Only terminate this window's recorded child; never other QEMU instances.
      if let child = self?.qemuPid, child > 1 { kill(child, SIGTERM) }
    }

    // The emulator UI needs room for the 1024x600 screen plus the QEMU/log column and
    // the two handlebar key groups; the storyboard default is too small.
    let targetSize = NSSize(width: 1560, height: 980)
    if let screen = NSScreen.main {
      let visible = screen.visibleFrame
      let w = min(targetSize.width, visible.width - 40)
      let h = min(targetSize.height, visible.height - 40)
      let origin = NSPoint(
        x: visible.midX - w / 2,
        y: visible.midY - h / 2)
      self.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
    } else {
      self.setFrame(NSRect(origin: self.frame.origin, size: targetSize), display: true)
    }
    self.minSize = NSSize(width: 1100, height: 720)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
