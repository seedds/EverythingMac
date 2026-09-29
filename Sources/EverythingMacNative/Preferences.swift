import AppKit
import CNative
import Darwin
import SwiftUI

final class Preferences: ObservableObject {
  static let directory = NSString(
    string: "~/Library/Application Support/com.everything.mac"
  ).expandingTildeInPath
  static let index = directory + "/" + IndexLocation.filename
  static var snapshotIndex: String { IndexLocation.existingIndex(in: directory) }
  static let file = directory + "/preferences.json"
  static let sortColumns = [
    "Name": "filename", "Path": "fullPath", "Size": "size", "Modified": "mtime", "Created": "ctime",
  ]
  @Published var root = "/"
  @Published var ignores = ""
  @Published var includes = ""
  @Published var patterns = ""
  @Published var shortcut: ActivationShortcut? = .standard
  var patternLines: [String] { patterns.isEmpty ? [] : patterns.components(separatedBy: "\n") }
  var applyShortcut: ((ActivationShortcut?) throws -> Void)?
  @Published var theme = "system"
  @Published var tray = false
  @Published var terminal = ""
  var terminalApplication: String {
    let path = terminal.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? "/System/Applications/Utilities/Terminal.app" : path
  }
  var sortKey = ""
  var sortAscending = true
  var onApply: (() -> Void)?
  var tableColumns: [String: Double] = [:]
  let isolated: Bool
  let storageURL: URL
  init(isolated: Bool = false, fileURL: URL? = nil) {
    self.isolated = isolated
    storageURL = fileURL ?? URL(fileURLWithPath: Self.file)
    guard !isolated else { return }
    if let data = try? Data(contentsOf: storageURL),
      let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      apply(values)
    }
  }
  func apply(_ v: [String: Any]) {
    root = v["root"] as? String ?? root
    ignores = v["ignores"] as? String ?? ignores
    includes = v["includes"] as? String ?? includes
    patterns = v["patterns"] as? String ?? patterns
    if let enabled = v["shortcutEnabled"] as? Bool {
      if enabled, let key = v["shortcutKey"] as? NSNumber,
        let modifiers = v["shortcutModifiers"] as? NSNumber
      {
        let candidate = ActivationShortcut(key: key.uint32Value, modifiers: modifiers.uint32Value)
        shortcut = candidate.isValid ? candidate : .standard
      } else {
        shortcut = enabled ? .standard : nil
      }
    }
    theme = v["theme"] as? String ?? theme
    tray = v["tray"] as? Bool ?? tray
    terminal = v["terminal"] as? String ?? terminal
    let savedSort = v["sortKey"] as? String ?? ""
    sortKey = Self.sortColumns.values.contains(savedSort) ? savedSort : ""
    sortAscending = v["sortAscending"] as? Bool ?? true
    tableColumns = v["columns"] as? [String: Double] ?? [:]
  }
  var values: [String: Any] {
    [
      "root": root, "ignores": ignores, "includes": includes,
      "theme": theme, "tray": tray, "patterns": patterns,
      "shortcutEnabled": shortcut != nil, "shortcutKey": shortcut?.key ?? 0,
      "shortcutModifiers": shortcut?.modifiers ?? 0,
      "terminal": terminal, "columns": tableColumns,
      "sortKey": sortKey, "sortAscending": sortAscending,
    ]
  }
  func commit(_ draft: Preferences) throws {
    try draft.validate()
    let previous = values
    try applyShortcut?(draft.shortcut)
    apply(draft.values)
    do { try save() } catch {
      apply(previous)
      try? applyShortcut?(shortcut)
      throw error
    }
    onApply?()
  }
  func save() throws {
    NSApp.appearance =
      theme == "system" ? nil : NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
    guard !isolated else { return }
    try FileManager.default.createDirectory(
      at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
      .write(to: storageURL, options: .atomic)
    NSApp.appearance =
      theme == "system" ? nil : NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
  }
  func restoreDefaults() {
    root = "/"
    ignores = ""
    includes = ""
    patterns = ""
    shortcut = .standard
    theme = "system"
    tray = false
    terminal = ""
  }
  static func expand(_ value: String) -> String {
    NSString(string: value.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
  }
  // Pure lexical normalization. Filesystem/symlink resolution belongs to the
  // cancellable Rust scan worker, never the UI thread.
  static func normalized(_ value: String) -> String {
    let path = expand(value)
    guard path.hasPrefix("/") else { return path }
    var parts: [Substring] = []
    for part in path.split(separator: "/") {
      if part == ".." {
        if !parts.isEmpty { parts.removeLast() }
      } else if part != "." {
        parts.append(part)
      }
    }
    return "/" + parts.joined(separator: "/")
  }
  static func paths(_ value: String) -> [String] {
    value.split(separator: "\n").map { normalized(String($0)) }.filter { !$0.isEmpty }
  }
  func validate() throws {
    _ = try jsonString(patternLines).withCString { try decode(cn_validate_exclusions($0)) }
    if let shortcut = shortcut, !shortcut.isValid {
      throw messageError("Use Command, Control, or Option with a non-modifier key.")
    }
    guard Self.expand(root).hasPrefix("/")
    else { throw messageError("Choose an existing absolute monitor root.") }
    guard (Self.paths(ignores) + Self.paths(includes)).allSatisfy({ $0.hasPrefix("/") }) else {
      throw messageError("Include and ignore paths must be absolute.")
    }
    let terminalPath = terminal.trimmingCharacters(in: .whitespacesAndNewlines)
    guard terminalPath.isEmpty || (terminalPath.hasPrefix("/") && terminalPath.hasSuffix(".app"))
    else { throw messageError("Choose an installed terminal application (.app).") }
    terminal = terminalPath
  }
}
func messageError(_ message: String) -> NSError {
  NSError(domain: "EverythingMacNative", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

struct PreferencesView: View {
  @ObservedObject var prefs: Preferences
  @ObservedObject var model: Model
  @StateObject private var draft: Preferences
  init(prefs: Preferences, model: Model) {
    self.prefs = prefs
    self.model = model
    let copy = Preferences(isolated: true)
    copy.apply(prefs.values)
    _draft = StateObject(wrappedValue: copy)
  }
  @Environment(\.presentationMode) var presentation
  @State var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Preferences").font(.title2.bold())
      TextField("Monitor root path", text: $draft.root)
      HStack {
        VStack(alignment: .leading) {
          Text("Ignore paths")
          TextEditor(text: $draft.ignores).frame(height: 110)
        }
        VStack(alignment: .leading) {
          Text("Include paths")
          TextEditor(text: $draft.includes).frame(height: 110)
        }
      }
      Text(
        "One absolute path per line; includes override ignored ancestors."
      ).font(.caption).foregroundColor(.secondary)
      Text("Exclude patterns")
      TextEditor(text: $draft.patterns).frame(height: 65)
        .accessibilityLabel("Exclude patterns")
      HStack {
        Text("Names or globs, one per line. Patterns also apply inside included folders.").font(
          .caption)
        Button("Add node_modules exclusion") {
          if !draft.patternLines.contains("node_modules") {
            draft.patterns +=
              (draft.patterns.isEmpty || draft.patterns.hasSuffix("\n") ? "" : "\n")
              + "node_modules"
          }
        }
      }
      ShortcutRecorder(shortcut: $draft.shortcut, recording: $model.recordingShortcut)
      Picker("Appearance", selection: $draft.theme) {
        ForEach(["system", "light", "dark"], id: \.self) {
          Text($0.capitalized).tag($0)
        }
      }
      Toggle("Show menu bar icon", isOn: $draft.tray)
      VStack(alignment: .leading, spacing: 4) {
        Text("Terminal app (F9)")
        TextField("Path to a terminal application (.app)", text: $draft.terminal)
          .accessibilityLabel("Terminal app for F9")
        Text(
          "F9 opens the selected folder or a file’s parent folder. Leave empty to use macOS Terminal."
        )
        .font(.caption).foregroundColor(.secondary)
      }
      Button("Open Full Disk Access settings") {
        FileActions.openPrivacySettings()
      }
      Text(
        "Enable Full Disk Access for EverythingMac and relaunch."
      ).font(.caption).foregroundColor(.secondary)
      if model.scanning {
        Text("Finish or cancel the current scan before saving preferences.").font(.caption)
          .foregroundColor(.secondary)
      }
      if let error = error { Text(error).foregroundColor(.red) }
      HStack {
        Button("Restore defaults") {
          draft.restoreDefaults()
        }
        Spacer()
        Button("Close") { presentation.wrappedValue.dismiss() }
        Button(
          (draft.patternLines != model.loadedPatterns || draft.root != prefs.root
            || draft.ignores != prefs.ignores || draft.includes != prefs.includes)
            && !model.snapshotOnly ? "Save and Rebuild" : "Save"
        ) {
          do {
            try model.savePreferences(draft)
            presentation.wrappedValue.dismiss()
          } catch { self.error = error.localizedDescription }
        }.keyboardShortcut(.defaultAction).disabled(model.scanning)
      }
    }.padding(20).frame(width: 650).background(Color(nsColor: .windowBackgroundColor))
  }
}
