import AppKit
import CNative
import Quartz
import SQLite3

// Real native window + Rust + FSEvents integration. Owns only disposable files.
final class LiveCheck {
  let model: Model
  let output: String
  let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
    "cardinal-live-" + UUID().uuidString)
  var root: URL { directory.appendingPathComponent("files") }
  var timer: Timer?
  var step = 0
  var since = ProcessInfo.processInfo.systemUptime
  var checks: [String] = []
  var pending = false
  var selectionBeforeSort: UInt64 = 0
  let terminalValidationError = "Choose an installed terminal application in Preferences."
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
      model.checkpointPath = directory.appendingPathComponent("native/cardinal.db").path
      model.prefs.root = root.resolvingSymlinksInPath().path
      model.prefs.ignores = model.prefs.root + "/ignored"
      model.prefs.includes = model.prefs.root + "/ignored/keep"
      model.query = "alpha"
      // Focused entry point for the terminal race, skipping unrelated UI checks.
      if CommandLine.arguments.contains("--terminal-check") {
        for i in 0..<1200 {
          try Data("terminal".utf8).write(to: root.appendingPathComponent("preview-item-\(i).txt"))
        }
        model.query = "preview-item"
        step = 20
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
    if ProcessInfo.processInfo.systemUptime - since > 25 {
      finish("Timeout at \(step): \(model.status); \(model.error ?? "")")
      return
    }
    guard model.ready, !model.searching, !model.scanning, model.pendingDraw == nil else { return }
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
    do {
      switch step {
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
        model.prefs.language = "zh-CN"
        Translation.load("zh-CN")
        guard tr("columns.filename", "Filename") != "Filename" else {
          finish("Translations were not bundled")
          return
        }
        Translation.load("en-US")
        for language in Translation.languages {
          Translation.load(language)
          guard tr("native.search", "MISSING") != "MISSING",
            tr("contextMenu.openItem", "MISSING") != "MISSING"
          else {
            finish("Missing translation for \(language)")
            return
          }
        }
        Translation.load("en-US")
        next("Bundled language resources")
        try checkMigration()
        next("Read-only legacy preferences migration")
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
          self.selectionBeforeSort = self.model.selectionEpoch
          self.model.sort(by: "filename")
          self.next("Large explicit selection resolves every path")
          self.pending = false
        }
      case 18:
        guard model.selectionEpoch > selectionBeforeSort, !model.selectionLoading else { return }
        guard model.actions.preview.urls.count == 1200 else { return }
        next("Quick Look retains all selected files after sort")
        model.activeTab = "events"
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
        model.timer?.invalidate()
        model.prefs.terminal = directory.appendingPathComponent("missing-terminal.app").path
        model.selectionChanged(IndexSet(integer: 0))
      case 21, 25:
        guard !model.selectionLoading, model.selectionCount == (step == 21 ? 1 : 1200) else {
          return
        }
        try Data("unrelated change".utf8).write(
          to: root.appendingPathComponent("terminal-event-\(step).txt"))
        step += 1
        since = ProcessInfo.processInfo.systemUptime
      case 22, 26:
        pollBeforeTerminalAction()
      case 24:
        guard model.total == 1200, !model.selectionLoading else { return }
        model.selectionChanged(IndexSet(integersIn: 0..<1200))
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
        self.model.actions.perform("terminal")
      }
    }
  }
  func checkMigration() throws {
    let directory = self.directory.appendingPathComponent("legacy/LocalStorage")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent("localstorage.sqlite3")
    var db: OpaquePointer?
    guard sqlite3_open(path.path, &db) == SQLITE_OK else {
      throw messageError("Migration fixture database failed")
    }
    let values = [
      "cardinal.watchRoot": root.path, "cardinal.theme": "dark", "cardinal.sortThreshold": "4321",
      "cardinal.ignorePaths": "[\"/tmp/ignored\"]",
    ]
    var sql = "CREATE TABLE ItemTable (key TEXT UNIQUE, value BLOB NOT NULL);"
    for (key, value) in values {
      let hex = value.data(using: .utf16LittleEndian)!.map { String(format: "%02x", $0) }.joined()
      sql += "INSERT INTO ItemTable VALUES ('\(key)',X'\(hex)');"
    }
    let status = sqlite3_exec(db, sql, nil, nil, nil)
    sqlite3_close(db)
    guard status == SQLITE_OK else { throw messageError("Migration fixture insert failed") }
    let before = try Data(contentsOf: path)
    let prefs = Preferences(isolated: true)
    prefs.importLegacy(directory: directory.path)
    guard prefs.root == root.path, prefs.theme == "dark", prefs.sortLimit == 4321,
      prefs.ignores == "/tmp/ignored", try Data(contentsOf: path) == before
    else { throw messageError("Preference import mismatch or source write") }
  }
  func finish(_ error: String?) {
    timer?.invalidate()
    timer = nil
    let report: [String: Any] = [
      "checks": checks, "error": error as Any? ?? NSNull(), "fixture": directory.path,
    ]
    do {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output))
    } catch { fputs("Live check output failed: \(error)\n", stderr) }
    model.close { _ in NSApp.terminate(nil) }
  }
}
