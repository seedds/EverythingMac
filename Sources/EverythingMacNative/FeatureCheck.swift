import AppKit
import CNative
import Carbon
import SwiftUI

// End-to-end feature checks use only disposable files and isolated preferences.
@MainActor
final class FeatureCheck {
  let model: Model
  let window: NSWindow
  let output: String
  var checks: [String] = []
  init(model: Model, window: NSWindow, output: String) {
    self.model = model
    self.window = window
    self.output = output
  }
  func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
    guard condition() else { throw messageError(description) }
    checks.append(description)
  }
  func waitFor(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw messageError("Timed out: \(model.status), \(model.error ?? "")")
  }
  func search(_ query: String) async throws {
    model.query = query
    model.changed()
    model.submit()
    try await waitFor { !model.searching }
  }
  func start() {
    Task { @MainActor in
      do {
        try await run()
        finish(nil)
      } catch { finish(error.localizedDescription) }
    }
  }
  func run() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent(
      "everything-features-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let migrationDirectory = temp.appendingPathComponent("index-migration")
    try FileManager.default.createDirectory(at: migrationDirectory, withIntermediateDirectories: true)
    let legacyIndex = migrationDirectory.appendingPathComponent(IndexLocation.legacyFilename)
    let currentIndex = migrationDirectory.appendingPathComponent(IndexLocation.filename)
    let indexBytes = Data("existing index bytes".utf8)
    try indexBytes.write(to: legacyIndex)
    try check(
      IndexLocation.existingIndex(in: migrationDirectory.path) == legacyIndex.path
        && !FileManager.default.fileExists(atPath: currentIndex.path),
      "Read-only index resolution finds the legacy index without migrating")
    try IndexLocation.migrate(in: migrationDirectory.path)
    let migratedBytes = try Data(contentsOf: currentIndex)
    try check(
      migratedBytes == indexBytes && !FileManager.default.fileExists(atPath: legacyIndex.path),
      "Index migration preserves bytes and removes only the legacy filename")
    try Data("older index".utf8).write(to: legacyIndex)
    try IndexLocation.migrate(in: migrationDirectory.path)
    let retainedBytes = try Data(contentsOf: currentIndex)
    try check(
      retainedBytes == indexBytes && FileManager.default.fileExists(atPath: legacyIndex.path)
        && IndexLocation.existingIndex(in: migrationDirectory.path) == currentIndex.path,
      "An existing renamed index takes precedence without overwriting either file")
    let freshDirectory = temp.appendingPathComponent("fresh-install")
    try IndexLocation.migrate(in: freshDirectory.path)
    try check(
      IndexLocation.existingIndex(in: freshDirectory.path)
        == freshDirectory.appendingPathComponent(IndexLocation.filename).path,
      "Fresh installations use the EverythingMac index filename")
    let libraryURL = temp.appendingPathComponent("library.json")
    let library = SearchLibrary(url: libraryURL)
    let original = SearchState(query: "report", directory: "/docs", sensitive: true)
    for i in 0..<105 {
      library.record(SearchState(query: "q\(i)", directory: "", sensitive: false))
    }
    library.record(original)
    library.record(original)
    try check(
      library.recent.count == 100 && library.recent.first?.state == original,
      "History deduplicates and retains 100 states")
    try library.save(name: "Reports", state: original)
    do {
      try library.save(name: " reports ", state: original)
      throw messageError("Duplicate saved name accepted")
    } catch { if error.localizedDescription == "Duplicate saved name accepted" { throw error } }
    let id = library.saved[0].id
    try library.save(name: "Work reports", state: original, id: id)
    try check(
      library.saved.count == 1 && library.saved[0].name == "Work reports",
      "Saved searches rename without duplication")
    try library.flush()
    let restored = SearchLibrary(url: libraryURL)
    try check(
      restored.saved[0].state == original && restored.recent.count == 100,
      "History and saved state survive reload")
    restored.clearHistory()
    try restored.flush()
    try check(
      SearchLibrary(url: libraryURL).recent.isEmpty && restored.saved.count == 1,
      "Clear History preserves saved searches")
    restored.deleteSaved(id)
    try restored.flush()
    try check(SearchLibrary(url: libraryURL).saved.isEmpty, "Saved search deletion persists")
    let corrupt = temp.appendingPathComponent("corrupt.json")
    let broken = Data("broken".utf8)
    try broken.write(to: corrupt)
    let blocked = SearchLibrary(url: corrupt)
    blocked.record(original)
    try blocked.flush()
    let preserved = try Data(contentsOf: corrupt)
    try check(
      blocked.error != nil && preserved == broken, "Unreadable library is reported and preserved")

    let preferencesURL = temp.appendingPathComponent("preferences.json")
    let prefs = Preferences(fileURL: preferencesURL)
    prefs.shortcut = ActivationShortcut(
      key: UInt32(kVK_ANSI_P), modifiers: UInt32(controlKey | shiftKey))
    prefs.patterns = "node_modules\n*.log"
    try prefs.save()
    let draft = Preferences(isolated: true)
    draft.apply(prefs.values)
    try check(draft.shortcut == prefs.shortcut, "Preferences draft preserves configured shortcut")
    draft.patterns = "["
    do {
      try draft.validate()
      throw messageError("Invalid pattern accepted")
    } catch { if error.localizedDescription == "Invalid pattern accepted" { throw error } }
    checks.append("Invalid exclusion is rejected before save")
    draft.patterns = "*.log"
    let previousPatterns = model.prefs.patterns
    model.scanning = true
    do {
      try model.savePreferences(draft)
      throw messageError("Saved preferences during scan")
    } catch { if error.localizedDescription == "Saved preferences during scan" { throw error } }
    model.scanning = false
    try check(
      model.prefs.patterns == previousPatterns,
      "Active scan rejects configuration save without losing preferences")
    let loaded = Preferences(fileURL: preferencesURL)
    try check(
      loaded.shortcut == prefs.shortcut && loaded.patterns == prefs.patterns,
      "Shortcut and exclusions survive preferences reload")
    loaded.shortcut = nil
    try loaded.save()
    try check(Preferences(fileURL: preferencesURL).shortcut == nil, "Disabled shortcut persists")
    var registrations = 0
    var released = 0
    let manager = ActivationShortcutManager(
      register: { shortcut in
        if shortcut.key == UInt32(kVK_ANSI_X) { throw messageError("Simulated conflict") }
        registrations += 1
        return OpaquePointer(bitPattern: registrations)!
      }, unregister: { _ in released += 1 })
    try manager.apply(.standard)
    do {
      try manager.apply(ActivationShortcut(key: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey)))
      throw messageError("Conflict accepted")
    } catch { if error.localizedDescription == "Conflict accepted" { throw error } }
    try check(
      manager.current == .standard && released == 0,
      "Shortcut conflict preserves previous registration")
    try manager.apply(prefs.shortcut)
    try manager.apply(nil)
    try check(
      registrations == 2 && released == 2, "Shortcut replacement and disable release registrations")
    let actual = ActivationShortcutManager()
    try actual.apply(
      ActivationShortcut(key: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | cmdKey)))
    try actual.apply(nil)
    checks.append("Real global shortcut registration and release")

    let root = temp.appendingPathComponent("files")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("node_modules/nested"), withIntermediateDirectories: true)
    try Data("invoice report".utf8).write(to: root.appendingPathComponent("report.txt"))
    try Data("hidden".utf8).write(to: root.appendingPathComponent("node_modules/nested/hidden.txt"))
    let reply: Reply = try await withCheckedThrowingContinuation { continuation in
      model.engine.scan(root: root.path, ignores: [], includes: [], patterns: ["node_modules"]) {
        continuation.resume(with: $0)
      }
    }
    model.root = reply.root ?? root.path
    model.loadedPatterns = reply.exclusion_patterns ?? []
    model.ready = true
    try check(model.loadedPatterns == ["node_modules"], "Scan bridge returns active patterns")
    try await search("hidden")
    try check(model.total == 0, "Native search excludes pruned descendants")
    for entry in SearchHelp.entries {
      if let example = entry.example {
        let fixtureExample = example.replacingOccurrences(of: "~/Documents", with: model.root)
          .replacingOccurrences(of: "~/Downloads", with: model.root)
        try await search(fixtureExample)
        try check(model.error == nil, "Help example accepted: \(example)")
      }
    }
    try await search("report")
    try check(model.total == 1, "Native fixture query matches")
    model.library.clearHistory()
    model.rememberQuery()
    try check(
      model.library.recent.first?.state.query == "report",
      "Entering results records a successful search")
    let state = SearchState(query: "report", directory: model.root, sensitive: true)
    let before = model.generation
    model.restoreSearch(state)
    try await waitFor { !model.searching }
    try await Task.sleep(nanoseconds: 250_000_000)
    try check(
      model.generation == before + 1 && model.currentSearchState == state && model.total == 1,
      "Restoration publishes all fields with one search")
    try await search("file: report")
    try await Task.sleep(nanoseconds: 2_100_000_000)
    try check(
      model.library.recent.first?.state.query == "file: report",
      "Two-second pause records a successful search")
    try await search("report.txt")
    model.library.clearHistory()
    try await Task.sleep(nanoseconds: 2_100_000_000)
    try check(
      model.library.recent.isEmpty, "Cleared history stays cleared past pending recording deadline")
    model.submit(background: true)
    try await waitFor { !model.searching }
    try check(model.library.recent.isEmpty, "Background refresh does not enter history")
    try await search("content:")
    try await Task.sleep(nanoseconds: 2_100_000_000)
    try check(
      model.error != nil && model.library.recent.isEmpty, "Failed query is excluded from history")
    model.error = nil
    try await search("report")
    try model.library.save(name: "Report preset", state: state)
    window.setContentSize(NSSize(width: 800, height: 600))
    try render(window, suffix: "results")
    model.libraryOpen = true
    try await Task.sleep(nanoseconds: 300_000_000)
    if let popover = window.childWindows?.first { try render(popover, suffix: "library") }
    model.libraryOpen = false
    model.preferencesOpen = true
    try await Task.sleep(nanoseconds: 300_000_000)
    if let sheet = window.attachedSheet { try render(sheet, suffix: "preferences") }
    model.preferencesOpen = false
    try check(window.contentView?.bounds.width == 800, "Native layout renders at minimum width")
    if let delegate = NSApp.delegate as? AppDelegate {
      delegate.showSearchHelp()
      try await Task.sleep(nanoseconds: 300_000_000)
      try check(delegate.helpWindow?.isVisible == true, "Search help opens in a native window")
      if let help = delegate.helpWindow { try render(help, suffix: "help") }
      delegate.helpWindow?.orderOut(nil)
    }
  }
  func render(_ window: NSWindow, suffix: String) throws {
    guard let view = window.contentView,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { throw messageError("Cannot capture native view") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw messageError("Cannot encode native view")
    }
    try png.write(
      to: URL(fileURLWithPath: output).deletingPathExtension().appendingPathExtension(
        suffix + ".png"))
  }
  func finish(_ error: String?) {
    model.close { _ in
      let report: [String: Any] = ["checks": self.checks, "error": error ?? NSNull()]
      if let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: URL(fileURLWithPath: self.output))
      }
      NSApp.terminate(nil)
    }
  }
}
