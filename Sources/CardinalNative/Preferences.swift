import AppKit
import Darwin
import SwiftUI

final class Preferences: ObservableObject {
  static let directory = NSString(
    string: "~/Library/Application Support/com.cardinal.native-prototype"
  ).expandingTildeInPath
  static let index = directory + "/cardinal.db"
  static let file = directory + "/preferences.json"
  static let sortColumns = [
    "Name": "filename", "Path": "fullPath", "Size": "size", "Modified": "mtime", "Created": "ctime",
  ]
  @Published var root = "/"
  @Published var ignores = ""
  @Published var includes = ""
  @Published var theme = "system"
  @Published var tray = false
  @Published var terminal = ""
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
    theme = v["theme"] as? String ?? theme
    tray = v["tray"] as? Bool ?? tray
    terminal = v["terminal"] as? String ?? terminal
    let savedSort = v["sortKey"] as? String ?? ""
    sortKey = Self.sortColumns.values.contains(savedSort) ? savedSort : ""
    sortAscending = v["sortAscending"] as? Bool ?? true
    tableColumns = v["columns"] as? [String: Double] ?? [:]
  }
  func save() throws {
    NSApp.appearance =
      theme == "system" ? nil : NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
    guard !isolated else { return }
    let values: [String: Any] = [
      "root": root, "ignores": ignores, "includes": includes,
      "theme": theme, "tray": tray,
      "terminal": terminal, "columns": tableColumns,
      "sortKey": sortKey, "sortAscending": sortAscending,
    ]
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
  NSError(domain: "CardinalNative", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

struct PreferencesView: View {
  @ObservedObject var prefs: Preferences
  @ObservedObject var model: Model
  @Environment(\.presentationMode) var presentation
  @State var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Preferences").font(.title2.bold())
      TextField("Monitor root path", text: $prefs.root)
      HStack {
        VStack(alignment: .leading) {
          Text("Ignore paths")
          TextEditor(text: $prefs.ignores).frame(height: 110)
        }
        VStack(alignment: .leading) {
          Text("Include paths")
          TextEditor(text: $prefs.includes).frame(height: 110)
        }
      }
      Text(
        "One absolute path per line; includes override ignored ancestors."
      ).font(.caption).foregroundColor(.secondary)
      Picker("Appearance", selection: $prefs.theme) {
        ForEach(["system", "light", "dark"], id: \.self) {
          Text($0.capitalized).tag($0)
        }
      }
      Toggle("Show menu bar icon", isOn: $prefs.tray)
      VStack(alignment: .leading, spacing: 4) {
        Text("Terminal app (F9)")
        TextField("Path to a terminal application (.app)", text: $prefs.terminal)
          .accessibilityLabel("Terminal app for F9")
        Text("Choose a terminal app to enable F9 for the selected folder or a file’s parent folder.")
          .font(.caption).foregroundColor(.secondary)
      }
      Button("Open Full Disk Access settings") {
        FileActions.openPrivacySettings()
      }
      Text(
        "Enable Full Disk Access for EverythingMac and relaunch."
      ).font(.caption).foregroundColor(.secondary)
      if let error = error { Text(error).foregroundColor(.red) }
      HStack {
        Button("Restore defaults") {
          prefs.restoreDefaults()
        }
        Spacer()
        Button("Close") { presentation.wrappedValue.dismiss() }
        Button("Save") {
          do {
            try prefs.validate()
            try prefs.save()
            prefs.onApply?()
            model.applyPreferences()
            presentation.wrappedValue.dismiss()
          } catch { self.error = error.localizedDescription }
        }.keyboardShortcut(.defaultAction)
      }
    }.padding(20).frame(width: 650)
  }
}
