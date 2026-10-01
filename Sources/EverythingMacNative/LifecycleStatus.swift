import SwiftUI

struct LifecycleStatus: View {
  let busy: Bool
  let hasError: Bool
  var paused = false
  let label: String
  static let labels = ["Ready", "Initializing", "Updating", "Paused", "No index", "Rescan needed"]

  var body: some View {
    HStack(spacing: 5) {
      ZStack {
        if busy {
          ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 12, height: 12)
        } else {
          Circle().fill(hasError ? Color.orange : paused ? Color.secondary : Color.green)
            .frame(width: 6, height: 6)
        }
      }.frame(width: 12, height: 12)
      // Reserve the widest state without exposing hidden labels to
      // accessibility while keeping state changes from shifting neighboring controls.
      ZStack(alignment: .leading) {
        ForEach(Self.labels.indices, id: \.self) { index in
          Text(Self.labels[index]).hidden().accessibilityHidden(true)
        }
        Text(label)
      }.fixedSize()
    }
  }
}

/// Files/Events switcher whose width never follows the live counts.
struct ViewTabs: View {
  @Binding var selection: String
  let files: Int
  let events: Int
  /// Counts up to this value fit without truncation.
  static let widestCount = 999_999_999
  /// A native segmented control sizes segments to their titles, so reserve room for
  /// the widest count in both segments and keep neighboring controls in place.
  static let width: CGFloat = {
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: .small))
    let widest = ["Files", "Events"].map {
      ("\($0) \(widestCount.formatted())" as NSString).size(withAttributes: [.font: font]).width
    }.max()!
    // Per-segment title insets plus the control's borders.
    return ceil(widest + 20) * 2 + 4
  }()

  var body: some View {
    Picker("View", selection: $selection) {
      Text("Files \(files.formatted())").tag("files")
      Text("Events \(events.formatted())").tag("events")
    }
    .pickerStyle(.segmented).labelsHidden()
    .frame(width: Self.width)
  }
}
