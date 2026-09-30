import AppKit

/// Loads a copy of a saved index with the saved scope, rescans it, and measures
/// searches and row loads while the rescan runs:
/// `--rescan-check REPORT INDEX`. Preferences and the index copy stay isolated.
final class RescanCheck {
  enum Waiting { case typing, search, page }
  let model: Model
  let output: String
  let index: String
  let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("everything-mac-rescan-" + UUID().uuidString, isDirectory: true)
  let queries = ["Info.plist", "readme", ".png", "config", "a"]
  var timer: Timer?
  var stage = 0
  var waiting = Waiting.search
  var deadline = ProcessInfo.processInfo.systemUptime + 60
  var loadedEntries = 0
  var loadedAt = 0.0
  var prunedEntries = 0
  var scanStarted = 0.0
  var rescanMS = 0.0
  var rescannedEntries = 0
  var ticket: UInt64 = 0
  var submitted = 0.0
  var queryIndex = 0
  var searchMS: [Double] = []
  var idleSearchMS: [Double] = []
  var pageRow = 0
  var pageMS: [Double] = []

  init(model: Model, output: String, index: String) {
    self.model = model
    self.output = output
    self.index = index
  }

  func start() {
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let copy = directory.appendingPathComponent("loaded.db")
      try FileManager.default.copyItem(at: URL(fileURLWithPath: index), to: copy)
      let saved = Preferences(isolated: false)
      model.prefs.root = saved.root
      model.prefs.ignores = saved.ignores
      model.prefs.includes = saved.includes
      model.prefs.patterns = saved.patterns
      model.snapshotOnly = false
      model.live = true
      model.checkpointPath = directory.appendingPathComponent("snapshot.db").path
      model.snapshot = copy.path
      model.load()
      timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in self?.tick() }
      RunLoop.main.add(timer!, forMode: .common)
    } catch { finish(error.localizedDescription) }
  }

  func search() {
    model.query = queries[queryIndex % queries.count]
    queryIndex += 1
    waiting = .typing
    // Let SwiftUI's onChange run, then submit immediately as Enter does.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [self] in
      model.submit()
      ticket = model.generation
      submitted = ProcessInfo.processInfo.systemUptime
      waiting = .search
    }
  }

  func tick() {
    let now = ProcessInfo.processInfo.systemUptime
    guard now < deadline else { finish("Timed out at stage \(stage): \(model.status)"); return }
    if let error = model.error { finish(error); return }
    if stage == 0 {
      guard model.ready, !model.searching, !model.scanning, model.pendingDraw == nil else { return }
      if loadedEntries == 0 {
        loadedEntries = model.indexedCount
        loadedAt = now
      }
      // The first poll removes other volumes' items from indexes saved before 0.1.66.
      guard model.indexedCount < loadedEntries || now - loadedAt > 5 else { return }
      prunedEntries = model.indexedCount
      stage = 1
      search()
    } else if stage == 1 {
      // The same searches without a rescan, for comparison.
      guard waiting == .search, model.displayedGeneration == ticket, !model.searching,
        model.pendingDraw == nil else { return }
      idleSearchMS.append((now - submitted) * 1000)
      guard idleSearchMS.count == 25 else { search(); return }
      stage = 2
      deadline = now + 900
      scanStarted = now
      model.scan(useCurrentConfig: true)
      search()
    } else if stage == 2 {
      guard model.scanning else {
        rescanMS = (now - scanStarted) * 1000
        stage = 3
        return
      }
      switch waiting {
      case .typing: return
      case .search:
        guard model.displayedGeneration == ticket, !model.searching, model.pendingDraw == nil
        else { return }
        searchMS.append((now - submitted) * 1000)
        guard model.total > 128 else { search(); return }
        // A page far from the top loads from the index while it is rescanned.
        pageRow = min(model.total - 1, 20_000)
        submitted = now
        waiting = .page
        model.ensure(pageRow)
      case .page:
        guard model.rows[pageRow] != nil else { return }
        pageMS.append((now - submitted) * 1000)
        search()
      }
    } else if stage == 3 {
      guard model.ready, !model.searching, !model.scanning, model.pendingDraw == nil else { return }
      rescannedEntries = model.indexedCount
      finish(searchMS.isEmpty ? "No search finished during the rescan" : nil)
    }
  }

  func summary(_ values: [Double]) -> [String: Double] {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return [:] }
    return [
      "median": sorted[sorted.count / 2], "p90": sorted[sorted.count * 9 / 10],
      "max": sorted[sorted.count - 1],
    ]
  }

  func finish(_ error: String?) {
    timer?.invalidate()
    timer = nil
    let report: [String: Any] = [
      "loadedEntries": loadedEntries, "entriesAfterFirstPoll": prunedEntries,
      "rescannedEntries": rescannedEntries, "rescanMS": rescanMS,
      "searchesDuringRescan": searchMS.count, "searchMS": summary(searchMS),
      "idleSearchMS": summary(idleSearchMS),
      "pageLoadsDuringRescan": pageMS.count, "pageMS": summary(pageMS),
      "error": error as Any? ?? NSNull(),
    ]
    do {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output, isDirectory: false))
    } catch { fputs("Rescan-check report failed: \(error)\n", stderr) }
    let directory = self.directory
    model.close { _ in
      try? FileManager.default.removeItem(at: directory)
      NSApp.terminate(nil)
    }
  }
}
