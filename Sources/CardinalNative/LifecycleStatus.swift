import SwiftUI

struct LifecycleStatus: View {
  let busy: Bool
  let hasError: Bool
  let label: String
  let labels: [String]

  var body: some View {
    HStack(spacing: 5) {
      ZStack {
        if busy {
          ProgressView().controlSize(.small).scaleEffect(0.65).frame(width: 12, height: 12)
        } else {
          Circle().fill(hasError ? Color.orange : Color.green).frame(width: 6, height: 6)
        }
      }.frame(width: 12, height: 12)
      // Reserve the widest translated state without exposing hidden labels to
      // accessibility or truncating languages with longer status descriptions.
      ZStack(alignment: .leading) {
        ForEach(labels.indices, id: \.self) { index in
          Text(labels[index]).hidden().accessibilityHidden(true)
        }
        Text(label)
      }.fixedSize()
    }
  }
}
