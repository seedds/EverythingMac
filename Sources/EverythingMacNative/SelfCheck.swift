import AppKit
import Darwin

// Runs against the disposable fixture produced by bridge/examples/fixture.rs.
// Uses the real Model, engine queue and rendered table; failures are recorded.
final class SelfCheck {
  let model: Model
  let output: String
  var timer: Timer?
  var step = -1
  var checks: [String] = []
  var started = ProcessInfo.processInfo.systemUptime
  let snapshot: String
  init(model: Model, output: String) {
    self.model = model
    self.output = output
    snapshot = model.snapshot
  }
  func start() {
    timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
      self?.tick()
    }
  }
  func tick() {
    if ProcessInfo.processInfo.systemUptime - started > 15 {
      finish("Timed out at step \(step): \(model.status)")
      return
    }
    if step == -1 {
      if model.ready && !model.searching && model.pendingDraw == nil { next() }
      return
    }
    if step == 6 {
      guard model.error != nil else { return }
      checks.append("Invalid query reports an error and retains previous results")
      next()
      return
    }
    if step == 7 {
      guard model.error != nil, !model.ready else { return }
      checks.append("Missing snapshot reports an error without scanning")
      next()
      return
    }
    guard model.ready, !model.searching, model.pendingDraw == nil, model.error == nil else {
      return
    }
    if let error = renderedRowError() {
      finish(error)
      return
    }
    switch step {
    case 0:
      guard model.total == 2 else {
        finish("Case-insensitive count \(model.total), expected 2")
        return
      }
      checks.append("Case-insensitive search")
    case 1:
      guard model.rows[0]?.metadata_loaded == true else { return }
      guard model.total == 1, model.rows[0]?.path.hasSuffix("alpha.md") == true else {
        finish("Case-sensitive result mismatch")
        return
      }
      guard model.rows[0]?.size == 1, model.rows[0]?.modified != nil,
        model.rows[0]?.created != nil else {
        finish("Asynchronous visible-row metadata did not load")
        return
      }
      checks.append("Case-sensitive search and asynchronous file metadata")
    case 2:
      guard model.total == 1, model.rows[0]?.path.hasSuffix("résumé.txt") == true else {
        finish("Directory/Unicode result mismatch")
        return
      }
      checks.append("Directory filtering and Unicode")
    case 3:
      guard model.total == 0 else {
        finish("No-match search returned rows")
        return
      }
      checks.append("Empty result state")
    case 4:
      guard model.total == 1, model.rows[0]?.path.hasSuffix("résumé.txt") == true else {
        finish("Cancelled query replaced latest query")
        return
      }
      checks.append("Rapid query replacement rejects cancelled responses")
    case 5:
      guard model.rows[0]?.metadata_loaded == true else { return }
      guard model.total == 1, model.rows[0]?.size == nil else {
        finish("Missing file metadata mismatch")
        return
      }
      checks.append("Deleted file remains searchable with unavailable metadata")
    case 8:
      checks.append("Reopen after load failure; empty query renders snapshot")
    case 9:
      guard let row = model.rows[0], row.metadata_loaded else { return }
      var info = stat()
      guard model.total == 1, row.path.hasSuffix("sparse.raw"),
        lstat(row.path, &info) == 0, row.size == 1 << 30,
        row.allocated_size == Int64(info.st_blocks) * 512,
        (row.allocated_size ?? Int64.max) < row.size! else {
        finish("Sparse file size on disk does not match allocated blocks"); return
      }
      checks.append("Sparse file displays allocated bytes while retaining logical size")
      model.query = "alpha"
      model.submit()
      model.close()
      checks.append("Close with queued search")
      finish(nil)
      return
    default: break
    }
    next()
  }
  func renderedRowError() -> String? {
    func findTable(_ view: NSView) -> ResultsView? {
      if let table = view as? ResultsView { return table }
      return view.subviews.lazy.compactMap { findTable($0) }.first
    }
    guard let content = NSApp.windows.first(where: { $0.identifier?.rawValue == "EverythingMacSearch" })?.contentView,
      let table = findTable(content)
    else { return "Rendered results table missing" }
    guard table.numberOfRows == model.total else { return "Stale table row count" }
    guard model.total > 0, let row = model.rows[0] else { return nil }
    guard let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? ResultCell,
      cell.textField?.stringValue == URL(fileURLWithPath: row.path).lastPathComponent,
      cell.representedPath == row.path, cell.toolTip == nil
    else { return "Rendered filename belongs to an older query" }
    if step == 9, row.metadata_loaded {
      guard let column = table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "Size" }),
        table.tableColumns[column].title == "Size",
        let sizeCell = table.view(atColumn: column, row: 0, makeIfNecessary: false) as? NSTableCellView,
        let bytes = row.allocated_size,
        sizeCell.textField?.stringValue == ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
      else { return "Size column does not render allocated bytes" }
    }
    return nil
  }
  func next() {
    step += 1
    started = ProcessInfo.processInfo.systemUptime
    switch step {
    case 0: model.query = "alpha"
    case 1: model.sensitive = true
    case 2:
      model.sensitive = false
      model.directory = "docs"
      model.query = "résumé"
    case 3:
      model.directory = ""
      model.query = "no-such-name-934fd"
    case 4:
      model.query = "alpha"
      model.submit()
      model.query = "résumé"
      model.changed()
    case 5: model.query = "missing.txt"
    case 6: model.query = "regex:["
    case 7:
      model.snapshot = snapshot + ".missing"
      model.load()
      return
    case 8:
      model.snapshot = snapshot
      model.query = ""
      model.load()
      return
    case 9: model.query = "sparse.raw"
    default:
      finish("Unknown test step")
      return
    }
    // Allow SwiftUI changes to cancel the scheduled debounce, then submit.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.model.submit() }
  }
  func finish(_ error: String?) {
    timer?.invalidate()
    let report: [String: Any] = ["checks": checks, "error": error as Any? ?? NSNull()]
    do {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output))
    } catch { fputs("Self-check report failed: \(error)\n", stderr) }
    model.close()
    NSApp.terminate(nil)
  }
}
