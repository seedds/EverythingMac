// Compile against the release bridge; see SORT-PERFORMANCE.md for reproduction.
// Opens a snapshot read-only, without watchers, preferences, or file actions.
import CNative
import Darwin
import Foundation

func reply(_ buffer: CNBuffer) throws -> [String: Any] {
  defer { cn_buffer_free(buffer) }
  let value = try JSONSerialization.jsonObject(with: Data(bytes: buffer.data!, count: buffer.len))
  guard let result = value as? [String: Any], result["status"] as? String == "ok" else {
    throw NSError(domain: "SortBenchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(value)"])
  }
  return result
}

func rss() -> UInt64 {
  var info = mach_task_basic_info()
  var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
  let status = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
    }
  }
  precondition(status == KERN_SUCCESS)
  return info.resident_size
}

func cpuMilliseconds() -> Double {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000
    + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
}

final class MemorySampler {
  private let lock = NSLock()
  private var peak: UInt64 = 0
  private var timer: DispatchSourceTimer?
  func start() {
    peak = rss()
    let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "sort-benchmark-memory"))
    source.schedule(deadline: .now(), repeating: .milliseconds(10))
    source.setEventHandler { [self] in
      let current = rss()
      lock.lock()
      peak = max(peak, current)
      lock.unlock()
    }
    timer = source
    source.resume()
  }
  func stop() -> UInt64 {
    timer?.cancel()
    lock.lock()
    defer { lock.unlock() }
    return max(peak, rss())
  }
}

do {
  let args = CommandLine.arguments
  guard args.count == 6 else {
    fputs("Usage: benchmark-sort INDEX QUERY KEY REPETITIONS OUTPUT.json\nKEY: filename/fullPath/size/mtime/ctime/none\n", stderr)
    exit(2)
  }
  let query = args[2], key = args[3], repetitions = Int(args[4])!
  precondition(repetitions > 0)
  var engine: OpaquePointer?
  let loadSampler = MemorySampler()
  loadSampler.start()
  let loadCPUStart = cpuMilliseconds()
  let loaded = try args[1].withCString { try reply(cn_engine_open($0, &engine)) }
  defer { cn_engine_close(engine) }
  let loadCPU = cpuMilliseconds() - loadCPUStart
  let loadPeakRSS = loadSampler.stop()
  let loadedRSS = rss()
  let descriptor = key == "none" ? "null" : "{\"key\":\"\(key)\",\"direction\":\"asc\"}"
  _ = try descriptor.withCString { try reply(cn_sort(engine, $0)) }
  var samples: [[String: Any]] = []
  func save() throws {
    let report: [String: Any] = [
      "query": query, "sort_key": key,
      "index_entries": loaded["total"]!, "load_ms": loaded["load_ms"]!,
      "loaded_rss_bytes": loadedRSS, "load_peak_rss_bytes": loadPeakRSS,
      "load_cpu_ms": loadCPU, "samples": samples,
    ]
    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      .write(to: URL(fileURLWithPath: args[5]), options: .atomic)
  }
  try save()
  for iteration in 0..<repetitions {
    let request = cn_request_new()
    let sampler = MemorySampler()
    let beforeRSS = rss()
    sampler.start()
    let cpuStart = cpuMilliseconds()
    let started = ProcessInfo.processInfo.systemUptime
    let result = try query.withCString { q in
      try "".withCString { directory in
        try reply(cn_search(engine, request, UInt64(iteration + 1), q, directory, false))
      }
    }
    let searchAndSortMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
    let rows = try reply(cn_rows(engine, UInt64(iteration + 1), 0, 128))
    let firstPageMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
    let cpuMS = cpuMilliseconds() - cpuStart
    let peakRSS = sampler.stop()
    cn_request_free(request)
    let total = result["total"] as! Int
    let rowValues = rows["rows"] as! [[String: Any]]
    precondition(rowValues.count == min(total, 128))
    samples.append([
      "iteration": iteration, "matches": total,
      "sort_applied": key != "none",
      "search_only_ms": result["search_ms"]!, "search_and_sort_ms": searchAndSortMS,
      "first_page_ms": firstPageMS, "cpu_ms": cpuMS,
      "rss_before_bytes": beforeRSS, "rss_peak_bytes": peakRSS, "rss_after_bytes": rss(),
      "first_page_metadata_loaded": rowValues.filter { $0["metadata_loaded"] as? Bool == true }.count,
    ])
    try save()
    fputs("\(query.isEmpty ? "<all>" : query) \(key) #\(iteration): \(total) matches, \(Int(firstPageMS)) ms\n", stderr)
  }
} catch {
  fputs("Sort benchmark failed: \(error)\n", stderr)
  exit(1)
}
