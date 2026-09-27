import AppKit
import Darwin
import SQLite3
import SwiftUI

final class Preferences: ObservableObject {
  static let directory = NSString(
    string: "~/Library/Application Support/com.cardinal.native-prototype"
  ).expandingTildeInPath
  static let index = directory + "/cardinal.db"
  static let file = directory + "/preferences.json"
  static let defaultIgnores = [
    "/Volumes", "~/Library/CloudStorage", "~/Library/Biome", "~/Library/Caches", "~/Library/Logs",
    "~/Library/Metadata", "/Library/Caches", "/System/Library/Caches", "/private/var",
    "/private/tmp",
  ]
  @Published var root = "/"
  @Published var ignores = defaultIgnores.joined(separator: "\n")
  @Published var includes = ""
  @Published var theme = "system"
  @Published var tray = false
  @Published var terminal = "/System/Applications/Utilities/Terminal.app"
  @Published var sortLimit = 20000
  @Published var migration = ""
  var onApply: (() -> Void)?
  var tableColumns: [String: Double] = [:]
  let isolated: Bool
  init(isolated: Bool = false) {
    self.isolated = isolated
    guard !isolated else { return }
    if let data = try? Data(contentsOf: URL(fileURLWithPath: Self.file)),
      let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    {
      apply(values)
    } else {
      importLegacy()
    }
  }
  func apply(_ v: [String: Any]) {
    root = v["root"] as? String ?? root
    ignores = v["ignores"] as? String ?? ignores
    includes = v["includes"] as? String ?? includes
    theme = v["theme"] as? String ?? theme
    tray = v["tray"] as? Bool ?? tray
    terminal = v["terminal"] as? String ?? terminal
    sortLimit = max(1, v["sortLimit"] as? Int ?? sortLimit)
    tableColumns = v["columns"] as? [String: Double] ?? [:]
  }
  func save() throws {
    NSApp.appearance =
      theme == "system" ? nil : NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
    guard !isolated else { return }
    let values: [String: Any] = [
      "root": root, "ignores": ignores, "includes": includes,
      "theme": theme, "tray": tray,
      "terminal": terminal, "sortLimit": max(1, sortLimit), "columns": tableColumns,
    ]
    try FileManager.default.createDirectory(
      atPath: Self.directory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: Self.file), options: .atomic)
    NSApp.appearance =
      theme == "system" ? nil : NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
  }
  func importLegacy(directory sourceDirectory: String? = nil) {
    let directory =
      sourceDirectory
      ?? NSString(string: "~/Library/WebKit/com.cardinal.one/WebsiteData").expandingTildeInPath
    guard
      let walker = FileManager.default.enumerator(
        at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
    else { return }
    var values: [String: String] = [:]
    for case let url as URL in walker
    where url.lastPathComponent == "localstorage.sqlite3" || url.pathExtension == "localstorage" {
      var db: OpaquePointer?
      guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        continue
      }
      var statement: OpaquePointer?
      if sqlite3_prepare_v2(
        db, "SELECT key, value FROM ItemTable WHERE key LIKE 'cardinal.%'", -1, &statement, nil)
        == SQLITE_OK
      {
        while sqlite3_step(statement) == SQLITE_ROW {
          guard let key = sqlite3_column_text(statement, 0),
            let bytes = sqlite3_column_blob(statement, 1)
          else { continue }
          let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))
          if let value = String(data: data, encoding: .utf16LittleEndian) {
            values[String(cString: key)] = value
          }
        }
      }
      sqlite3_finalize(statement)
      sqlite3_close(db)
    }
    func paths(_ key: String) -> String? {
      guard let string = values[key], let data = string.data(using: .utf8),
        let paths = try? JSONDecoder().decode([String].self, from: data)
      else { return nil }
      return paths.joined(separator: "\n")
    }
    root = values["cardinal.watchRoot"] ?? root
    ignores = paths("cardinal.ignorePaths") ?? ignores
    includes = paths("cardinal.includePaths") ?? includes
    theme = values["cardinal.theme"] ?? theme
    tray = values["cardinal.trayIconEnabled"] == "true"
    terminal = values["cardinal.terminalApp"] ?? terminal
    sortLimit = max(1, Int(values["cardinal.sortThreshold"] ?? "") ?? sortLimit)
    migration =
      values.isEmpty
      ? "No existing preferences found."
      : "Imported Cardinal preferences; the original store was not changed."
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
    sortLimit = max(1, sortLimit)
    guard Self.expand(root).hasPrefix("/")
    else { throw messageError("Choose an existing absolute monitor root.") }
    guard (Self.paths(ignores) + Self.paths(includes)).allSatisfy({ $0.hasPrefix("/") }) else {
      throw messageError("Include and ignore paths must be absolute.")
    }
    if terminal.trimmingCharacters(in: .whitespaces).isEmpty {
      terminal = "/System/Applications/Utilities/Terminal.app"
    }
    guard terminal.hasPrefix("/"), terminal.hasSuffix(".app")
    else { throw messageError("Choose an installed terminal application (.app).") }
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
      TextField("Terminal application", text: $prefs.terminal)
      HStack {
        Text("Sorting limit")
        TextField("20000", value: $prefs.sortLimit, formatter: NumberFormatter()).frame(width: 120)
      }
      HStack {
        Button("Import existing Cardinal preferences") {
          prefs.importLegacy()
        }
        Text(prefs.migration).font(.caption).foregroundColor(.secondary)
      }
      Button("Open Full Disk Access settings") {
        FileActions.openPrivacySettings()
      }
      Text(
        "Enable Full Disk Access for Cardinal Native and relaunch."
      ).font(.caption).foregroundColor(.secondary)
      if let error = error { Text(error).foregroundColor(.red) }
      HStack {
        Button("Restore defaults") {
          prefs.theme = "system"
          prefs.tray = false
          prefs.terminal = "/System/Applications/Utilities/Terminal.app"
          prefs.sortLimit = 20000
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
