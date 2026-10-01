import AppKit
import CNative
import Foundation
import Observation

struct Row: Decodable, Equatable {
  let index: Int
  let id: UInt32
  let path: String
  let size: Int64?
  let allocated_size: Int64?
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
  let rows: [Row]?
  let root: String?
  let ignores: [String]?
  let includes: [String]?
  let exclusion_patterns: [String]?
  let changed: Bool?
  let needs_rescan: Bool?
  let metadata_changed: Bool?
  let watcher_stopped: Bool?
  let metadata_indexing: Bool?
  let walking: Bool?
  let applying: Bool?
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
      domain: "EverythingMacNative", code: 1,
      userInfo: [NSLocalizedDescriptionKey: reply.error ?? "Unknown engine error"])
  }
  return reply
}

// All handle access, including destruction, belongs to this serial queue.
final class Engine {
  let queue = DispatchQueue(label: "everything.mac.engine", qos: .userInitiated)
  // Scans build a separate index, so the current one stays searchable meanwhile.
  private let scanQueue = DispatchQueue(label: "everything.mac.scan", qos: .userInitiated)
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
    root: String, ignores: [String], includes: [String], patterns: [String] = [],
    progress: @escaping (Int) -> Void = { _ in },
    completion: @escaping (Result<Reply, Error>) -> Void
  ) {
    cn_cancel_scan()
    let request = SearchRequest(scan: true)
    let progressTimer = DispatchSource.makeTimerSource(queue: .main)
    progressTimer.schedule(deadline: .now(), repeating: .milliseconds(200))
    progressTimer.setEventHandler { progress(Int(cn_scan_count(request.pointer))) }
    progressTimer.resume()
    scanQueue.async {
      let replacement = ScannedIndex()
      let scanned = Result { () throws -> Reply in
        try root.withCString { r in
          try jsonString(ignores).withCString { i in
            try jsonString(includes).withCString { n in
              try jsonString(patterns).withCString { p in
                try decode(cn_scan(r, i, n, p, request.pointer, &replacement.handle))
              }
            }
          }
        }
      }
      self.queue.async {
        defer { cn_engine_close(replacement.handle) }
        let result = Result { () throws -> Reply in
          let reply = try scanned.get()
          guard reply.status == "ok" else { return reply }
          // Opening or closing an index, or Cancel Scan, discards a finished scan.
          guard cn_scan_current(request.pointer) else {
            return try JSONDecoder().decode(Reply.self, from: Data(#"{"status":"cancelled"}"#.utf8))
          }
          _ = try decode(cn_transfer_selection(self.handle, replacement.handle))
          cn_engine_close(self.handle)
          self.handle = replacement.handle
          replacement.handle = nil
          return reply
        }
        DispatchQueue.main.async {
          progressTimer.cancel()
          completion(result)
        }
      }
    }
  }

  /// With `keepCurrent`, the loaded index is replaced only after `path` opens,
  /// so a failed open leaves it usable; `saveCurrent` checkpoints it first.
  func open(
    _ path: String, keepCurrent: Bool = false, saveCurrent: Bool = false,
    completion: @escaping (Result<Reply, Error>) -> Void
  ) {
    cn_cancel()
    cn_cancel_scan()
    queue.async {
      if saveCurrent && self.handle != nil {
        // Best effort: unsaved live changes are otherwise replayed from FSEvents.
        _ = try? decode(cn_checkpoint(self.handle, true))
      }
      if !keepCurrent {
        cn_engine_close(self.handle)
        self.handle = nil
      }
      var replacement: OpaquePointer?
      let result = Result { try path.withCString { try decode(cn_engine_open($0, &replacement)) } }
      if case .success = result {
        cn_engine_close(self.handle)
        self.handle = replacement
      } else {
        cn_engine_close(replacement)
      }
      DispatchQueue.main.async { completion(result) }
    }
  }

  func search(
    query: String, directory: String, sensitive: Bool, generation: UInt64,
    submitted: Double, firstRow: Int = 0, sort: String = "null",
    completion: @escaping (Result<(Reply, [Row], Double), Error>) -> Void
  ) {
    let request = SearchRequest()
    queue.async {
      let result = Result { () throws -> (Reply, [Row], Double) in
        _ = try sort.withCString { try decode(cn_sort(self.handle, $0)) }
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
        do { _ = try decode(cn_checkpoint(self.handle, true)) } catch let e { error = e }
      }
      cn_engine_close(self.handle)
      self.handle = nil
      DispatchQueue.main.async { completion(error) }
    }
  }

  deinit { cn_engine_close(handle) }
}

// A scan's new index, passed from the scan queue to the engine queue.
private final class ScannedIndex: @unchecked Sendable {
  var handle: OpaquePointer?
}

// Captures keep the request alive through its queued operation and any
// concurrent reads of the scan progress counter.
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

@Observable final class Model {
  var query = ""
  var directory = ""
  var sensitive = false { didSet { if sensitive != oldValue { filterEvents() } } }
  var debounce = 100
  var total = 0
  var indexedCount = 0
  var processedEventCount = 0
  var status = "Choose or load a saved index."
  var snapshot = Preferences.snapshotIndex
  var snapshotDate = ""
  var ready = false
  var searching = false
  /// Result-table content version. Not published: the table is notified directly
  /// so row loads never re-render the SwiftUI window.
  @ObservationIgnored var revision: UInt64 = 0 { didSet { scheduleTableUpdate() } }
  /// Rows whose data changed since the table last applied `revision`.
  @ObservationIgnored var dirtyRows = IndexSet()
  @ObservationIgnored var tableUpdate: (() -> Void)?
  @ObservationIgnored private var tableUpdateScheduled = false
  var error: String?
  let engine = Engine()
  @ObservationIgnored lazy var actions = FileActions(self)
  var hasFullDiskAccess = true
  var shortcutMessage: String?
  var recordingShortcut = false
  let library: SearchLibrary
  var libraryOpen = false
  /// Selected Settings tab; kept on the model so it survives Settings sessions.
  var settingsTab = "general"
  /// The results table has keyboard focus; gates file commands in the menu bar.
  var resultsFocused = false
  @ObservationIgnored var suppressedHistoryState: SearchState?
  @ObservationIgnored var observedSearchState: SearchState?
  @ObservationIgnored var successfulSearchState: SearchState?
  @ObservationIgnored var successfulSearchTicket: UInt64?
  @ObservationIgnored var recordRequestedState: SearchState?
  @ObservationIgnored var historyRecordWork: DispatchWorkItem?
  let prefs: Preferences
  var live = false
  var scanning = false
  /// Folders changed by filesystem events are being read in the background.
  var walking = false
  var indexStatus = "Saved index"
  var events: [FileEvent] = [] { didSet { filterEvents() } }
  var eventFilter = "" { didSet { if eventFilter != oldValue { filterEvents() } } }
  /// Events shown on the Events tab, recomputed only when its inputs change.
  private(set) var filteredEvents: [FileEvent] = []
  var activeTab = "files"
  /// Not published: a click's selection loads in milliseconds, and the window
  /// need not redraw for it.
  @ObservationIgnored var selectionLoading = false {
    didSet { if oldValue && !selectionLoading { selectionDidLoad?() } }
  }
  /// Called on the main thread after selectionLoading becomes false.
  @ObservationIgnored var selectionDidLoad: (() -> Void)?
  @ObservationIgnored var selectedPaths: [String] = []
  /// The count from the latest selection reply; it stays until the next reply.
  var selectionCount = 0 {
    didSet { if hasSelection != (selectionCount > 0) { hasSelection = selectionCount > 0 } }
  }
  /// Menu commands read this rather than the count, so selecting another file
  /// does not rebuild the menus.
  private(set) var hasSelection = false
  var sortKey = ""
  var sortAscending = true
  var snapshotOnly = true
  @ObservationIgnored var checkpointPath = Preferences.index
  @ObservationIgnored var root = ""
  @ObservationIgnored var loadedIgnores: [String] = []
  @ObservationIgnored var loadedIncludes: [String] = []
  @ObservationIgnored var loadedPatterns: [String] = []
  @ObservationIgnored var timer: Timer?
  @ObservationIgnored var polling = false
  @ObservationIgnored var lastPoll = 0.0
  /// processed_events when `events` was last fetched; nil after an index swap.
  @ObservationIgnored var eventsFetchedAt: UInt64?
  @ObservationIgnored var saving = false
  /// Startup messages, shown by `showNotices` once the first index is loaded or scanned.
  @ObservationIgnored var notices: [String] = []
  /// Set when a scan fails or is cancelled, so an index that needs a rescan is not
  /// rescanned again on every poll; the Rescan command still runs, and a
  /// successful scan or opening an index clears it.
  @ObservationIgnored var automaticRescanPaused = false
  /// The engine reported that the index can no longer be kept current; shown in the
  /// status bar while automatic rescans are paused.
  var rescanNeeded = false
  /// No index is loaded because the scan that would build it was cancelled or failed.
  var needsIndex = false
  /// The user turned Live Updates off; rescans keep them off until turned on again.
  @ObservationIgnored var liveUpdatesPausedByUser = false
  @ObservationIgnored var refreshPending = false
  /// Sizes or dates changed since the displayed rows were loaded.
  @ObservationIgnored var visibleRowsStale = false
  /// Backfilled sizes/dates may reorder or refilter the displayed results.
  @ObservationIgnored var metadataRefreshPending = false
  @ObservationIgnored var metadataIndexing = false
  /// Whether the running search is a background refresh.
  @ObservationIgnored var searchIsBackground = false
  @ObservationIgnored var lastRefresh = 0.0
  @ObservationIgnored var lastSave = ProcessInfo.processInfo.systemUptime
  @ObservationIgnored var indexEpoch: UInt64 = 0
  @ObservationIgnored var selectionEpoch: UInt64 = 0
  @ObservationIgnored var restoredSelection: IndexSet?
  @ObservationIgnored var backgroundResult = false
  @ObservationIgnored var visibleStart = 0
  @ObservationIgnored var tableAction: ((String) -> Void)?
  @ObservationIgnored var focusSearch: (() -> Void)?
  @ObservationIgnored var historyCursor = -1
  @ObservationIgnored var navigationHistory: [SearchState] = []
  @ObservationIgnored var closeCompletions: [(Error?) -> Void] = []
  @ObservationIgnored var closeFinished = false
  init(prefs: Preferences = Preferences(isolated: true)) {
    self.prefs = prefs
    library = SearchLibrary(url: prefs.isolated ? nil : prefs.storageURL.deletingLastPathComponent().appendingPathComponent("search-library.json"))
    sortKey = prefs.sortKey
    sortAscending = prefs.sortAscending
    debounce = prefs.debounce
    library.willRemoveHistory = { [weak self] state in self?.suppressHistoryRecording(state) }
    // Surface library errors in the main window, including one from loading, which
    // is shown with unreadable preferences after the index loads.
    notices = [prefs.loadError, library.error].compactMap { $0 }
    library.onError = { [weak self] in self?.error = $0 }
  }
  @ObservationIgnored var rows: [Int: Row] = [:]
  @ObservationIgnored var highlights: [String] = []
  @ObservationIgnored var displayedSensitive = false
  @ObservationIgnored var generation: UInt64 = 0
  @ObservationIgnored var displayedGeneration: UInt64 = 0
  @ObservationIgnored var inputAt = 0.0
  @ObservationIgnored var submittedAt = 0.0
  var backendMS = 0.0
  @ObservationIgnored var lastSample: Sample?
  @ObservationIgnored var pendingDraw: UInt64?
  @ObservationIgnored var pendingPages = Set<Int>()
  let metadataQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "everything.mac.row-metadata"
    queue.qualityOfService = .utility
    queue.maxConcurrentOperationCount = 2
    return queue
  }()
  @ObservationIgnored var pendingMetadata: [Int: RowMetadataOperation] = [:]
  @ObservationIgnored var debounceWork: DispatchWorkItem?
  @ObservationIgnored var onDraw: ((Sample) -> Void)?
  @ObservationIgnored var loadedMS = 0.0
  @ObservationIgnored var closed = false

  private func filterEvents() {
    let filter = eventFilter
    let options: String.CompareOptions = sensitive ? [] : [.caseInsensitive]
    filteredEvents = filter.isEmpty
      ? events : events.filter { $0.path.range(of: filter, options: options) != nil }
  }

  /// Coalesces page and metadata arrivals into one table pass per main-loop turn.
  func scheduleTableUpdate() {
    guard !tableUpdateScheduled else { return }
    tableUpdateScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.tableUpdateScheduled = false
      self.tableUpdate?()
    }
  }

  /// The index shown before "Open Index…", restored if the chosen file cannot be opened.
  struct LoadedIndex {
    let snapshot: String
    let snapshotDate: String
    let snapshotOnly: Bool
    let live: Bool
  }

  func load(restoringOnFailure previous: LoadedIndex? = nil) {
    debounceWork?.cancel()
    debounceWork = nil
    indexEpoch &+= 1
    let epoch = indexEpoch
    generation &+= 1
    ready = false
    searching = false
    walking = false
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
    // Another index gets automatic rescans again.
    automaticRescanPaused = false
    rescanNeeded = false
    needsIndex = false
    let path = snapshot
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    snapshotDate = (attributes?[.modificationDate] as? Date)?.formatted() ?? "Unavailable"
    engine.open(
      path, keepCurrent: previous != nil, saveCurrent: previous.map { !$0.snapshotOnly } ?? false
    ) { [weak self] result in
      guard let self = self, !self.closed, self.indexEpoch == epoch else { return }
      switch result {
      case .success(let reply):
        self.root = reply.root ?? self.prefs.root
        self.loadedIgnores = reply.ignores ?? []
        self.loadedIncludes = reply.includes ?? []
        self.loadedPatterns = reply.exclusion_patterns ?? []
        self.loadedMS = reply.load_ms ?? 0
        self.indexedCount = reply.total ?? 0
        self.processedEventCount = 0
        self.resetEvents()
        self.ready = true
        if !self.snapshotOnly {
          self.setLive()
          self.startTimer()
        }
        self.status = "Loaded \(reply.total ?? 0) indexed entries in \(Int(self.loadedMS)) ms"
        self.inputAt = ProcessInfo.processInfo.systemUptime
        self.submit()
        if !self.snapshotOnly && self.prefs.loadError != nil {
          // Preferences that could not be read fell back to defaults; keep the
          // folders of the index instead of rescanning with the default ones.
          self.prefs.loadError = nil
          self.saveLoadedScope()
        }
        // The loaded index stays searchable while it is rebuilt for new settings.
        if !self.snapshotOnly && self.scopeDiffersFromPreferences() {
          self.scan()
        } else {
          self.showNotices()
        }
      case .failure(let error):
        if let previous {
          self.snapshot = previous.snapshot
          self.snapshotDate = previous.snapshotDate
          self.snapshotOnly = previous.snapshotOnly
          self.live = previous.live
          self.ready = true
          if !self.snapshotOnly { self.startTimer() }
          self.inputAt = ProcessInfo.processInfo.systemUptime
          self.submit()
          self.error =
            "Cannot open \((path as NSString).lastPathComponent): \(error.localizedDescription). The current index is still loaded."
          self.showNotices()
          return
        }
        if !self.snapshotOnly {
          // The app's own index only mirrors the disk, so a damaged one is rebuilt.
          self.scan()
          self.error = "The saved index could not be read (\(error.localizedDescription)); rebuilding it."
          return
        }
        self.error =
          "Cannot load this snapshot: \(error.localizedDescription). Choose a compatible EverythingMac index; no scan will be started."
        self.status = "Index unavailable"
        self.showNotices()
      }
    }
  }

  func changed() {
    guard observedSearchState != currentSearchState else { return }
    observedSearchState = currentSearchState
    historyRecordWork?.cancel()
    successfulSearchState = nil
    recordRequestedState = nil
    suppressedHistoryState = nil
    historyCursor = -1
    navigationHistory = []
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
    let submittedState = currentSearchState
    searching = true
    searchIsBackground = background
    // Background refreshes keep messages about earlier actions, such as a partial
    // move to the Trash; the user dismisses them or starts a search.
    if !background && error != nil { error = nil }
    pendingDraw = nil
    submittedAt = ProcessInfo.processInfo.systemUptime
    if inputAt == 0 { inputAt = submittedAt }
    engine.search(
      query: query, directory: directory, sensitive: sensitive,
      generation: ticket, submitted: submittedAt,
      firstRow: background ? (visibleStart / 128) * 128 : 0,
      sort: sortKey.isEmpty
        ? "null" : jsonString(["key": sortKey, "direction": sortAscending ? "asc" : "desc"])
    ) { [weak self] result in
      guard let self = self, !self.closed, self.generation == ticket else { return }
      switch result {
      case .success(let (reply, rows, _)):
        guard reply.status == "ok" else { self.searching = false; return }
        if !background { self.recordSuccessfulSearch(submittedState, ticket: ticket) }
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
      if selectionCount != 0 { selectionCount = 0 }
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
    visibleRowsStale = false
    pendingPages.removeAll()
    pendingDraw = ticket
    status = "\(total) results · Rust \(String(format: "%.1f", backendMS)) ms"
    revision &+= 1
    // New results are shown without waiting for the coalesced pass.
    tableUpdate?()
    if selection != nil, selectionCount > 0, actions.preview.isVisible {
      resolveSelection(limit: PreviewController.limit) { [weak self] in
        self?.actions.preview.update($0)
      }
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
      for row in loaded {
        self.rows[row.index] = row
        self.dirtyRows.insert(row.index)
      }
      // Keep at most 8 pages. Never allocate models for the full result set.
      if self.rows.count > 1024 {
        self.rows = self.rows.filter { abs($0.key - start) < 512 }
      }
      if !loaded.isEmpty { self.revision &+= 1 }
    }
  }

  /// Re-reads cached rows around the viewport after sizes or dates changed in place.
  /// A row keeps metadata Swift loaded itself while the index has none yet.
  func refreshVisibleRows() {
    guard ready, !searching, !closed, total > 0 else { return }
    let ticket = displayedGeneration
    let first = (visibleStart / 128) * 128
    for start in [first, first + 128] where start < total {
      engine.rows(generation: ticket, start: start) { [weak self] loaded in
        guard let self = self, !self.closed, self.displayedGeneration == ticket else { return }
        var updated = false
        for row in loaded {
          guard let current = self.rows[row.index], current != row else { continue }
          if current.path == row.path && current.metadata_loaded && !row.metadata_loaded { continue }
          self.rows[row.index] = row
          self.dirtyRows.insert(row.index)
          updated = true
        }
        if updated { self.revision &+= 1 }
      }
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
      let previous =
        ready
        ? LoadedIndex(
          snapshot: snapshot, snapshotDate: snapshotDate, snapshotOnly: snapshotOnly, live: live)
        : nil
      snapshotOnly = true
      live = false
      timer?.invalidate()
      snapshot = url.path
      load(restoringOnFailure: previous)
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
    historyRecordWork?.cancel()
    let library = self.library
    engine.queue.async {
      do { try library.flush() }
      catch { DispatchQueue.main.async { library.error = error.localizedDescription } }
    }
    engine.close(save: !snapshotOnly && ready && !scanning) { [weak self] error in
      guard let self = self else { return }
      self.closeFinished = true
      let completions = self.closeCompletions
      self.closeCompletions = []
      completions.forEach { $0(error) }
    }
  }
}
