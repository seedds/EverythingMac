import AppKit
import SwiftUI

/// AppKit search field: native search icon, clear button, and focus ring.
/// Keyboard shortcuts stay in AppDelegate's key monitor, which sees the field
/// editor (an NSTextView) as first responder exactly as with a SwiftUI TextField.
struct SearchField: NSViewRepresentable {
  @Binding var text: String
  var placeholder: String
  var symbol = "magnifyingglass"
  var accessibilityLabel: String
  var onSubmit: () -> Void = {}
  /// Receives a closure that focuses this field.
  var focus: (((@escaping () -> Void)) -> Void)?

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.delegate = context.coordinator
    field.target = context.coordinator
    field.action = #selector(Coordinator.submit(_:))
    // Submit on Return only; searching as you type is driven by the binding.
    field.sendsSearchStringImmediately = false
    field.sendsWholeSearchString = true
    field.font = .systemFont(ofSize: 13)
    field.controlSize = .large
    field.lineBreakMode = .byTruncatingTail
    if let cell = field.cell as? NSSearchFieldCell {
      cell.searchButtonCell?.image = NSImage(
        systemSymbolName: symbol, accessibilityDescription: nil)
      cell.searchButtonCell?.imageScaling = .scaleProportionallyDown
    }
    focus?({ [weak field] in field?.window?.makeFirstResponder(field) })
    return field
  }

  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.parent = self
    if field.stringValue != text { field.stringValue = text }
    field.placeholderString = placeholder
    field.setAccessibilityLabel(accessibilityLabel)
    field.isEnabled = context.environment.isEnabled
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: SearchField
    init(_ parent: SearchField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      parent.text = field.stringValue
    }
    @objc func submit(_ sender: NSSearchField) {
      parent.text = sender.stringValue
      // The clear button also sends the action; only Return submits.
      guard NSApp.currentEvent?.type == .keyDown else { return }
      parent.onSubmit()
    }
  }
}
