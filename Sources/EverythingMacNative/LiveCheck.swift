import AppKit
import CNative
import Quartz

// Real native window + Rust + FSEvents integration. Owns only disposable files.
final class LiveCheck {
  let model: Model
  let output: String
  let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
    "everything-mac-live-" + UUID().uuidString)
  var root: URL { directory.appendingPathComponent("files") }
  var timer: Timer?
  var step = 0
  var since = ProcessInfo.processInfo.systemUptime
  var checks: [String] = []
  var pending = false
  var scanCounts = Set<Int>()
  var countBeforeEvent = 0
  var selectionBeforeSort: UInt64 = 0
  let terminalValidationError = "Choose an installed terminal application in Preferences."
  var tabCheck: Bool { CommandLine.arguments.contains("--tab-check") }
  var trashCheck: Bool { CommandLine.arguments.contains("--trash-check") }
  var actionSelectionSize: Int { trashCheck ? 130 : 1200 }
  var trashActions: FileActions?
  var trashExpected = Set<String>()
  var trashReceipts: [(URL, URL)] = []
  init(model: Model, output: String) {
    self.model = model
    self.output = output
  }
  func start() {
    do {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent("ignored/keep"), withIntermediateDirectories: true)
      try Data("alpha".utf8).write(to: root.appendingPathComponent("alpha.txt"))
      try Data("beta larger".utf8).write(to: root.appendingPathComponent("beta.txt"))
      try Data().write(to: root.appendingPathComponent("ignored/hidden.txt"))
      try Data().write(to: root.appendingPathComponent("ignored/keep/included.txt"))
      model.snapshotOnly = false
      model.live = true
      model.checkpointPath = directory.appendingPathComponent("native/everything-mac.db").path
      model.prefs.root = root.resolvingSymlinksInPath().path
      model.prefs.ignores = model.prefs.root + "/ignored"
      model.prefs.includes = model.prefs.root + "/ignored/keep"
      model.query = "alpha"
      // Focused entry points for file-action and tab-transition races.
      if CommandLine.arguments.contains("--terminal-check") || CommandLine.arguments.contains("--trash-check") || tabCheck {
        for i in 0..<actionSelectionSize {
          try Data("terminal".utf8).write(to: root.appendingPathComponent("preview-item-\(i).txt"))
        }
        model.query = "preview-item"
        step = tabCheck ? 16 : 20
      }
      if trashCheck {
        trashActions = FileActions(model, trashItem: { [weak self] url in
          guard let self = self, self.trashExpected.contains(url.path) else {
            throw messageError("Trash attempted to target an unselected fixture")
          }
          var destination: NSURL?
          try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
          guard let destination = destination as URL? else {
            throw messageError("Trash did not return a recovery location")
          }
          self.trashReceipts.append((url, destination))
        })
      }
      if CommandLine.arguments.contains("--scan-progress-check") {
        for i in 0..<20_000 {
          let folder = root.appendingPathComponent("scan-\(i)")
          try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
          try Data().write(to: folder.appendingPathComponent("item.txt"))
        }
        step = 30
      }
      model.scan()
      timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
        self?.tick()
      }
    } catch { finish(error.localizedDescription) }
  }
  func next(_ description: String) {
    checks.append(description)
    step += 1
    since = ProcessInfo.processInfo.systemUptime
  }
  func query(_ q: String) {
    model.query = q
    model.submit()
  }
  func tick() {
    guard !pending else { return }
    if model.scanning, model.indexedCount > 0 { scanCounts.insert(model.indexedCount) }
    if ProcessInfo.processInfo.systemUptime - since > (tabCheck ? 8 : 25) {
      finish("Timeout at \(step): \(model.status); \(model.error ?? ""); tab=\(model.activeTab), selection=\(model.selectionCount), loading=\(model.selectionLoading), pendingDraw=\(String(describing: model.pendingDraw))")
      return
    }
    // Events has no Files table to acknowledge a background result draw.
    guard model.ready, !model.searching, !model.scanning,
      model.activeTab != "files" || model.pendingDraw == nil else { return }
    if let error = model.error {
      // A deliberately missing terminal proves F9 reached terminal validation
      // without opening an external app or failing on stale result generations.
      if (step == 23 || step == 27), error == terminalValidationError {
        model.error = nil
        if step == 23 {
          next("F9 resolves a selected file after live updates invalidate displayed rows")
          model.submit(background: true)
        } else {
          next("F9 resolves the first file of a large selection during live updates")
          finish(nil)
        }
      } else {
        finish(error)
      }
      return
    }
    if trashCheck && (step == 23 || step == 27) {
      guard model.status == "File action completed" else { return }
      do {
        guard Set(trashReceipts.map { $0.0.path }) == trashExpected,
          trashReceipts.allSatisfy({ !FileManager.default.fileExists(atPath: $0.0.path) }),
          FileManager.default.fileExists(atPath: root.appendingPathComponent("beta.txt").path)
        else { throw messageError("Trash did not move exactly the selected files") }
        try restoreTrashedFixtures()
        if step == 23 {
          next("F8 trashes exactly one selected file after live row invalidation; fixture restored")
          model.submit(background: true)
        } else {
          next("F8 trashes all 130 selected files beyond the 128-path UI sample; fixtures restored")
          finish(nil)
        }
      } catch { finish(error.localizedDescription) }
      return
    }
    do {
      switch step {
      case 30, 31:
        guard !scanCounts.isEmpty else {
          finish("Files counter did not update during scan at step \(step)")
          return
        }
        next("Files counter updates during \(step == 30 ? "initial scan" : "rescan")")
        scanCounts.removeAll()
        if step == 31 {
          model.scan(useCurrentConfig: true)
        } else {
          countBeforeEvent = model.indexedCount
          try Data().write(to: root.appendingPathComponent("after-scan.txt"))
        }
      case 32:
        guard model.processedEventCount > 0, model.indexedCount > countBeforeEvent else { return }
        next("Files and Events counters update after scanning finishes")
        finish(nil)
      case 0:
        guard model.total == 1 else { return }
        next("Initial native scan and search")
        model.selectionChanged(IndexSet(integer: 0))
        try Data().write(to: root.appendingPathComponent("alpha-new.txt"))
      case 1:
        guard model.total == 2, !model.selectionLoading else { return }
        guard model.selectedPaths.contains(model.root + "/alpha.txt") else {
          finish(
            "Selection was lost during live refresh: \(model.selectedPaths); generation \(model.displayedGeneration); background \(model.backgroundResult)"
          )
          return
        }
        next("File creation updates results and preserves selection by path")
        _ = try FileActions.renameExclusive(
          path: root.appendingPathComponent("alpha-new.txt").path, name: "résumé.txt")
      case 2:
        guard model.total == 1 else { return }
        next("Rename reconciles live search")
        query("résumé")
      case 3:
        guard model.total == 1 else { return }
        let original = root.appendingPathComponent("alpha.txt")
        let target = root.appendingPathComponent("beta.txt")
        do {
          _ = try FileActions.renameExclusive(path: original.path, name: target.lastPathComponent)
          finish("Rename replaced an existing file")
          return
        } catch {
          guard try Data(contentsOf: target) == Data("beta larger".utf8) else {
            finish("Rename collision modified destination")
            return
          }
        }
        next("Unicode rename and exclusive collision handling")
        try FileManager.default.removeItem(at: root.appendingPathComponent("résumé.txt"))
      case 4:
        guard model.total == 0 else { return }
        next("File deletion removes stale results")
        query("hidden")
      case 5:
        guard model.total == 0 else {
          finish("Ignored file appeared")
          return
        }
        next("Ignore filter")
        query("included")
      case 6:
        guard model.total == 1 else {
          finish("Included exception missing")
          return
        }
        next("Include overrides ignored ancestor")
        model.live = false
        model.setLive()
        try Data().write(to: root.appendingPathComponent("paused.txt"))
        model.live = true
        model.setLive()
        query("paused")
      case 7:
        guard model.total == 1 else { return }
        next("Watcher resumes from saved event checkpoint")
        query(".txt")
        model.sortKey = "filename"
        model.sortAscending = false
        model.submit()
      case 8:
        let paths = model.rows.sorted { $0.key < $1.key }.map {
          URL(fileURLWithPath: $0.value.path).lastPathComponent
        }
        guard paths == paths.sorted(by: >) else {
          finish("Sort order mismatch")
          return
        }
        next("Backend sort ordering")
        pending = true
        model.engine.perform({ try decode(cn_checkpoint($0)) }) { [weak self] result in
          guard let self = self else { return }
          self.pending = false
          if case .failure(let e) = result {
            self.finish(e.localizedDescription)
            return
          }
          self.next("Native checkpoint persisted")
          self.model.snapshot = self.model.checkpointPath
          self.model.load()
        }
      case 10:
        guard model.total > 0 else { return }
        next("Checkpoint reload restores index")
        model.prefs.ignores = ""
        model.prefs.includes = ""
        model.query = "hidden"
        model.load()
      case 11:
        guard model.total == 1 else { return }
        next("Saved scope mismatch triggers index rebuild on load")
        let trash = root.appendingPathComponent("trash-fixture-" + UUID().uuidString)
        try Data("recoverable".utf8).write(to: trash)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: trash, resultingItemURL: &resulting)
        guard !FileManager.default.fileExists(atPath: trash.path), let recovered = resulting as URL?
        else {
          finish("Trash did not return a recoverable URL")
          return
        }
        try FileManager.default.moveItem(at: recovered, to: trash)
        next("Native Trash moves fixture and supports recovery")
        model.actions.preview.show([trash.path])
      case 13:
        guard QLPreviewPanel.shared()?.isVisible == true,
          model.actions.preview.numberOfPreviewItems(in: QLPreviewPanel.shared()) == 1
        else {
          finish("Quick Look did not show selected file")
          return
        }
        QLPreviewPanel.shared()?.orderOut(nil)
        next("Quick Look shows a real selected file")
        let resources = Bundle.main.resourceURL!
        guard Bundle.main.localizations == ["en"],
          !FileManager.default.fileExists(atPath: resources.appendingPathComponent("Translations").path),
          !FileManager.default.fileExists(atPath: resources.appendingPathComponent("native-translations.json").path)
        else {
          finish("English-only bundle contains unexpected language resources")
          return
        }
        next("English-only bundle has no translation resources")
        try checkPreferences()
        next("Empty fresh preferences, saved settings, and restore defaults")
        model.actions.preview.update([])
        for i in 0..<1200 {
          try Data("preview".utf8).write(to: root.appendingPathComponent("preview-item-\(i).txt"))
        }
        model.query = "preview-item"
        model.scan()
      case 16:
        guard model.total == 1200 else { return }
        model.selectionChanged(IndexSet(integersIn: 0..<1200))
        next("Large result fixture")
      case 17:
        guard !model.selectionLoading, model.selectionCount == 1200 else { return }
        guard model.selectedPaths.count == 128 else {
          finish("Passive selection was not bounded")
          return
        }
        pending = true
        model.resolveSelection { [weak self] paths in
          guard let self = self else { return }
          guard paths.count == 1200 else {
            self.finish("Explicit action omitted uncached rows")
            return
          }
          self.model.actions.preview.show(paths)
          self.selectionBeforeSort = self.model.displayedGeneration
          self.model.sort(by: "filename")
          self.next("Large explicit selection resolves every path")
          self.pending = false
        }
      case 18:
        guard model.displayedGeneration > selectionBeforeSort, !model.selectionLoading else { return }
        guard model.actions.preview.urls.count == 1200 else { return }
        next("Quick Look retains all selected files after sort")
        model.activeTab = "events"
        // A live refresh can complete after the Files table has been hidden.
        if tabCheck { model.submit(background: true) }
      case 19:
        guard !model.selectionLoading, model.selectionCount == 0 else { return }
        model.activeTab = "files"
        next("Events tab clears actionable selection")
      case 20:
        guard !model.selectionLoading else { return }
        guard model.selectionCount == 0, model.selectedPaths.isEmpty else {
          finish("Invisible selection survived tab switch")
          return
        }
        next("Returning to Files has no invisible action target")
        if tabCheck { finish(nil); return }
        model.timer?.invalidate()
        if trashCheck { model.live = false }
        model.prefs.terminal = directory.appendingPathComponent("missing-terminal.app").path
        model.selectionChanged(IndexSet(integer: 0))
      case 21, 25:
        guard !model.selectionLoading, model.selectionCount == (step == 21 ? 1 : actionSelectionSize) else {
          return
        }
        if trashCheck {
          trashExpected = step == 21 ? Set(model.selectedPaths)
            : Set((0..<actionSelectionSize).map { model.root + "/preview-item-\($0).txt" })
        }
        try Data("unrelated change".utf8).write(
          to: root.appendingPathComponent("terminal-event-\(step).txt"))
        step += 1
        since = ProcessInfo.processInfo.systemUptime
      case 22, 26:
        pollBeforeTerminalAction()
      case 24:
        guard model.total == actionSelectionSize, !model.selectionLoading else { return }
        model.selectionChanged(IndexSet(integersIn: 0..<actionSelectionSize))
        step = 25
        since = ProcessInfo.processInfo.systemUptime
      default: break
      }
    } catch { finish(error.localizedDescription) }
  }
  func pollBeforeTerminalAction() {
    pending = true
    let ticket = model.displayedGeneration
    model.engine.perform({ handle in
      let reply = try decode(cn_poll(handle))
      if reply.changed == true {
        guard try decode(cn_rows(handle, ticket, 0, 1)).status == "stale" else {
          throw messageError("Terminal regression fixture did not invalidate displayed rows")
        }
      }
      return reply
    }) { [weak self] result in
      guard let self = self else { return }
      self.pending = false
      switch result {
      case .failure(let error): self.finish(error.localizedDescription)
      case .success(let reply):
        guard reply.changed == true else { return }
        self.step += 1
        self.since = ProcessInfo.processInfo.systemUptime
        if self.trashCheck {
          self.model.status = "Testing Trash…"
          self.trashActions?.perform("trash")
        } else {
          self.model.actions.perform("terminal")
        }
      }
    }
  }
  func checkPreferences() throws {
    let file = directory.appendingPathComponent("fresh-preferences.json")
    let prefs = Preferences(fileURL: file)
    func checkEmpty(_ value: Preferences) throws {
      guard value.includes.isEmpty, value.ignores.isEmpty, value.terminal.isEmpty else {
        throw messageError("Fresh preferences should have empty folder filters and terminal")
      }
      guard value.terminalApplication == "/System/Applications/Utilities/Terminal.app",
        value.terminal.isEmpty else {
        throw messageError("Empty terminal should resolve to macOS Terminal without changing the setting")
      }
    }
    try checkEmpty(prefs)
    try prefs.validate()
    try prefs.save()
    try checkEmpty(Preferences(fileURL: file))
    prefs.includes = root.path
    prefs.ignores = "/tmp/ignored"
    prefs.terminal = "/Applications/Custom Terminal.app"
    try prefs.validate()
    try prefs.save()
    let reopened = Preferences(fileURL: file)
    guard reopened.includes == prefs.includes, reopened.ignores == prefs.ignores,
      reopened.terminal == prefs.terminal, reopened.terminalApplication == prefs.terminal else {
      throw messageError("Explicit user preferences did not survive reopening")
    }
    reopened.restoreDefaults()
    try reopened.validate()
    try reopened.save()
    try checkEmpty(Preferences(fileURL: file))
    guard Model(prefs: Preferences(isolated: true)).snapshot == Preferences.index else {
      throw messageError("Default index is not the app's own index")
    }
  }
  func finish(_ error: String?) {
    timer?.invalidate()
    timer = nil
    var reportError = error
    if trashCheck {
      // Recovery waits for any in-flight fixture action before moving its receipts.
      trashActions?.queue.sync {}
      do { try restoreTrashedFixtures() }
      catch { reportError = "Fixture recovery failed: \(error.localizedDescription)" }
    }
    let report: [String: Any] = [
      "checks": checks, "error": reportError as Any? ?? NSNull(), "fixture": directory.path,
    ]
    do {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output))
    } catch { fputs("Live check output failed: \(error)\n", stderr) }
    model.close { _ in NSApp.terminate(nil) }
  }
  func restoreTrashedFixtures() throws {
    while let (original, trashed) = trashReceipts.last {
      try FileManager.default.moveItem(at: trashed, to: original)
      trashReceipts.removeLast()
    }
  }
}
