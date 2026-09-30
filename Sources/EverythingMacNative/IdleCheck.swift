import AppKit

/// Measures what the app costs while files change and nobody is typing, with the
/// search window shown and then hidden, and what each Down Arrow in the results
/// costs: `--idle-check REPORT INDEX`. Loads a copy of the index with the saved
/// scope; preferences and the saved index are not changed.
final class IdleCheck {
  let model: Model
  weak var window: NSWindow?
  let output: String
  let index: String
  let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("everything-mac-idle-" + UUID().uuidString, isDirectory: true)
  /// Files written here stand in for the changes a Mac makes all the time. The index
  /// copy lives in a sibling folder: events under its own folder are ignored.
  var churnFolder: URL { directory.appendingPathComponent("churn", isDirectory: true) }
  let keyCount = 100
  let period = 30.0
  var timer: Timer?
  var churn: DispatchSourceTimer?
  var stage = 0
  var deadline = ProcessInfo.processInfo.systemUptime + 120
  var loadedEntries = 0
  var loadedAt = 0.0
  var ticket: UInt64 = 0
  var keys = 0
  var keyPressed = 0.0
  var keyMS: [Double] = []
  var baseline = Usage()
  var shownAt = 0.0
  var shownGeneration: UInt64 = 0
  var report: [String: Any] = [:]

  struct Usage {
    var uptime = ProcessInfo.processInfo.systemUptime
    /// Main-thread CPU: SwiftUI, AppKit drawing, and reply handling.
    var main = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    /// Every thread, including searches and event processing on the engine queue.
    var process = clock_gettime_nsec_np(CLOCK_PROCESS_CPUTIME_ID)
    var generation: UInt64 = 0
  }

  init(model: Model, window: NSWindow, output: String, index: String) {
    self.model = model
    self.window = window
    self.output = output
    self.index = index
  }

  func table(in view: NSView?) -> ResultsView? {
    if let table = view as? ResultsView { return table }
    return (view?.subviews ?? []).lazy.compactMap { self.table(in: $0) }.first
  }

  func start() {
    do {
      let state = directory.appendingPathComponent("state", isDirectory: true)
      try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: churnFolder, withIntermediateDirectories: true)
      let copy = state.appendingPathComponent("loaded.db")
      try FileManager.default.copyItem(at: URL(fileURLWithPath: index), to: copy)
      let saved = Preferences(isolated: false)
      model.prefs.root = saved.root
      model.prefs.ignores = saved.ignores
      model.prefs.includes = saved.includes
      model.prefs.patterns = saved.patterns
      model.snapshotOnly = false
      model.live = true
      model.checkpointPath = state.appendingPathComponent("snapshot.db").path
      model.snapshot = copy.path
      model.load()
      startTicking()
    } catch { finish(error.localizedDescription) }
  }

  func startTicking() {
    timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(timer!, forMode: .common)
  }

  func usage() -> Usage {
    var value = Usage()
    value.generation = model.generation
    return value
  }

  func measurement(since start: Usage) -> [String: Any] {
    let end = usage()
    return [
      "seconds": end.uptime - start.uptime,
      "mainCPUMS": Double(end.main - start.main) / 1e6,
      "processCPUMS": Double(end.process - start.process) / 1e6,
      "searches": end.generation - start.generation,
    ]
  }

  func pressDown() {
    guard let window = window,
      let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
        charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125)
    else { finish("Cannot create a Down Arrow event"); return }
    keyPressed = ProcessInfo.processInfo.systemUptime
    window.sendEvent(event)
  }

  func startChurn() {
    let folder = churnFolder
    var count = 0
    let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    source.schedule(deadline: .now(), repeating: 0.25)
    source.setEventHandler {
      let file = folder.appendingPathComponent("churn-\(count).txt")
      try? Data("change".utf8).write(to: file)
      if count > 0 {
        try? FileManager.default.removeItem(
          at: folder.appendingPathComponent("churn-\(count - 1).txt"))
      }
      count += 1
    }
    source.resume()
    churn = source
  }

  /// Idle periods run without the check's own timer, which would add main-thread work.
  func measurePeriod(_ name: String, then next: @escaping () -> Void) {
    timer?.invalidate()
    timer = nil
    baseline = usage()
    DispatchQueue.main.asyncAfter(deadline: .now() + period) { [self] in
      report[name] = measurement(since: baseline)
      next()
    }
  }

  func tick() {
    let now = ProcessInfo.processInfo.systemUptime
    guard now < deadline else { finish("Timed out at stage \(stage): \(model.status)"); return }
    if let error = model.error { finish(error); return }
    switch stage {
    case 0:
      guard model.ready, !model.searching, !model.scanning, model.pendingDraw == nil else { return }
      if loadedEntries == 0 {
        loadedEntries = model.indexedCount
        loadedAt = now
      }
      // The first poll removes other volumes' items from indexes saved before 0.1.66.
      guard model.indexedCount < loadedEntries || now - loadedAt > 5 else { return }
      report["entries"] = model.indexedCount
      model.query = ""
      stage = 1
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [self] in
        model.submit()
        ticket = model.generation
      }
    case 1:
      guard ticket != 0, model.displayedGeneration == ticket, !model.searching,
        model.pendingDraw == nil, let table = table(in: window?.contentView)
      else { return }
      // Arrow keys are measured without live polls in between.
      model.timer?.invalidate()
      window?.makeFirstResponder(table)
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
      stage = 2
    case 2:
      guard !model.selectionLoading, model.selectionCount == 1 else { return }
      baseline = usage()
      stage = 3
      pressDown()
    case 3:
      guard !model.selectionLoading, model.selectionCount == 1,
        table(in: window?.contentView)?.selectedRow == keys + 1
      else { return }
      keyMS.append((now - keyPressed) * 1000)
      keys += 1
      guard keys == keyCount else { pressDown(); return }
      var keysReport = measurement(since: baseline)
      keysReport["keys"] = keys
      keysReport["latencyMS"] = summary(keyMS)
      report["arrowKeys"] = keysReport
      model.startTimer()
      startChurn()
      stage = 4
      measurePeriod("visible") { [self] in
        window?.orderOut(nil)
        measurePeriod("hidden") { [self] in
          churn?.cancel()
          churn = nil
          shownGeneration = model.displayedGeneration
          shownAt = ProcessInfo.processInfo.systemUptime
          window?.makeKeyAndOrderFront(nil)
          stage = 5
          deadline = shownAt + 10
          startTicking()
        }
      }
    case 5:
      guard now - shownAt < 5 else {
        report["showRefreshMS"] = NSNull()
        finish(nil)
        return
      }
      guard model.displayedGeneration != shownGeneration, !model.searching,
        model.pendingDraw == nil
      else { return }
      report["showRefreshMS"] = (now - shownAt) * 1000
      finish(nil)
    default: break
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
    churn?.cancel()
    churn = nil
    report["error"] = error as Any? ?? NSNull()
    do {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output, isDirectory: false))
    } catch { fputs("Idle-check report failed: \(error)\n", stderr) }
    let directory = self.directory
    model.close { _ in
      try? FileManager.default.removeItem(at: directory)
      NSApp.terminate(nil)
    }
  }
}
