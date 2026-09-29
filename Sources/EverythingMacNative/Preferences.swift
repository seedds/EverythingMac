import AppKit
import CNative
import Darwin
import SwiftUI
import UniformTypeIdentifiers

@Observable final class Preferences {
  static let directory = NSString(
    string: "~/Library/Application Support/com.everything.mac"
  ).expandingTildeInPath
  static let index = directory + "/" + IndexLocation.filename
  static var snapshotIndex: String { IndexLocation.existingIndex(in: directory) }
  static let file = directory + "/preferences.json"
  static let sortColumns = [
    "Name": "filename", "Path": "fullPath", "Size": "size", "Modified": "mtime", "Created": "ctime",
  ]
  var root = "/"
  var ignores = ""
  var includes = ""
  var patterns = ""
  var shortcut: ActivationShortcut? = .standard
  var patternLines: [String] { patterns.isEmpty ? [] : patterns.components(separatedBy: "\n") }
  @ObservationIgnored var applyShortcut: ((ActivationShortcut?) throws -> Void)?
  var theme = "system"
  var tray = false
  var terminal = ""
  /// Search-as-you-type delay in milliseconds.
  var debounce = 100
  var terminalApplication: String {
    let path = terminal.trimmingCharacters(in: .whitespacesAndNewlines)
    return path.isEmpty ? "/System/Applications/Utilities/Terminal.app" : path
  }
  @ObservationIgnored var sortKey = ""
  @ObservationIgnored var sortAscending = true
  @ObservationIgnored var tableColumns: [String: Double] = [:]
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
    if let delay = v["debounce"] as? Int, [0, 100, 300].contains(delay) { debounce = delay }
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
      "terminal": terminal, "debounce": debounce, "columns": tableColumns,
      "sortKey": sortKey, "sortAscending": sortAscending,
    ]
  }
  /// Commits the index scope from a Settings draft. Other settings apply immediately
  /// through `update`, so the draft never overwrites them.
  func commit(_ draft: Preferences) throws {
    try draft.validate()
    let previous = values
    root = draft.root
    ignores = draft.ignores
    includes = draft.includes
    patterns = draft.patterns
    do { try save() } catch {
      apply(previous)
      throw error
    }
  }
  /// Applies a General setting immediately, restoring the previous values if saving fails.
  func update(_ change: (Preferences) -> Void) throws {
    let previous = values
    change(self)
    do { try save() } catch {
      apply(previous)
      throw error
    }
  }
  func save() throws {
    NSApp.appearance =
      theme == "system" ? nil : NSAppearance(named: theme == "dark" ? .darkAqua : .aqua)
    guard !isolated else { return }
    try FileManager.default.createDirectory(
      at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
      .write(to: storageURL, options: .atomic)
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
    debounce = 100
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
  var prefs: Preferences
  @Bindable var model: Model
  var close: () -> Void
  /// Index scope edits; committed only by Apply & Rebuild.
  @State private var draft: Preferences
  @State private var error: String?
  init(prefs: Preferences, model: Model, close: @escaping () -> Void) {
    self.prefs = prefs
    self.model = model
    self.close = close
    let copy = Preferences(isolated: true)
    copy.apply(prefs.values)
    _draft = State(initialValue: copy)
  }

  var body: some View {
    TabView(selection: $model.settingsTab) {
      general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
      index.tabItem { Label("Index", systemImage: "externaldrive") }.tag("index")
      privacy.tabItem { Label("Privacy", systemImage: "hand.raised") }.tag("privacy")
    }
    .frame(width: 560)
  }

  /// Saves one General setting, reporting a failure instead of losing it silently.
  private func update(_ change: (Preferences) -> Void) {
    do {
      try prefs.update(change)
      error = nil
    } catch { self.error = error.localizedDescription }
  }
  private func setting<Value>(_ key: ReferenceWritableKeyPath<Preferences, Value>) -> Binding<Value> {
    Binding(get: { prefs[keyPath: key] }, set: { value in update { $0[keyPath: key] = value } })
  }
  private var shortcut: Binding<ActivationShortcut?> {
    Binding(get: { prefs.shortcut }, set: { value in
      do {
        try prefs.applyShortcut?(value)
        update { $0.shortcut = value }
      } catch { self.error = error.localizedDescription }
    })
  }
  private var debounce: Binding<Int> {
    Binding(get: { model.debounce }, set: { value in
      model.debounce = value
      update { $0.debounce = value }
    })
  }
  @ViewBuilder private var errorFooter: some View {
    if let error = error { Text(error).foregroundStyle(.red) }
  }

  private var general: some View {
    Form {
      Section {
        ShortcutRecorder(shortcut: shortcut, recording: $model.recordingShortcut)
        Picker("Search delay", selection: debounce) {
          Text("None").tag(0)
          Text("100 ms").tag(100)
          Text("300 ms").tag(300)
        }
      }
      Section {
        Picker("Appearance", selection: setting(\.theme)) {
          Text("System").tag("system")
          Text("Light").tag("light")
          Text("Dark").tag("dark")
        }
        Toggle("Show menu bar icon", isOn: setting(\.tray))
      }
      Section {
        LabeledContent("Terminal app (F9)") {
          HStack {
            Text(FileManager.default.displayName(atPath: prefs.terminalApplication))
              .foregroundStyle(.secondary)
            Button("Choose…", action: chooseTerminal)
              .accessibilityLabel("Choose terminal app for F9")
            Button("Reset") { update { $0.terminal = "" } }.disabled(prefs.terminal.isEmpty)
          }
        }
      } footer: {
        VStack(alignment: .leading) {
          Text("F9 opens the selected folder or a file’s parent folder.")
            .foregroundStyle(.secondary)
          errorFooter
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .formStyle(.grouped)
  }

  private func chooseRoot() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.directoryURL = URL(fileURLWithPath: Preferences.expand(draft.root))
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    draft.root = url.path
  }
  private func chooseTerminal() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "Choose"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    update { $0.terminal = url.path }
  }

  private var scopeChanged: Bool {
    draft.root != prefs.root || draft.ignores != prefs.ignores
      || draft.includes != prefs.includes || draft.patterns != prefs.patterns
  }
  private var index: some View {
    Form {
      Section {
        LabeledContent("Index file") {
          Text(model.snapshot).lineLimit(1).truncationMode(.middle)
            .help(model.snapshot).textSelection(.enabled)
        }
        if !model.snapshotDate.isEmpty {
          LabeledContent("Last saved", value: model.snapshotDate)
        }
        LabeledContent("Status", value: model.indexStatus)
      }
      Section {
        HStack {
          TextField("Monitor root", text: $draft.root, prompt: Text("Monitor root path"))
          Button("Choose…", action: chooseRoot)
        }
      }
      Section {
        TextEditor(text: $draft.ignores).frame(height: 56)
          .font(.body.monospaced()).accessibilityLabel("Ignore paths")
      } header: { Text("Ignore paths") }
      Section {
        TextEditor(text: $draft.includes).frame(height: 56)
          .font(.body.monospaced()).accessibilityLabel("Include paths")
      } header: { Text("Include paths") } footer: {
        Text("One absolute path per line; includes override ignored ancestors.")
          .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
      }
      Section {
        TextEditor(text: $draft.patterns).frame(height: 55)
          .font(.body.monospaced()).accessibilityLabel("Exclude patterns")
      } header: {
        HStack {
          Text("Exclude patterns")
          Spacer()
          Button("Add node_modules") {
            if !draft.patternLines.contains("node_modules") {
              draft.patterns +=
                (draft.patterns.isEmpty || draft.patterns.hasSuffix("\n") ? "" : "\n")
                + "node_modules"
            }
          }
          .buttonStyle(.link).controlSize(.small)
        }
      } footer: {
        Text("Names or globs, one per line. Patterns also apply inside included folders.")
          .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
      }
      Section {
        HStack {
          Button("Restore Defaults") {
            draft.root = "/"
            draft.ignores = ""
            draft.includes = ""
            draft.patterns = ""
          }
          Spacer()
          if model.scanning {
            Text("Finish or cancel the current scan first.").foregroundStyle(.secondary)
          }
          Button("Revert") { draft.apply(prefs.values) }.disabled(!scopeChanged)
          Button(model.snapshotOnly ? "Apply" : "Apply & Rebuild") {
            do {
              try model.savePreferences(draft)
              error = nil
            } catch { self.error = error.localizedDescription }
          }
          .keyboardShortcut(.defaultAction)
          .disabled(model.scanning || !(scopeChanged || draft.patternLines != model.loadedPatterns))
        }
      } footer: { errorFooter.frame(maxWidth: .infinity, alignment: .leading) }
    }
    .formStyle(.grouped)
    // Tall enough to show every index field without scrolling.
    .frame(height: 720)
  }

  private var privacy: some View {
    Form {
      Section {
        LabeledContent("Full Disk Access") {
          Button("Open System Settings…") { FileActions.openPrivacySettings() }
        }
      } footer: {
        Text("Enable Full Disk Access for EverythingMac, then relaunch it to search protected files.")
          .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .formStyle(.grouped)
  }
}
