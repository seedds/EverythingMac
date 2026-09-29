import AppKit
import CNative

// First draw and inter-draw intervals are proxies, not measured display scanout.
final class Benchmark {
  let model: Model
  weak var window: NSWindow?
  let output: String
  let queries = ["EE.en", "everything-mac", "package.json", "a"]
  var samples: [Sample] = []
  struct TypingSample: Encodable {
    let debounceMS: Int
    let sample: Sample
  }
  var typingSamples: [TypingSample] = []
  var iteration = -1
  var timer: Timer?
  var started = 0.0
  init(model: Model, window: NSWindow, output: String) {
    self.model = model
    self.window = window
    self.output = output
  }
  func start() {
    started = ProcessInfo.processInfo.systemUptime
    model.onDraw = { [weak self] sample in self?.advance(sample) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
      guard let self = self else { return }
      self.finish(error: "Benchmark timed out: \(self.model.error ?? self.model.status)")
    }
  }
  func advance(_ sample: Sample) {
    if iteration >= 0 && iteration % 23 >= 3 { samples.append(sample) }
    iteration += 1
    if iteration >= queries.count * 23 {
      typing()
      return
    }
    let query = queries[iteration / 23]
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
      guard let self = self else { return }
      self.model.query = query
      // Let SwiftUI's onChange run, then use the same immediate submit as Enter.
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
        self.model.inputAt = ProcessInfo.processInfo.systemUptime
        self.model.submit()
      }
    }
  }
  func typing() {
    var step = 0
    func next() {
      if step >= 36 {
        scroll()
        return
      }
      model.debounce = [0, 100, 300][step / 12]
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
        self?.model.query = step % 2 == 0 ? "everything-mac" : "package.json"
      }
    }
    model.onDraw = { [weak self] sample in
      guard let self = self else { return }
      if step % 12 >= 2 {
        self.typingSamples.append(TypingSample(debounceMS: self.model.debounce, sample: sample))
      }
      step += 1
      next()
    }
    next()
  }
  func table(in view: NSView?) -> ResultsView? {
    if let table = view as? ResultsView { return table }
    for child in view?.subviews ?? [] { if let result = table(in: child) { return result } }
    return nil
  }
  func scroll() {
    model.onDraw = nil
    guard let table = table(in: window?.contentView) else {
      finish(error: "Table missing")
      return
    }
    table.frameTimes.removeAll()
    table.previousDraw = 0
    table.recordDrawIntervals = true
    var tick = 0
    timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) {
      [weak self, weak table] timer in
      guard let self = self, let table = table else {
        timer.invalidate()
        return
      }
      tick += 1
      table.scrollRowToVisible(min(self.model.total - 1, tick * 12))
      table.needsDisplay = true
      if tick >= 180 {
        timer.invalidate()
        self.finish(error: nil)
      }
    }
  }
  func finish(error: String?) {
    timer?.invalidate()
    table(in: window?.contentView)?.recordDrawIntervals = false
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    struct Report: Encodable {
      let snapshot: String
      let snapshotDate: String
      let loadMS: Double
      let samples: [Sample]
      let typingSamples: [TypingSample]
      let scrollDrawIntervalsMS: [Double]
      let error: String?
      let os: String
      let processors: Int
    }
    let report = Report(
      snapshot: model.snapshot, snapshotDate: model.snapshotDate, loadMS: model.loadedMS,
      samples: samples, typingSamples: typingSamples,
      scrollDrawIntervalsMS: table(in: window?.contentView)?.frameTimes ?? [],
      error: error, os: ProcessInfo.processInfo.operatingSystemVersionString,
      processors: ProcessInfo.processInfo.processorCount)
    do {
      try encoder.encode(report).write(to: URL(fileURLWithPath: output))
      print("Benchmark saved: \(output)")
    } catch { fputs("Cannot write benchmark: \(error)\n", stderr) }
    model.close()
    NSApp.terminate(nil)
  }
}

// Runs the exact linked bridge without a window to isolate engine/FFI overhead.
enum Probe {
  static func run() {
    let args = CommandLine.arguments
    let path =
      args.firstIndex(of: "--index").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
      ?? Preferences.snapshotIndex
    var engine: OpaquePointer?
    do {
      let loaded = try path.withCString { try decode(cn_engine_open($0, &engine)) }
      defer { cn_engine_close(engine) }
      print("load_ms,\(loaded.load_ms ?? 0),entries,\(loaded.total ?? 0)")
      if args.contains("--selection-probe") {
        let request = cn_request_new()
        let result = try "".withCString { q in
          try decode(cn_search(engine, request, 1, q, q, false))
        }
        cn_request_free(request)
        _ = try "[[0,1]]".withCString { r in
          try "null".withCString { p in try decode(cn_select(engine, 1, r, p)) }
        }
        var times: [Double] = []
        for _ in 0..<30 {
          let start = ProcessInfo.processInfo.systemUptime
          let selected = try decode(cn_selected(engine, 1, true))
          guard selected.paths?.count == 1 else {
            throw messageError("Single selection resolution failed")
          }
          times.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        times.sort()
        print("selection_results,\(result.total ?? 0),median_ms,\(times[15]),p95_ms,\(times[28])")
        return
      }
      print("query,iteration,results,backend_ms,bridge_and_first_page_ms")
      for query in ["EE.en", "everything-mac", "package.json", "a"] {
        for iteration in 0..<23 {
          let request = cn_request_new()
          let start = ProcessInfo.processInfo.systemUptime
          let response = try query.withCString { q in
            try "".withCString { d in
              try decode(cn_search(engine, request, UInt64(iteration + 1), q, d, false))
            }
          }
          cn_request_free(request)
          _ = try decode(cn_rows(engine, UInt64(iteration + 1), 0, 128))
          let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
          if iteration >= 3 {
            print(
              "\(query),\(iteration-3),\(response.total ?? 0),\(response.search_ms ?? 0),\(elapsed)"
            )
          }
        }
      }
    } catch {
      fputs("Probe failed: \(error.localizedDescription)\n", stderr)
      exit(1)
    }
  }
}
