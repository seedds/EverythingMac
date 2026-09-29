import AppKit

// Measures how long real visible cells retain Loading… after scrolling a saved index.
final class ScrollCheck {
  let model: Model
  weak var window: NSWindow?
  let output: String
  var timer: Timer?
  var started = ProcessInfo.processInfo.systemUptime
  var pending = false
  var step = 0
  var samples: [Double] = []
  var fractions = [0.1, 0.9, 0.5, 0.99, 0.25, 0.0]

  init(model: Model, window: NSWindow, output: String) {
    self.model = model
    self.window = window
    self.output = output
    let args = CommandLine.arguments
    if args.contains("--scroll-stress") {
      let seed = args.firstIndex(of: "--scroll-seed").flatMap {
        args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil
      } ?? 1049
      fractions = (0..<60).map { Double(($0 * 7919 + seed) % 10000) / 10000 }
    }
    if let index = args.firstIndex(of: "--scroll-query"), args.indices.contains(index + 1) {
      model.query = args[index + 1]
    }
  }

  func table(in view: NSView?) -> ResultsView? {
    if let table = view as? ResultsView { return table }
    return (view?.subviews ?? []).lazy.compactMap { self.table(in: $0) }.first
  }

  func start() {
    timer = Timer(timeInterval: 0.005, repeats: true) { [weak self] _ in self?.tick() }
    RunLoop.main.add(timer!, forMode: .common)
  }

  func tick() {
    let now = ProcessInfo.processInfo.systemUptime
    if now - started > 30 { finish("Visible rows did not finish loading within 30 seconds"); return }
    guard model.ready, !model.searching, model.pendingDraw == nil,
      let table = table(in: window?.contentView) else { return }
    guard model.total > 10000 else { finish("Use an index with at least 10,000 results"); return }
    if !pending {
      if step == fractions.count {
        finish(samples.max()! > 250 ? "Visible rows took longer than 250 ms to load" : nil)
        return
      }
      started = now
      pending = true
      table.scrollRowToVisible(Int(Double(model.total - 40) * fractions[step]))
      table.layoutSubtreeIfNeeded()
      table.displayIfNeeded()
      return
    }
    let range = table.rows(in: table.visibleRect)
    guard range.location != NSNotFound, range.length > 0 else { return }
    for row in range.location..<min(NSMaxRange(range), model.total) {
      guard let item = model.rows[row],
        let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ResultCell,
        cell.representedPath == item.path,
        cell.toolTip == nil,
        cell.textField?.stringValue == (item.path as NSString).lastPathComponent
      else { return }
    }
    samples.append((now - started) * 1000)
    pending = false
    step += 1
  }

  func finish(_ error: String?) {
    timer?.invalidate()
    let report: [String: Any] = [
      "results": model.total, "visibleRowsReadyMS": samples,
      "error": error as Any? ?? NSNull(),
    ]
    do {
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output))
    } catch { fputs("Scroll-check report failed: \(error)\n", stderr) }
    model.close()
    NSApp.terminate(nil)
  }
}
