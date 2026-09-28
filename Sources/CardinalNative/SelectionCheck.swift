import AppKit

// Observe the real selection between frames, throughout actual filesystem updates.
final class SelectionCheck {
  let model: Model
  weak var window: NSWindow?
  let output: String
  let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    .appendingPathComponent("cardinal-selection-" + UUID().uuidString, isDirectory: true)
  var timer: Timer?
  var stage = 0
  var cycle = 0
  var generation: UInt64 = 0
  var deadline = ProcessInfo.processInfo.systemUptime + 30
  var observedGaps = 0
  var observedCountGaps = 0
  var watchedSamples = 0
  var selectedPath = ""

  init(model: Model, window: NSWindow, output: String) {
    self.model = model
    self.window = window
    self.output = output
  }

  func table(in view: NSView?) -> ResultsView? {
    if let table = view as? ResultsView { return table }
    return (view?.subviews ?? []).lazy.compactMap { self.table(in: $0) }.first
  }

  func start() {
    do {
      let root = directory.appendingPathComponent("files", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try Data("selected".utf8).write(to: root.appendingPathComponent("middle.txt"))
      for i in 0..<3000 {
        try Data().write(to: root.appendingPathComponent(String(format: "z-%04d.txt", i)))
      }
      model.snapshotOnly = false
      model.live = true
      model.checkpointPath = directory.appendingPathComponent("snapshot.db").path
      model.prefs.root = root.resolvingSymlinksInPath().path
      model.prefs.ignores = ""
      model.prefs.includes = ""
      model.query = ".txt"
      model.sortKey = "filename"
      selectedPath = model.prefs.root + "/middle.txt"
      model.scan()
      timer = Timer(timeInterval: 0.001, repeats: true) { [weak self] _ in self?.tick() }
      RunLoop.main.add(timer!, forMode: .common)
    } catch { finish(error.localizedDescription) }
  }

  func tick() {
    guard ProcessInfo.processInfo.systemUptime < deadline else {
      finish("Timed out at stage \(stage): \(model.status); selection=\(model.selectionCount)"); return
    }
    guard let table = table(in: window?.contentView) else { return }
    if stage == 2 {
      watchedSamples += 1
      if table.selectedRowIndexes.isEmpty { observedGaps += 1 }
      if model.selectionCount != 1 { observedCountGaps += 1 }
    }
    guard model.ready, !model.searching, !model.scanning, !model.selectionLoading,
      model.pendingDraw == nil else { return }
    if let error = model.error { finish(error); return }
    if stage == 0 {
      selectedPath = model.root + "/middle.txt"
      guard let row = model.rows.values.first(where: { $0.path == selectedPath }) else { return }
      window?.makeFirstResponder(table)
      table.selectRowIndexes(IndexSet(integer: row.index), byExtendingSelection: false)
      stage = 1
    } else if stage == 1 {
      guard model.selectionCount == 1 else { return }
      mutate()
    } else if stage == 2 && model.displayedGeneration != generation {
      guard table.selectedRowIndexes.count == 1,
        let row = model.rows[table.selectedRow], row.path == selectedPath else { return }
      guard table.rowView(atRow: table.selectedRow, makeIfNecessary: false)?.isSelected == true
      else { finish("Rendered selected row lost its highlight"); return }
      cycle += 1
      if cycle == 3 {
        generation = model.displayedGeneration
        stage = 4
        deadline = ProcessInfo.processInfo.systemUptime + 15
        // A real click while the replacement search is queued must win.
        guard let other = model.rows.values.first(where: { $0.path.hasSuffix("/z-0000.txt") }) else {
          finish("Missing replacement-selection fixture"); return
        }
        selectedPath = other.path
        model.submit(background: true)
        table.selectRowIndexes(IndexSet(integer: other.index), byExtendingSelection: false)
      } else { mutate() }
    } else if stage == 4 && model.displayedGeneration != generation {
      guard model.selectedPaths == [selectedPath], model.rows[table.selectedRow]?.path == selectedPath
      else { finish("Background refresh replaced the user's newer selection"); return }
      cycle += 1
      generation = model.displayedGeneration
      stage = 3
      deadline = ProcessInfo.processInfo.systemUptime + 15
      do { try FileManager.default.removeItem(atPath: selectedPath) }
      catch { finish(error.localizedDescription) }
    } else if stage == 3 && model.displayedGeneration != generation {
      guard model.selectionCount == 0, model.selectedPaths.isEmpty, table.selectedRowIndexes.isEmpty
      else { finish("Deleted file remained selected or actionable"); return }
      cycle += 1
      stage = 5
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    } else if stage == 5 {
      guard model.selectionCount == 1 else { return }
      generation = model.displayedGeneration
      stage = 6
      model.submit()
    } else if stage == 6 && model.displayedGeneration != generation {
      guard model.selectionCount == 0, table.selectedRowIndexes.isEmpty else {
        finish("A new search retained the previous selection"); return
      }
      cycle += 1
      generation = model.displayedGeneration
      stage = 7
      model.submit(background: true)
    } else if stage == 7 && model.displayedGeneration != generation {
      guard model.selectionCount == 0, table.selectedRowIndexes.isEmpty else {
        finish("Background refresh resurrected a cleared selection"); return
      }
      cycle += 1
      finish(observedGaps == 0 && observedCountGaps == 0 ? nil
        : "Selection flickered: \(observedGaps) highlight gaps, \(observedCountGaps) count gaps")
    }
  }

  func mutate() {
    do {
      generation = model.displayedGeneration
      stage = 2
      deadline = ProcessInfo.processInfo.systemUptime + 15
      let added = URL(fileURLWithPath: model.root + "/aaa-added.txt", isDirectory: false)
      if cycle == 0 {
        try Data().write(to: added)
      } else if cycle == 1 {
        try Data("modified selected file".utf8).write(
          to: URL(fileURLWithPath: selectedPath, isDirectory: false))
      } else {
        try FileManager.default.removeItem(at: added)
      }
    } catch { finish(error.localizedDescription) }
  }

  func finish(_ error: String?) {
    timer?.invalidate()
    timer = nil
    let report: [String: Any] = [
      "completedUpdates": cycle, "observedSelectionGaps": observedGaps,
      "observedSelectionCountGaps": observedCountGaps,
      "watchedSamples": watchedSamples, "error": error as Any? ?? NSNull(),
    ]
    do {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output, isDirectory: false))
    } catch { fputs("Selection-check report failed: \(error)\n", stderr) }
    model.close { _ in NSApp.terminate(nil) }
  }
}
