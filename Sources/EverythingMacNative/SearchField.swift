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
    // Reading or assigning the value while an input method composes text (for
    // example Pinyin before a candidate is chosen) commits the letters as typed.
    if !field.isComposing && field.stringValue != text { field.stringValue = text }
    if field.placeholderString != placeholder { field.placeholderString = placeholder }
    if field.accessibilityLabel() != accessibilityLabel {
      field.setAccessibilityLabel(accessibilityLabel)
    }
    if field.isEnabled != context.environment.isEnabled {
      field.isEnabled = context.environment.isEnabled
    }
  }
}

extension NSTextField {
  /// An input method is composing uncommitted (marked) text in the field editor.
  var isComposing: Bool { (currentEditor() as? NSTextView)?.hasMarkedText() == true }
}

extension SearchField {
  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var parent: SearchField
    init(_ parent: SearchField) { self.parent = parent }
    func controlTextDidChange(_ notification: Notification) {
      // Uncommitted input-method text is not searched; committing or cancelling
      // the composition sends another change with the final text.
      guard let field = notification.object as? NSSearchField, !field.isComposing else { return }
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
