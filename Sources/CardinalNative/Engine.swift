import AppKit
import CNative
import Foundation

struct Row: Decodable {
  let index: Int
  let id: UInt32
  let path: String
  let size: Int64?
  let modified: UInt32?
  let created: UInt32?
  let is_directory: Bool
  let metadata_loaded: Bool
}

struct Reply: Decodable {
  let status: String
  let error: String?
  let total: Int?
  let generation: UInt64?
  let load_ms: Double?
  let search_ms: Double?
  let skipped_cloud_files: Int?
  let rows: [Row]?
  let root: String?
  let ignores: [String]?
  let includes: [String]?
  let changed: Bool?
  let needs_rescan: Bool?
  let processed_events: UInt64?
  let events: [FileEvent]?
  let paths: [String]?
  let indices: [Int]?
  let highlights: [String]?
  let selection_count: Int?
  let ranges: [[Int]]?
}

func decode(_ buffer: CNBuffer) throws -> Reply {
  defer { cn_buffer_free(buffer) }
  let reply = try JSONDecoder().decode(
    Reply.self, from: Data(bytes: buffer.data!, count: buffer.len))
  if reply.status == "error" {
    throw NSError(
      domain: "CardinalNative", code: 1,
      userInfo: [NSLocalizedDescriptionKey: reply.error ?? "Unknown engine error"])
  }
  return reply
}

// All handle access, including destruction, belongs to this serial queue.
final class Engine {
  let queue = DispatchQueue(label: "cardinal.native.engine", qos: .userInitiated)
  private var handle: OpaquePointer?
  func perform(
    _ operation: @escaping (OpaquePointer?) throws -> Reply,
    completion: @escaping (Result<Reply, Error>) -> Void
  ) {
    queue.async {
      let result = Result { try operation(self.handle) }
      DispatchQueue.main.async { completion(result) }
    }
  }
  func scan(
    root: String, ignores: [String], includes: [String],
    completion: @escaping (Result<Reply, Error>) -> Void
  ) {
    cn_cancel()
    cn_cancel_scan()
    let request = SearchRequest(scan: true)
    queue.async {
      let result = Result { () throws -> Reply in
        var replacement: OpaquePointer?
        defer { cn_engine_close(replacement) }
        let reply = try root.withCString { r in
          try jsonString(ignores).withCString { i in
            try jsonString(includes).withCString { n in
              try decode(cn_scan(r, i, n, request.pointer, &replacement))
            }
          }
        }
        if reply.status == "ok" {
          _ = try decode(cn_transfer_selection(self.handle, replacement))
          cn_engine_close(self.handle)
          self.handle = replacement
          replacement = nil
        }
        return reply
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  func open(_ path: String, completion: @escaping (Result<Reply, Error>) -> Void) {
    cn_cancel()
    cn_cancel_scan()
    queue.async {
      cn_engine_close(self.handle)
      self.handle = nil
      let result = Result { try path.withCString { try decode(cn_engine_open($0, &self.handle)) } }
      DispatchQueue.main.async { completion(result) }
    }
  }

  func search(
    query: String, directory: String, sensitive: Bool, generation: UInt64,
    submitted: Double, firstRow: Int = 0, sort: String = "null", sortLimit: Int = 20000,
    completion: @escaping (Result<(Reply, [Row], Double), Error>) -> Void
  ) {
    let request = SearchRequest()
    queue.async {
      let result = Result { () throws -> (Reply, [Row], Double) in
        _ = try sort.withCString { try decode(cn_sort(self.handle, $0, sortLimit)) }
        let reply = try query.withCString { q in
          try directory.withCString { d in
            try decode(cn_search(self.handle, request.pointer, generation, q, d, sensitive))
          }
        }
        let rows =
          reply.status == "ok"
          ? try decode(cn_rows(self.handle, generation, firstRow, 128)).rows ?? [] : []
        return (reply, rows, ProcessInfo.processInfo.systemUptime - submitted)
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  func rows(generation: UInt64, start: Int, completion: @escaping ([Row]) -> Void) {
    queue.async {
      let rows = (try? decode(cn_rows(self.handle, generation, start, 128)))?.rows ?? []
      DispatchQueue.main.async { completion(rows) }
    }
  }

  func close(save: Bool = false, completion: @escaping (Error?) -> Void = { _ in }) {
    cn_cancel()
    cn_cancel_scan()
    queue.async {
      var error: Error?
      if save && self.handle != nil {
        do { _ = try decode(cn_checkpoint(self.handle)) } catch let e { error = e }
      }
      cn_engine_close(self.handle)
      self.handle = nil
      DispatchQueue.main.async { completion(error) }
    }
  }

  deinit { cn_engine_close(handle) }
}

// Immutable ownership wrapper: only the queued search uses the pointer, and
// its capture keeps the token alive until the FFI call has returned.
private final class SearchRequest: @unchecked Sendable {
  let pointer: OpaquePointer
  init(scan: Bool = false) { pointer = scan ? cn_scan_request_new()! : cn_request_new()! }
  deinit { cn_request_free(pointer) }
}

struct Sample: Codable {
  let query: String
  let backendMS: Double
  let submissionToDrawMS: Double
  let inputToDrawMS: Double
  let rows: Int
}

final class Model: ObservableObject {
  @Published var query = ""
  @Published var directory = ""
  @Published var sensitive = false
  @Published var debounce = 100
  @Published var total = 0
  @Published var indexedCount = 0
  @Published var processedEventCount = 0
  @Published var status = "Choose or load a saved index."
  @Published var snapshot = NSString(
    string: "~/Library/Application Support/com.cardinal.one/cardinal.db"
  ).expandingTildeInPath
  @Published var snapshotDate = ""
  @Published var ready = false
  @Published var searching = false
  @Published var revision: UInt64 = 0
  @Published var error: String?
  let engine = Engine()
  lazy var actions = FileActions(self)
  @Published var hasFullDiskAccess = true
  @Published var shortcutMessage: String?
  let prefs: Preferences
  @Published var live = false
  @Published var scanning = false
  @Published var indexStatus = "Saved index"
  @Published var events: [FileEvent] = []
  @Published var eventFilter = ""
  @Published var activeTab = "files"
  @Published var preferencesOpen = false
  @Published var selectionLoading = false
  @Published var selectedPaths: [String] = []
  @Published var selectionCount = 0
  @Published var sortKey = ""
  @Published var sortAscending = true
  var snapshotOnly = true
  var checkpointPath = Preferences.index
  var root = ""
  var loadedIgnores: [String] = []
  var loadedIncludes: [String] = []
  var timer: Timer?
  var polling = false
  var saving = false
  var refreshPending = false
  var lastRefresh = 0.0
  var lastSave = ProcessInfo.processInfo.systemUptime
  var indexEpoch: UInt64 = 0
  var selectionEpoch: UInt64 = 0
  var restoredSelection: IndexSet?
  var backgroundResult = false
  var visibleStart = 0
  var tableAction: ((String) -> Void)?
  var focusSearch: (() -> Void)?
  var history: [String] = [""]
  var historyCursor = 0
  var navigatingHistory = false
  var closeCompletions: [(Error?) -> Void] = []
  var closeFinished = false
  init(prefs: Preferences = Preferences(isolated: true)) {
    self.prefs = prefs
    sortKey = prefs.sortKey
    sortAscending = prefs.sortAscending
  }
  var rows: [Int: Row] = [:]
  var highlights: [String] = []
  var displayedSensitive = false
  var generation: UInt64 = 0
  var displayedGeneration: UInt64 = 0
  var inputAt = 0.0
  var submittedAt = 0.0
  var backendMS = 0.0
  var lastSample: Sample?
  var pendingDraw: UInt64?
  var pendingPages = Set<Int>()
  let metadataQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "cardinal.native.row-metadata"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 2
    return queue
  }()
  var pendingMetadata: [Int: RowMetadataOperation] = [:]
  var debounceWork: DispatchWorkItem?
  var onDraw: ((Sample) -> Void)?
  var loadedMS = 0.0
  var closed = false

  func load() {
    debounceWork?.cancel()
    debounceWork = nil
    indexEpoch &+= 1
    let epoch = indexEpoch
    generation &+= 1
    ready = false
    searching = false
    selectionEpoch &+= 1
    selectionLoading = false
    selectedPaths = []
    selectionCount = 0
    pendingDraw = nil
    rows.removeAll()
    cancelMetadata()
    total = 0
    revision &+= 1
    status = "Loading snapshot…"
    error = nil
    let path = snapshot
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    snapshotDate = (attributes?[.modificationDate] as? Date)?.formatted() ?? "Unavailable"
    engine.open(path) { [weak self] result in
      guard let self = self, !self.closed, self.indexEpoch == epoch else { return }
      switch result {
      case .success(let reply):
        self.root = reply.root ?? self.prefs.root
        self.loadedIgnores = reply.ignores ?? []
        self.loadedIncludes = reply.includes ?? []
        self.loadedMS = reply.load_ms ?? 0
        self.indexedCount = reply.total ?? 0
        self.processedEventCount = 0
        self.ready = true
        if !self.snapshotOnly {
          self.setLive()
          self.startTimer()
          if self.scopeDiffersFromPreferences() {
            self.scan()
            return
          }
        }
        self.status = "Loaded \(reply.total ?? 0) indexed entries in \(Int(self.loadedMS)) ms"
        self.inputAt = ProcessInfo.processInfo.systemUptime
        self.submit()
      case .failure(let error):
        self.error =
          "Cannot load this snapshot: \(error.localizedDescription). Choose a compatible Cardinal index; no scan will be started."
        self.status = "Index unavailable"
      }
    }
  }

  func changed() {
    if navigatingHistory { navigatingHistory = false } else { historyEdited() }
    inputAt = ProcessInfo.processInfo.systemUptime
    debounceWork?.cancel()
    // Editing while opening an index must not invalidate the load reply.
    // Its completion will submit the newest field values.
    guard ready else { return }
    generation &+= 1  // reject replies immediately, including during debounce
    pendingDraw = nil
    cn_cancel()
    let work = DispatchWorkItem { [weak self] in self?.submit() }
    debounceWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(debounce), execute: work)
  }

  func submit(background: Bool = false) {
    guard ready, !closed else { return }
    debounceWork?.cancel()
    debounceWork = nil
    generation &+= 1
    let ticket = generation
    searching = true
    error = nil
    pendingDraw = nil
    submittedAt = ProcessInfo.processInfo.systemUptime
    if inputAt == 0 { inputAt = submittedAt }
    engine.search(
      query: query, directory: directory, sensitive: sensitive,
      generation: ticket, submitted: submittedAt,
      firstRow: background ? (visibleStart / 128) * 128 : 0,
      sort: sortKey.isEmpty
        ? "null" : jsonString(["key": sortKey, "direction": sortAscending ? "asc" : "desc"]),
      sortLimit: prefs.sortLimit
    ) { [weak self] result in
      guard let self = self, !self.closed, self.generation == ticket else { return }
      switch result {
      case .success(let (reply, rows, _)):
        guard reply.status == "ok" else { self.searching = false; return }
        self.finishSearch(reply, rows: rows, ticket: ticket, background: background)
      case .failure(let error):
        self.searching = false
        self.error = error.localizedDescription
        self.status = "Search failed; previous results retained"
      }
    }
  }

  // Keep the displayed rows and highlight together until remapping is complete.
  // A click while the search runs wins: reconcile after its queued selection write.
  func finishSearch(_ reply: Reply, rows: [Row], ticket: UInt64, background: Bool) {
    guard !closed, generation == ticket else { return }
    guard background else {
      publishSearch(reply, rows: rows, ticket: ticket, selection: nil)
      return
    }
    let epoch = selectionEpoch
    engine.perform({ try decode(cn_selected($0, ticket, false)) }) { [weak self] result in
      guard let self = self, !self.closed, self.generation == ticket else { return }
      guard self.selectionEpoch == epoch else {
        self.finishSearch(reply, rows: rows, ticket: ticket, background: true)
        return
      }
      switch result {
      case .success(let selection) where selection.status == "ok":
        self.publishSearch(reply, rows: rows, ticket: ticket, selection: selection)
      default:
        self.searching = false
        self.error = "Cannot restore selection; previous results retained."
      }
    }
  }

  private func publishSearch(_ reply: Reply, rows: [Row], ticket: UInt64, selection: Reply?) {
    searching = false
    selectionLoading = false
    backgroundResult = selection != nil
    restoredSelection = nil
    if let selection = selection {
      applyRestoredSelection(selection)
    } else {
      selectedPaths = []
      selectionCount = 0
      selectionEpoch &+= 1
      // A new user search clears both the UI and the retained backend identities,
      // so a later background refresh cannot resurrect the old selection.
      engine.perform({ handle in
        try "[]".withCString { empty in try decode(cn_select(handle, ticket, empty, empty)) }
      }) { _ in }
    }
    highlights = reply.highlights ?? []
    displayedSensitive = sensitive
    backendMS = reply.search_ms ?? 0
    total = reply.total ?? 0
    displayedGeneration = ticket
    cancelMetadata()
    self.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.index, $0) })
    pendingPages.removeAll()
    pendingDraw = ticket
    let skipped = reply.skipped_cloud_files ?? 0
    status = "\(total) results · Rust \(String(format: "%.1f", backendMS)) ms"
      + (skipped > 0 ? " · \(skipped) cloud files skipped" : "")
    revision &+= 1
    if selection != nil, selectionCount > 0, actions.preview.isVisible {
      resolveSelection { [weak self] in self?.actions.preview.update($0) }
    }
  }

  func ensure(_ index: Int) {
    guard index >= 0, index < total, rows[index] == nil, !searching, !closed else { return }
    let start = (index / 128) * 128
    guard !pendingPages.contains(start) else { return }
    pendingPages.insert(start)
    let ticket = displayedGeneration
    engine.rows(generation: ticket, start: start) { [weak self] loaded in
      guard let self = self, !self.closed, self.displayedGeneration == ticket else { return }
      self.pendingPages.remove(start)
      for row in loaded { self.rows[row.index] = row }
      // Keep at most 8 pages. Never allocate models for the full result set.
      if self.rows.count > 1024 {
        self.rows = self.rows.filter { abs($0.key - start) < 512 }
      }
      if !loaded.isEmpty { self.revision &+= 1 }
    }
  }

  func drew(_ drawnGeneration: UInt64) {
    guard pendingDraw == drawnGeneration, pendingDraw == displayedGeneration, pendingDraw != nil
    else { return }
    pendingDraw = nil
    let now = ProcessInfo.processInfo.systemUptime
    let sample = Sample(
      query: query, backendMS: backendMS,
      submissionToDrawMS: (now - submittedAt) * 1000,
      inputToDrawMS: (now - inputAt) * 1000, rows: total)
    lastSample = sample
    status += " · first draw \(String(format: "%.1f", sample.submissionToDrawMS)) ms"
    onDraw?(sample)
  }

  func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      snapshotOnly = true
      live = false
      timer?.invalidate()
      snapshot = url.path
      load()
    }
  }

  func close(completion: @escaping (Error?) -> Void = { _ in }) {
    if closeFinished {
      completion(nil)
      return
    }
    closeCompletions.append(completion)
    guard !closed else { return }
    closed = true
    cancelMetadata()
    timer?.invalidate()
    timer = nil
    debounceWork?.cancel()
    generation &+= 1
    engine.close(save: !snapshotOnly && ready && !scanning) { [weak self] error in
      guard let self = self else { return }
      self.closeFinished = true
      let completions = self.closeCompletions
      self.closeCompletions = []
      completions.forEach { $0(error) }
    }
  }
}
