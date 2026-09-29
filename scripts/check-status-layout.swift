import AppKit
import SwiftUI

// Measure the actual status components without loading an index or preferences.
@main struct StatusLayoutCheck {
  @MainActor static func main() {
    _ = NSApplication.shared
    var widths: [CGFloat] = []
    for label in LifecycleStatus.labels {
      for busy in [false, true] {
        let view = NSHostingView(rootView:
          LifecycleStatus(busy: busy, hasError: false, paused: label == "Paused", label: label)
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
    print("PASS: stable English status layout in all \(widths.count) states")

    // Growing counts must neither resize the Files/Events control nor truncate it.
    var tabWidths: [CGFloat] = []
    for count in [0, 7, 4_478_475, ViewTabs.widestCount] {
      for tab in ["files", "events"] {
        let view = NSHostingView(rootView:
          ViewTabs(selection: .constant(tab), files: count, events: count)
            .controlSize(.small).font(.system(size: 11)))
        tabWidths.append(view.fittingSize.width)
      }
    }
    // The natural width of the same control at the widest count must fit the reservation.
    let widest = ViewTabs.widestCount.formatted()
    let natural = NSHostingView(rootView:
      Picker("View", selection: .constant("files")) {
        Text("Files \(widest)").tag("files")
        Text("Events \(widest)").tag("events")
      }
      .pickerStyle(.segmented).labelsHidden().fixedSize()
      .controlSize(.small).font(.system(size: 11))
    ).fittingSize.width
    guard natural <= ViewTabs.width + 0.5 else {
      fputs("FAIL: \(widest) needs \(natural) pt but only \(ViewTabs.width) pt is reserved\n", stderr)
      exit(1)
    }
    let tabShift = tabWidths.max()! - tabWidths.min()!
    print("Files/Events shift \(tabShift) pt; widths \(Set(tabWidths).sorted())")
    guard tabShift <= 0.5 else {
      fputs("FAIL: count changes resize the Files/Events control\n", stderr)
      exit(1)
    }
    print("PASS: stable Files/Events width from 0 to \(ViewTabs.widestCount.formatted())")
  }
}
