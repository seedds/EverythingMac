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
  @Published var language = "en-US"
  @Published var tray = false
  @Published var thumbnails = true
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
    Translation.load(language)
  }
  func apply(_ v: [String: Any]) {
    root = v["root"] as? String ?? root
    ignores = v["ignores"] as? String ?? ignores
    includes = v["includes"] as? String ?? includes
    theme = v["theme"] as? String ?? theme
    language = v["language"] as? String ?? language
    tray = v["tray"] as? Bool ?? tray
    thumbnails = v["thumbnails"] as? Bool ?? thumbnails
    terminal = v["terminal"] as? String ?? terminal
    sortLimit = max(1, v["sortLimit"] as? Int ?? sortLimit)
    tableColumns = v["columns"] as? [String: Double] ?? [:]
  }
  func save() throws {
    Translation.load(language)
    NSApp.appearance =
      theme == "system" ? nil : NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
    guard !isolated else { return }
    let values: [String: Any] = [
      "root": root, "ignores": ignores, "includes": includes,
      "theme": theme, "language": language, "tray": tray, "thumbnails": thumbnails,
      "terminal": terminal, "sortLimit": max(1, sortLimit), "columns": tableColumns,
    ]
    try FileManager.default.createDirectory(
      atPath: Self.directory, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: Self.file), options: .atomic)
    Translation.load(language)
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
    language = values["cardinal.language"] ?? language
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

enum Translation {
  static let languages = [
    "en-US", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "fr-FR", "es-ES", "pt-BR", "de-DE", "it-IT",
    "ru-RU", "uk-UA", "ar-SA", "hi-IN", "tr-TR",
  ]
  static var strings: [String: Any] = [:]
  static func load(_ code: String) {
    let url = Bundle.main.resourceURL?.appendingPathComponent("Translations/\(code).json")
    strings =
      url.flatMap { try? Data(contentsOf: $0) }.flatMap {
        try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
      } ?? [:]
    if let nativeURL = Bundle.main.resourceURL?.appendingPathComponent("native-translations.json"),
      let data = try? Data(contentsOf: nativeURL),
      let locales = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
    {
      strings["native"] = locales[code] ?? locales["en-US"]
    }
  }
  static func text(_ key: String, _ fallback: String) -> String {
    var current: Any = strings
    for part in key.split(separator: ".") {
      guard let value = (current as? [String: Any])?[String(part)] else { return fallback }
      current = value
    }
    return current as? String ?? fallback
  }
}
func tr(_ key: String, _ fallback: String) -> String { Translation.text(key, fallback) }

struct PreferencesView: View {
  @ObservedObject var prefs: Preferences
  @ObservedObject var model: Model
  @Environment(\.presentationMode) var presentation
  @State var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(tr("preferences.title", "Preferences")).font(.title2.bold())
      TextField(tr("watchRoot.label", "Monitor root path"), text: $prefs.root)
      HStack {
        VStack(alignment: .leading) {
          Text(tr("ignorePaths.label", "Ignore paths"))
          TextEditor(text: $prefs.ignores).frame(height: 110)
        }
        VStack(alignment: .leading) {
          Text(tr("includePaths.label", "Include paths"))
          TextEditor(text: $prefs.includes).frame(height: 110)
        }
      }
      Text(
        tr("includePaths.help", "One absolute path per line; includes override ignored ancestors.")
      ).font(.caption).foregroundColor(.secondary)
      Picker(tr("preferences.appearance", "Appearance"), selection: $prefs.theme) {
        ForEach(["system", "light", "dark"], id: \.self) {
          Text(tr("theme.options.\($0)", $0.capitalized)).tag($0)
        }
      }
      Picker(tr("preferences.language", "Language"), selection: $prefs.language) {
        ForEach(Translation.languages, id: \.self) {
          Text(Locale(identifier: $0).localizedString(forIdentifier: $0) ?? $0).tag($0)
        }
      }
      Toggle(tr("preferences.trayIcon.label", "Show menu bar icon"), isOn: $prefs.tray)
      Toggle(tr("native.thumbnails", "Generate file thumbnails"), isOn: $prefs.thumbnails)
      TextField(tr("preferences.terminalApp.label", "Terminal application"), text: $prefs.terminal)
      HStack {
        Text(tr("preferences.sortingLimit.label", "Sorting limit"))
        TextField("20000", value: $prefs.sortLimit, formatter: NumberFormatter()).frame(width: 120)
      }
      HStack {
        Button(tr("native.importPrefs", "Import existing Cardinal preferences")) {
          prefs.importLegacy()
        }
        Text(prefs.migration).font(.caption).foregroundColor(.secondary)
      }
      Button(tr("app.fullDiskAccess.openSettings", "Open Full Disk Access settings")) {
        FileActions.openPrivacySettings()
      }
      Text(
        tr(
          "app.fullDiskAccess.description",
          "Enable Full Disk Access for Cardinal Native and relaunch.")
      ).font(.caption).foregroundColor(.secondary)
      if let error = error { Text(error).foregroundColor(.red) }
      HStack {
        Button(tr("preferences.reset", "Restore defaults")) {
          prefs.theme = "system"
          prefs.language = "en-US"
          prefs.tray = false
          prefs.terminal = "/System/Applications/Utilities/Terminal.app"
          prefs.sortLimit = 20000
          prefs.thumbnails = true
        }
        Spacer()
        Button(tr("preferences.close", "Close")) { presentation.wrappedValue.dismiss() }
        Button(tr("preferences.save", "Save")) {
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
