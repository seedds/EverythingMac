import AppKit
import CNative

struct FileEvent: Decodable, Identifiable {
  let id: UInt64
  let path: String
  let flags: String
  let time: Double
  let name: String
  let folder: String
  enum CodingKeys: String, CodingKey { case id, path, flags, time }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    id = try values.decode(UInt64.self, forKey: .id)
    path = try values.decode(String.self, forKey: .path)
    flags = try values.decode(String.self, forKey: .flags)
    time = try values.decode(Double.self, forKey: .time)
    // String-only parsing, computed once per event rather than per table render.
    name = (path as NSString).lastPathComponent
    folder = (path as NSString).deletingLastPathComponent
  }
}
func jsonString<T: Encodable>(_ value: T) -> String {
  String(data: (try? JSONEncoder().encode(value)) ?? Data("null".utf8), encoding: .utf8)!
}

extension Model {
  func startTimer() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      self?.poll()
    }
    timer?.tolerance = 0.1
  }
  func setLive() {
    guard ready, !snapshotOnly, !closed else { return }
    let enabled = live
    let epoch = indexEpoch
    let checkpoint = checkpointPath
    engine.perform({ h in try checkpoint.withCString { try decode(cn_watch(h, enabled, $0)) } }) {
      [weak self] result in
      guard let self = self, !self.closed, self.indexEpoch == epoch else { return }
      if case .failure(let e) = result {
        self.error = e.localizedDescription
        self.live = false
      }
      self.indexStatus = self.live ? "Live updates · catching up…" : "Live updates paused"
    }
  }
  func poll() {
    guard ready, !snapshotOnly, !closed, !searching, !scanning, !polling, !saving,
      !selectionLoading
    else { return }
    // Poll less often while the search window is hidden.
    let now = ProcessInfo.processInfo.systemUptime
    let shown = searchWindowShown
    guard shown || now - lastPoll >= 2 else { return }
    lastPoll = now
    polling = true
    let epoch = indexEpoch
    let includeEvents = activeTab == "events" && shown
    // UInt64.max never matches the engine's count, forcing a first fetch.
    let since = includeEvents ? (eventsFetchedAt ?? .max) : 0
    engine.perform({ try decode(cn_poll($0, since, includeEvents)) }) { [weak self] result in
      guard let self = self else { return }
      self.polling = false
      guard !self.closed, self.indexEpoch == epoch else { return }
      switch result {
      case .failure(let e):
        self.error = e.localizedDescription
        self.live = false
      case .success(let reply):
        if reply.watcher_stopped == true {
          self.error = "Filesystem watcher stopped. Resume Live updates or rescan."
          self.live = false
        }
        let processed = reply.processed_events ?? 0
        if let events = reply.events, self.activeTab == "events" {
          self.events = events
          self.eventsFetchedAt = processed
        }
        let total = reply.total ?? self.indexedCount
        if self.indexedCount != total { self.indexedCount = total }
        if self.processedEventCount != Int(clamping: processed) {
          self.processedEventCount = Int(clamping: processed)
        }
        let walking = reply.walking == true
        if self.walking != walking { self.walking = walking }
        var status = "\(reply.total ?? 0) indexed · \(processed) events"
        if walking { status += " · Updating changed folders…" }
        if reply.metadata_indexing == true {
          status += " · Indexing file sizes and dates…"
        } else if !self.live {
          status += " · Live updates paused"
        }
        if reply.needs_rescan == true && self.automaticRescanPaused {
          status += " · Rescan needed"
        }
        if self.indexStatus != status { self.indexStatus = status }
        if reply.needs_rescan == true {
          self.rescanAutomatically()
          return
        }
        if reply.changed == true { self.refreshPending = true }
        let now = ProcessInfo.processInfo.systemUptime
        // Backfilled sizes and dates leave the displayed rows valid, and visible rows
        // load their own metadata. Re-sort or re-filter only when the view uses it:
        // at most every 10 seconds, and once more when the backfill finishes.
        if reply.metadata_changed == true && self.displayDependsOnMetadata {
          self.metadataRefreshPending = true
        }
        let backfillFinished = self.metadataIndexing && reply.metadata_indexing != true
        self.metadataIndexing = reply.metadata_indexing == true
        if self.metadataRefreshPending && (backfillFinished || now - self.lastRefresh > 10) {
          self.metadataRefreshPending = false
          self.refreshPending = true
        }
        // Rows on screen show sizes and dates updated in place without a new search.
        // A hidden window keeps its index current, and updates its rows and runs
        // its search again once it is shown.
        if reply.metadata_changed == true { self.visibleRowsStale = true }
        let shown = self.searchWindowShown
        if self.visibleRowsStale && shown && !self.refreshPending {
          self.visibleRowsStale = false
          self.refreshVisibleRows()
        }
        if self.refreshPending && shown && self.debounceWork == nil && !self.searching
          && now - self.lastRefresh > 1
        {
          self.refreshPending = false
          self.lastRefresh = now
          self.submit(background: true)
        } else if now - self.lastSave > self.checkpointInterval && now - self.inputAt > 10
          && !self.searching && self.debounceWork == nil
        {
          self.saving = true
          self.lastSave = now
          self.engine.perform({ try decode(cn_checkpoint($0, false)) }) { [weak self] result in
            self?.saving = false
            switch result {
            case .failure(let e):
              self?.error = "Cannot save native index: \(e.localizedDescription)"
            case .success: self?.refreshCheckpointInformation()
            }
          }
        }
      }
    }
  }
  /// Whether any part of the search window is on screen. Checks count an open window
  /// as shown, since other apps' windows may cover theirs while they run.
  var searchWindowShown: Bool {
    NSApp.windows.contains {
      $0.identifier?.rawValue == "EverythingMacSearch"
        && (prefs.isolated ? $0.isVisible : $0.occlusionState.contains(.visible))
    }
  }
  /// Brings results up to date as soon as the search window appears again.
  func searchWindowVisibilityChanged() {
    if searchWindowShown { poll() }
  }
  /// Seconds between idle saves: a fresh scan is saved soon; later changes are
  /// replayed from FSEvents after a restart, so saving rarely avoids stalls.
  var checkpointInterval: Double { snapshotDate == "Not saved yet" ? 60 : 600 }
  /// Sorting or filtering by size or date, whose results change as metadata is indexed.
  var displayDependsOnMetadata: Bool {
    ["size", "mtime", "ctime"].contains(sortKey)
      || query.range(of: Self.metadataFilter, options: .regularExpression) != nil
  }
  static let metadataFilter =
    #"(?i)\b(size|dm|datemodified|dc|datecreated):"#
  /// Drops files the app itself just removed from the index and refreshes at once,
  /// rather than waiting for the filesystem events and the refresh throttle.
  func applyRemovals(_ paths: [String]) {
    guard ready, !closed else { return }
    let json = jsonString(paths)
    let epoch = indexEpoch
    engine.perform({ h in try json.withCString { try decode(cn_remove_paths(h, $0)) } }) {
      [weak self] result in
      guard let self = self, !self.closed, self.indexEpoch == epoch else { return }
      guard case .success(let reply) = result, reply.changed == true else {
        self.refreshPending = true
        self.poll()
        return
      }
      if reply.needs_rescan == true {
        self.rescanAutomatically()
        return
      }
      self.refreshPending = false
      self.lastRefresh = ProcessInfo.processInfo.systemUptime
      self.submit(background: true)
    }
  }
  /// A new engine restarts its event counter; drop the previous engine's list.
  func resetEvents() {
    events = []
    eventsFetchedAt = nil
  }
  func refreshCheckpointInformation() {
    let path = checkpointPath
    engine.queue.async { [weak self] in
      let modified =
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
      DispatchQueue.main.async { [weak self] in
        guard let self = self, !self.closed, !self.snapshotOnly, let modified = modified else {
          return
        }
        self.snapshot = path
        self.snapshotDate = modified.formatted()
      }
    }
  }
  /// The current index stays searchable until the scan replaces it.
  /// Rebuilds an index the engine can no longer update, unless the last scan
  /// failed or was cancelled; the user then chooses when to rescan.
  func rescanAutomatically() {
    guard !automaticRescanPaused else { return }
    scan(useCurrentConfig: true)
  }
  func scan(useCurrentConfig: Bool = false) {
    guard !scanning, !snapshotOnly, !closed else { return }
    let epoch = indexEpoch
    let previousIndexStatus = indexStatus
    let previousCount = indexedCount
    let previousEvents = processedEventCount
    scanning = true
    error = nil
    status = "Scanning…"
    indexedCount = 0
    processedEventCount = 0
    indexStatus = "Scanning…"
    let scanRoot = useCurrentConfig && !root.isEmpty ? root : Preferences.normalized(prefs.root)
    let ignores = useCurrentConfig ? loadedIgnores : Preferences.paths(prefs.ignores)
    let includes = useCurrentConfig ? loadedIncludes : Preferences.paths(prefs.includes)
    let patterns = useCurrentConfig ? loadedPatterns : prefs.patternLines
    engine.scan(root: scanRoot, ignores: ignores, includes: includes, patterns: patterns, progress: { [weak self] count in
      guard let self = self, !self.closed, self.indexEpoch == epoch, self.scanning else { return }
      self.indexedCount = count
      self.indexStatus = "Scanning… \(count) entries found"
    }) { [weak self] result in
      guard let self = self, !self.closed, self.indexEpoch == epoch else { return }
      self.scanning = false
      switch result {
      case .success(let reply):
        guard reply.status == "ok" else {
          self.indexStatus = previousIndexStatus
          self.indexedCount = previousCount
          self.processedEventCount = previousEvents
          self.status = "Scan cancelled; previous index retained"
          self.automaticRescanPaused = true
          return
        }
        self.automaticRescanPaused = false
        // Replies about the replaced index no longer apply.
        self.indexEpoch &+= 1
        self.walking = false
        self.root = reply.root ?? scanRoot
        self.loadedIgnores = reply.ignores ?? ignores
        self.loadedIncludes = reply.includes ?? includes
        self.loadedPatterns = reply.exclusion_patterns ?? patterns
        if !useCurrentConfig {
          self.prefs.root = self.root
          self.prefs.ignores = self.loadedIgnores.filter { $0 != "/System/Volumes/Data" }.joined(
            separator: "\n")
          self.prefs.includes = self.loadedIncludes.joined(separator: "\n")
          self.prefs.patterns = self.loadedPatterns.joined(separator: "\n")
          do { try self.prefs.save() } catch { self.error = error.localizedDescription }
        }
        self.ready = true
        self.live = true
        self.snapshot = self.checkpointPath
        self.snapshotDate = "Not saved yet"
        self.loadedMS = reply.load_ms ?? 0
        self.indexedCount = reply.total ?? 0
        self.processedEventCount = 0
        self.resetEvents()
        self.setLive()
        self.startTimer()
        // Run the displayed search again on the new index. A search still running
        // used the previous index and runs again as the same kind of search; one
        // still being typed waits for its own delay.
        if self.debounceWork == nil {
          self.submit(background: !self.searching || self.searchIsBackground)
        }
      case .failure(let e):
        self.indexStatus = previousIndexStatus
        self.indexedCount = previousCount
        self.processedEventCount = previousEvents
        self.error = e.localizedDescription
        self.status = "Scan failed; previous index retained"
        self.automaticRescanPaused = true
      }
    }
  }
  func savePreferences(_ draft: Preferences) throws {
    guard !scanning else { throw messageError("Finish or cancel the current scan before saving preferences.") }
    try prefs.commit(draft)
    applyPreferences()
  }
  func applyPreferences() {
    guard !snapshotOnly else { return }
    let ignores = Set(Preferences.paths(prefs.ignores) + ["/System/Volumes/Data"])
    if root != Preferences.normalized(prefs.root) || ignores != Set(loadedIgnores)
      || Set(Preferences.paths(prefs.includes)) != Set(loadedIncludes)
      || prefs.patternLines != loadedPatterns
    {
      scan()
    } else {
      submit(background: true)
    }
  }
  func sort(by key: String) {
    if sortKey != key {
      sortKey = key
      sortAscending = true
    } else if sortAscending {
      sortAscending = false
    } else {
      sortKey = ""
      sortAscending = true
    }
    prefs.sortKey = sortKey
    prefs.sortAscending = sortAscending
    submit(background: true)
    do { try prefs.save() }
    catch { self.error = "Could not save the sort preference: \(error.localizedDescription)" }
  }
  func selectionChanged(_ indices: IndexSet) {
    selectionEpoch &+= 1
    let epoch = selectionEpoch
    let ticket = displayedGeneration
    selectionLoading = true
    selectedPaths = []
    let ranges = indices.rangeView.map { [$0.lowerBound, $0.upperBound] }
    let cached = indices.count <= 1024 ? indices.compactMap { rows[$0]?.path } : []
    let fallback: String = cached.count == indices.count ? jsonString(cached) : "null"
    engine.perform({ h in
      try jsonString(ranges).withCString { r in
        try fallback.withCString { p in try decode(cn_select(h, ticket, r, p)) }
      }
    }) { [weak self] result in
      guard let self = self, !self.closed, self.selectionEpoch == epoch else { return }
      self.selectionLoading = false
      switch result {
      case .success(let reply) where reply.status == "ok":
        self.selectedPaths = reply.paths ?? []
        let count = reply.selection_count ?? 0
        if self.selectionCount != count { self.selectionCount = count }
        if self.actions.preview.isVisible {
          if self.selectionCount == 0 {
            self.actions.preview.update([])
          } else {
            self.resolveSelection(limit: PreviewController.limit) { [weak self] in
            self?.actions.preview.update($0)
          }
          }
        }
        if self.displayedGeneration != ticket { self.restoreSelection() }
      default:
        self.selectedPaths = []
        self.selectionCount = 0
        self.error = "The index changed before selection finished. Select the files again."
      }
    }
  }
  func restoreSelection() {
    guard selectionCount > 0 else { return }
    let epoch = selectionEpoch
    let ticket = displayedGeneration
    engine.perform({ try decode(cn_selected($0, ticket, false)) }) { [weak self] result in
      guard let self = self, !self.closed, self.selectionEpoch == epoch,
        self.displayedGeneration == ticket
      else { return }
      if case .success(let reply) = result, reply.status == "ok" {
        self.applyRestoredSelection(reply)
        self.revision &+= 1
        if self.selectionCount > 0 && self.actions.preview.isVisible {
          self.resolveSelection(limit: PreviewController.limit) { [weak self] in
            self?.actions.preview.update($0)
          }
        }
      }
    }
  }
  func applyRestoredSelection(_ reply: Reply) {
    var indices = IndexSet()
    for pair in reply.ranges ?? [] where pair.count == 2 {
      indices.insert(integersIn: pair[0]..<pair[1])
    }
    restoredSelection = indices
    selectedPaths = reply.paths ?? []
    let count = reply.selection_count ?? indices.count
    if selectionCount != count { selectionCount = count }
    if selectionCount == 0 && actions.preview.isVisible { actions.preview.update([]) }
  }
  /// Resolves selected paths for an action; `limit` bounds them (0 for all).
  func resolveSelection(limit: Int = 0, _ completion: @escaping ([String]) -> Void) {
    guard !selectionLoading, selectionCount > 0 else { return }
    let epoch = selectionEpoch
    let index = indexEpoch
    engine.perform({ try decode(cn_selection_paths($0, limit)) }) { [weak self] result in
      guard let self = self, !self.closed, self.selectionEpoch == epoch,
        self.indexEpoch == index
      else { return }
      switch result {
      case .success(let reply) where reply.status == "ok":
        completion(reply.paths ?? [])
      case .failure(let error): self.error = error.localizedDescription
      default: self.error = "Cannot resolve the selected files. Select them again."
      }
    }
  }
  func scopeDiffersFromPreferences() -> Bool {
    root != Preferences.normalized(prefs.root)
      || Set(loadedIgnores) != Set(Preferences.paths(prefs.ignores) + ["/System/Volumes/Data"])
      || Set(loadedIncludes) != Set(Preferences.paths(prefs.includes))
      || loadedPatterns != prefs.patternLines
  }
  func rememberQuery() {
    let state = currentSearchState
    historyRecordWork?.cancel()
    suppressedHistoryState = nil
    recordRequestedState = state
    if successfulSearchState == state { library.record(state) }
    else { recordRequestedState = state }
  }
  func navigateHistory(_ delta: Int) {
    if navigationHistory.isEmpty { navigationHistory = library.recent.map(\.state) }
    guard !navigationHistory.isEmpty else { return }
    historyCursor = min(max(0, historyCursor + (delta < 0 ? 1 : -1)), navigationHistory.count - 1)
    restoreSearch(navigationHistory[historyCursor], record: false)
  }
  func enableLive() {
    guard ready else { return }
    snapshotOnly = false
    live = true
    prefs.root = root
    prefs.ignores = loadedIgnores.joined(separator: "\n")
    prefs.includes = loadedIncludes.joined(separator: "\n")
    prefs.patterns = loadedPatterns.joined(separator: "\n")
    do { try prefs.save() } catch { self.error = error.localizedDescription }
    setLive()
    startTimer()
  }
}
