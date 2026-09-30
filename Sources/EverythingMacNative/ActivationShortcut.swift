import AppKit
import Carbon
import SwiftUI

struct ActivationShortcut: Codable, Equatable {
  let key: UInt32
  let modifiers: UInt32
  static let standard = ActivationShortcut(
    key: UInt32(kVK_Space), modifiers: UInt32(cmdKey | shiftKey))
  var isValid: Bool {
    key < 128 && ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(key)
      && modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
      && modifiers & ~UInt32(cmdKey | controlKey | optionKey | shiftKey) == 0
  }
  static func from(_ event: NSEvent) -> ActivationShortcut {
    let flags = event.modifierFlags
    var modifiers: UInt32 = 0
    if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
    if flags.contains(.control) { modifiers |= UInt32(controlKey) }
    if flags.contains(.option) { modifiers |= UInt32(optionKey) }
    if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
    return ActivationShortcut(key: UInt32(event.keyCode), modifiers: modifiers)
  }
  var label: String {
    var text = ""
    for (flag, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
      if modifiers & UInt32(flag) != 0 { text += symbol }
    }
    let special: [UInt32: String] = [
      49: "Space", 36: "Return", 48: "Tab", 51: "Delete", 53: "Escape", 123: "←", 124: "→",
      125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
    ]
    if let name = special[key] { return text + name }
    let functionKeys: [UInt32] = [
      122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90,
    ]
    if let index = functionKeys.firstIndex(of: key) { return text + "F\(index + 1)" }
    // Translate using the active keyboard layout rather than assuming US key positions.
    if let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
      let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
    {
      let data = unsafeBitCast(raw, to: CFData.self)
      let layout = UnsafeRawPointer(CFDataGetBytePtr(data)).assumingMemoryBound(
        to: UCKeyboardLayout.self)
      var dead: UInt32 = 0
      var count = 0
      var chars = [UniChar](repeating: 0, count: 8)
      if UCKeyTranslate(
        layout, UInt16(key), UInt16(kUCKeyActionDisplay), 0,
        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead,
        chars.count, &count, &chars) == noErr, count > 0
      {
        return text + String(utf16CodeUnits: chars, count: count).uppercased()
      }
    }
    return text + "Key \(key)"
  }
}

final class ActivationShortcutManager {
  typealias Register = (ActivationShortcut) throws -> EventHotKeyRef
  private var reference: EventHotKeyRef?
  private(set) var current: ActivationShortcut?
  private let register: Register
  private let unregister: (EventHotKeyRef) -> Void
  init(
    register: @escaping Register = { shortcut in
      var ref: EventHotKeyRef?
      let status = RegisterEventHotKey(
        shortcut.key, shortcut.modifiers,
        EventHotKeyID(signature: 0x4341_5244, id: 1), GetApplicationEventTarget(), 0, &ref)
      guard status == noErr, let ref = ref else {
        throw messageError(
          "\(shortcut.label) could not be registered (\(status)). Choose another shortcut in Preferences."
        )
      }
      return ref
    }, unregister: @escaping (EventHotKeyRef) -> Void = { UnregisterEventHotKey($0) }
  ) {
    self.register = register
    self.unregister = unregister
  }
  func apply(_ shortcut: ActivationShortcut?) throws {
    if shortcut == current { return }
    if let shortcut = shortcut, !shortcut.isValid {
      throw messageError("Invalid activation shortcut")
    }
    let next = try shortcut.map(register)
    if let reference = reference { unregister(reference) }
    reference = next
    current = shortcut
  }
  deinit { if let reference = reference { unregister(reference) } }
}

struct ShortcutRecorder: View {
  @Binding var shortcut: ActivationShortcut?
  @Binding var recording: Bool
  @State private var monitor: Any?
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("Show / hide EverythingMac")
        Button(recording ? "Press shortcut… (Esc cancels)" : shortcut?.label ?? "Disabled") {
          start()
        }
        .accessibilityLabel("Record global activation shortcut")
        Button("Disable") {
          stop()
          shortcut = nil
        }
        Button("Restore Default") {
          stop()
          shortcut = .standard
        }
      }
      if let error = error { Text(error).font(.caption).foregroundColor(.red) }
    }.onDisappear { stop() }
  }
  private func start() {
    stop()
    recording = true
    error = nil
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      // Closing Settings ends recording, and keys typed in other windows are theirs.
      guard recording else {
        stop()
        return event
      }
      guard event.window?.identifier?.rawValue == "EverythingMacSettings" else { return event }
      if event.keyCode == 53 {
        stop()
        return nil
      }
      let value = ActivationShortcut.from(event)
      if value.isValid {
        shortcut = value
        stop()
      } else {
        error = "Include Command, Control, or Option."
      }
      return nil
    }
  }
  private func stop() {
    if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    recording = false
  }
}
