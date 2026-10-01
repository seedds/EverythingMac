import AppKit
import CNative
import Carbon
import SwiftUI

// End-to-end feature checks use only disposable files and isolated preferences.
@MainActor
final class FeatureCheck {
  let model: Model
  let window: NSWindow
  unowned let delegate: AppDelegate
  let output: String
  var checks: [String] = []
  private var failure: String?
  init(model: Model, window: NSWindow, delegate: AppDelegate, output: String) {
    self.model = model
    self.window = window
    self.delegate = delegate
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
  /// Input methods such as Pinyin compose marked text before a candidate is chosen.
  /// App updates must not reset it, and Escape and the arrow keys belong to the
  /// input method until the text is committed. Drives the field editor through the
  /// same text input calls an input method makes.
  func checkInputMethodComposition() async throws {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    model.focusSearch?()
    try await waitFor { self.window.isKeyWindow && self.window.firstResponder is NSTextView }
    guard let editor = window.firstResponder as? NSTextView else {
      throw messageError("Search field editor is missing")
    }
    let committed = model.query
    editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    editor.setMarkedText(
      "ni", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0))
    try await Task.sleep(nanoseconds: 400_000_000)
    try check(
      editor.hasMarkedText() && model.query == committed && !model.searching,
      "Text being composed by an input method is not searched")
    model.submit(background: true)
    try await waitFor { !self.model.searching }
    model.status = "Composing"
    try await Task.sleep(nanoseconds: 300_000_000)
    let intact = editor.hasMarkedText() && editor.string == committed + "ni"
    try check(
      intact,
      "App updates keep text being composed"
        + (intact ? "" : " (marked: \(editor.hasMarkedText()), text: \(editor.string))"))
    let keys: [(String, UInt16, String)] = [
      ("Escape", 53, "\u{1b}"), ("Down Arrow", 125, "\u{f701}"), ("Up Arrow", 126, "\u{f700}"),
    ]
    for (name, keyCode, character) in keys {
      guard
        let event = NSEvent.keyEvent(
          with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
          windowNumber: window.windowNumber, context: nil, characters: character,
          charactersIgnoringModifiers: character, isARepeat: false, keyCode: keyCode)
      else { throw messageError("Cannot create the \(name) key event") }
      try check(delegate.key(event) === event, "\(name) goes to the input method while composing")
    }
    try check(
      window.isVisible && editor.hasMarkedText(), "Escape while composing keeps the window and text")
    editor.insertText("你", replacementRange: editor.markedRange())
    try await waitFor { self.model.query == committed + "你" }
    try check(!editor.hasMarkedText(), "Choosing a candidate commits the composed text for search")
    try await search(committed)
  }
  /// Browsing history with Option-Up/Down leaves its order alone; Return records.
  func checkHistoryNavigation() async throws {
    let states = ["history-a", "history-b", "history-c"].map {
      SearchState(query: $0, directory: "", sensitive: false)
    }
    model.library.clearHistory()
    states.forEach(model.library.record)
    let order = model.library.recent.map(\.state)
    for _ in 0..<2 {
      model.navigateHistory(-1)
      try await waitFor { !self.model.searching }
    }
    try await Task.sleep(nanoseconds: 300_000_000)
    try check(
      model.currentSearchState == states[1] && model.library.recent.map(\.state) == order,
      "Browsing history with Option-Up does not reorder it")
    model.rememberQuery()
    try check(
      model.library.recent.first?.state == states[1], "Return records the browsed search")
    model.library.clearHistory()
  }
  /// F2 selects the name without its extension, so typing replaces only the name.
  func checkRenameSelection(_ path: String) throws {
    var selected: NSRange?
    let opened = ProcessInfo.processInfo.systemUptime
    let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
      guard let alert = NSApp.modalWindow else { return }
      guard ProcessInfo.processInfo.systemUptime - opened > 0.3 else { return }
      selected = (alert.firstResponder as? NSTextView)?.selectedRange()
      timer.invalidate()
      NSApp.stopModal(withCode: .alertSecondButtonReturn)
    }
    RunLoop.main.add(timer, forMode: .common)
    model.actions.rename([path])
    timer.invalidate()
    try check(
      selected == NSRange(location: 0, length: 6)
        && FileManager.default.fileExists(atPath: path),
      "Rename selects the name without its extension"
        + (selected == NSRange(location: 0, length: 6) ? "" : " (selected \(String(describing: selected)))"))
  }
  /// Closing Settings while recording a shortcut must not leave the recorder taking
  /// keys typed in the search window.
  func checkRecorderAfterClosingSettings(_ settings: NSWindow, appMenu: NSMenu, index: Int)
    async throws
  {
    model.settingsTab = "general"
    appMenu.performActionForItem(at: index)
    try await Task.sleep(nanoseconds: 300_000_000)
    // The recorder is the first button on the General tab; recordingShortcut
    // confirms that pressing it started recording.
    func firstButton(in view: NSView) -> NSView? {
      if String(describing: type(of: view)) == "SwiftUIAppKitButton" { return view }
      return view.subviews.lazy.compactMap { firstButton(in: $0) }.first
    }
    guard let content = settings.contentView, let record = firstButton(in: content) else {
      throw messageError("Cannot find the shortcut recorder")
    }
    _ = record.accessibilityPerformPress()
    try await waitFor { self.model.recordingShortcut }
    settings.performClose(nil)
    try await waitFor { !self.model.recordingShortcut }
    let shortcut = model.prefs.shortcut
    window.makeKeyAndOrderFront(nil)
    model.focusSearch?()
    try await waitFor { self.window.isKeyWindow }
    guard
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "k",
        charactersIgnoringModifiers: "k", isARepeat: false, keyCode: UInt16(kVK_ANSI_K))
    else { throw messageError("Cannot create a key event") }
    NSApp.sendEvent(event)
    try await Task.sleep(nanoseconds: 100_000_000)
    try check(
      model.prefs.shortcut == shortcut,
      "Closing Settings while recording leaves keys in the search window alone")
    model.settingsTab = "index"
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
    try await search("size:abc")
    try await Task.sleep(nanoseconds: 2_100_000_000)
    try check(
      model.error != nil && model.library.recent.isEmpty, "Failed query is excluded from history")
    model.error = nil
    try await checkHistoryNavigation()
    try await search("report")
    // A message about an earlier action, such as a partial move to the Trash,
    // survives background refreshes; a search the user starts clears it.
    let actionMessage = "Moved 1 of 2 items to the Trash."
    model.error = actionMessage
    model.submit(background: true)
    try await waitFor { !model.searching }
    try check(model.error == actionMessage, "Background refresh keeps an earlier action's message")
    try await search("report")
    try check(model.error == nil, "A new search clears an earlier action's message")
    try checkRenameSelection(model.root + "/report.txt")
    try await checkInputMethodComposition()
    try model.library.save(name: "Report preset", state: state)
    window.setContentSize(NSSize(width: 800, height: 600))
    try render(window, suffix: "results")
    model.libraryOpen = true
    try await Task.sleep(nanoseconds: 300_000_000)
    if let popover = window.childWindows?.first { try render(popover, suffix: "library") }
    model.libraryOpen = false
    guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
      let settingsIndex = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," })
    else { throw messageError("SwiftUI Settings command is missing") }
    model.settingsTab = "index"
    appMenu.performActionForItem(at: settingsIndex)
    try await Task.sleep(nanoseconds: 300_000_000)
    guard let settings = NSApp.windows.first(where: {
      $0.identifier?.rawValue == "EverythingMacSettings"
    }) else { throw messageError("SwiftUI Settings window is missing") }
    try check(settings.isVisible && window.attachedSheet == nil, "Settings opens in an independent SwiftUI window")
    try render(settings, suffix: "preferences")
    func rootField(in view: NSView?) -> NSTextField? {
      guard let view = view else { return nil }
      if let field = view as? NSTextField, field.placeholderString == "Monitor root path" { return field }
      return view.subviews.lazy.compactMap { rootField(in: $0) }.first
    }
    guard let field = rootField(in: settings.contentView), settings.makeFirstResponder(field),
      let rootEditor = settings.firstResponder as? NSTextView else {
      throw messageError("Cannot focus Settings root field")
    }
    rootEditor.selectAll(nil)
    rootEditor.insertText("/discard-this-draft", replacementRange: rootEditor.selectedRange())
    try await Task.sleep(nanoseconds: 100_000_000)
    try check(field.stringValue == "/discard-this-draft", "Settings draft accepts edits")
    settings.performClose(nil)
    try await Task.sleep(nanoseconds: 100_000_000)
    let savedRoot = model.prefs.root
    model.prefs.root = "/updated-while-settings-closed"
    appMenu.performActionForItem(at: settingsIndex)
    try await Task.sleep(nanoseconds: 300_000_000)
    try check(settings.isVisible, "Settings reopens after closing")
    try await waitFor { rootField(in: settings.contentView)?.stringValue == self.model.prefs.root }
    try check(rootField(in: settings.contentView)?.stringValue == model.prefs.root,
      "Reopening Settings discards unsaved edits and reads current preferences")
    settings.performClose(nil)
    model.prefs.root = savedRoot
    try await checkRecorderAfterClosingSettings(settings, appMenu: appMenu, index: settingsIndex)
    try check(window.contentView?.bounds.width == 800, "Native layout renders at minimum width")
    delegate.showSearchHelp()
    try await Task.sleep(nanoseconds: 300_000_000)
    try check(delegate.helpWindow?.isVisible == true, "Search help opens in a native window")
    if let help = delegate.helpWindow { try render(help, suffix: "help") }
    delegate.helpWindow?.orderOut(nil)
    delegate.showWindow()
    window.performClose(nil)
    try check(!window.isVisible && !model.closed, "Closing search hides the window and keeps the engine alive")
    delegate.showWindow()
    try check(window.isVisible, "Search reopens after closing")
    window.miniaturize(nil)
    delegate.showWindow()
    try check(!window.isMiniaturized && window.isVisible, "Activation restores a minimized search window")
    delegate.toggleWindow()
    try check(!window.isVisible, "Activation shortcut hides the visible search window")
    delegate.toggleWindow()
    try check(window.isVisible, "Activation shortcut reopens the search window")
    window.orderOut(nil)
    var pid = ProcessInfo.processInfo.processIdentifier
    let target = NSAppleEventDescriptor(descriptorType: typeKernelProcessID,
      bytes: &pid, length: MemoryLayout.size(ofValue: pid))
    let reopen = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
      eventID: AEEventID(kAEReopenApplication), targetDescriptor: target,
      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    _ = try reopen.sendEvent(options: .noReply, timeout: 2)
    try await waitFor { self.window.isVisible }
    // A duplicate window may appear after the existing one is shown.
    try await Task.sleep(nanoseconds: 500_000_000)
    try check(NSApp.windows.filter { $0.title == "EverythingMac" && $0.isVisible }.count == 1,
      "Dock reopen restores the existing search window without duplicates")
    func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
      menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) }
    }
    func copyKey(_ flags: NSEvent.ModifierFlags, _ character: String) -> String? {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: character,
        charactersIgnoringModifiers: character, isARepeat: false, keyCode: UInt16(kVK_ANSI_C)
      ).flatMap(ResultsView.fileCommand)
    }
    try check(
      copyKey(.command, "c") == "copy" && copyKey([.command, .shift], "C") == "paths"
        && copyKey([.command, .option], "c") == "paths",
      "Command-C copies files; Command-Shift-C and Option-Command-C copy paths")
    let commands = NSApp.mainMenu.map(menuItems) ?? []
    for (key, name) in [("w", "Close Window"), ("q", "Quit"), ("h", "Hide"), (",", "Settings")] {
      try check(commands.contains { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command },
        "Standard Command-\(key) command is available for \(name)")
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
    failure = error
    if let error = error { fputs("Feature check failed: \(error)\n", stderr) }
    // Exercise SwiftUI's forwarding to the application delegate and its async
    // termination handshake, rather than closing the model before asking to quit.
    // Request quit from the run loop, like a menu action. Calling terminate from
    // a main-actor task blocks the dispatch queue needed by engine completion.
    Timer.scheduledTimer(withTimeInterval: 0.01, repeats: false) { _ in NSApp.terminate(nil) }
  }
  func didFinishTermination(_ error: Error?) {
    if model.closeFinished { checks.append("Application quit waits for engine shutdown") }
    let outcome = failure ?? error?.localizedDescription
      ?? (model.closeFinished ? nil : "Engine shutdown incomplete")
    let report: [String: Any] = ["checks": checks, "error": outcome as Any? ?? NSNull()]
    if let data = try? JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: URL(fileURLWithPath: output))
    }
  }
}
