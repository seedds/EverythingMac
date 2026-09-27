import AppKit
import SwiftUI

// Compile with the real LifecycleStatus view, then measure its AppKit-hosted
// layout across all bundled translations. No index or app preferences are used.
@main struct StatusLayoutCheck {
  @MainActor static func main() throws {
    _ = NSApplication.shared
    let resources = URL(fileURLWithPath: CommandLine.arguments[1])
    let files = try FileManager.default.contentsOfDirectory(
      at: resources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    var failures: [String] = []
    for file in files.sorted(by: { $0.path < $1.path }) {
      let data = try Data(contentsOf: file)
      let values = try JSONSerialization.jsonObject(with: data) as! [String: Any]
      let status = values["statusBar"] as! [String: Any]
      let lifecycle = status["lifecycle"] as! [String: String]
      let labels = ["Ready", "Initializing", "Updating"].map { lifecycle[$0]! }
      var widths: [CGFloat] = []
      for label in labels {
        for busy in [false, true] {
          let view = NSHostingView(rootView:
            LifecycleStatus(busy: busy, hasError: false, label: label, labels: labels)
              .font(.system(size: 11)).lineLimit(1))
          widths.append(view.fittingSize.width)
        }
      }
      let shift = widths.max()! - widths.min()!
      print("\(file.lastPathComponent): horizontal shift \(shift) pt; widths \(widths)")
      if shift > 0.5 { failures.append(file.lastPathComponent) }
    }
    guard failures.isEmpty else {
      fputs("FAIL: status changes resize the layout in \(failures.count) languages\n", stderr)
      exit(1)
    }
    print("PASS: stable status layout in \(files.count) languages")
  }
}
