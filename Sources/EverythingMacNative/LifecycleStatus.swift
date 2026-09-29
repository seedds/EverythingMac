import SwiftUI

struct LifecycleStatus: View {
  let busy: Bool
  let hasError: Bool
  let label: String
  static let labels = ["Ready", "Initializing", "Updating"]

  var body: some View {
    HStack(spacing: 5) {
      ZStack {
        if busy {
          ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 12, height: 12)
        } else {
          Circle().fill(hasError ? Color.orange : Color.green).frame(width: 6, height: 6)
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
