import AppKit
import SwiftUI

// Measure the actual status component without loading an index or preferences.
@main struct StatusLayoutCheck {
  @MainActor static func main() {
    _ = NSApplication.shared
    var widths: [CGFloat] = []
    for label in LifecycleStatus.labels {
      for busy in [false, true] {
        let view = NSHostingView(rootView:
          LifecycleStatus(busy: busy, hasError: false, label: label)
            .font(.system(size: 11)).lineLimit(1))
        widths.append(view.fittingSize.width)
      }
    }
    let shift = widths.max()! - widths.min()!
    print("Horizontal shift \(shift) pt; widths \(widths)")
    guard shift <= 0.5 else {
      fputs("FAIL: status changes resize the layout\n", stderr)
      exit(1)
    }
    print("PASS: stable English status layout in all six states")
  }
}
