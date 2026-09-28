import AppKit
import CNative

struct FileEvent: Decodable, Identifiable {
  let id: UInt64
  let path: String
  let flags: String
  let time: Double
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
    guard live, ready, !snapshotOnly, !closed, !searching, !scanning, !polling, !saving,
      !selectionLoading
    else { return }
    polling = true
    let epoch = indexEpoch
    engine.perform({ try decode(cn_poll($0)) }) { [weak self] result in
      guard let self = self else { return }
      self.polling = false
      guard !self.closed, self.indexEpoch == epoch else { return }
      switch result {
      case .failure(let e):
        self.error = e.localizedDescription
        self.live = false
      case .success(let reply):
        self.events = reply.events ?? []
        self.indexedCount = reply.total ?? self.indexedCount
        self.processedEventCount = Int(clamping: reply.processed_events ?? 0)
        self.indexStatus = "\(reply.total ?? 0) indexed · \(reply.processed_events ?? 0) events"
        if reply.needs_rescan == true {
          self.scan(useCurrentConfig: true)
          return
        }
        if reply.changed == true { self.refreshPending = true }
        let now = ProcessInfo.processInfo.systemUptime
        if self.refreshPending && self.debounceWork == nil && !self.searching
          && now - self.lastRefresh > 1
        {
          self.refreshPending = false
          self.lastRefresh = now
          self.submit(background: true)
        } else if now - self.lastSave > 60 && now - self.inputAt > 10 && !self.searching
          && self.debounceWork == nil
        {
          self.saving = true
          self.lastSave = now
          self.engine.perform({ try decode(cn_checkpoint($0)) }) { [weak self] result in
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
  func scan(useCurrentConfig: Bool = false) {
    guard !scanning, !snapshotOnly, !closed else { return }
    cn_cancel()
    cn_cancel_scan()
    debounceWork?.cancel()
    debounceWork = nil
    indexEpoch &+= 1
    let epoch = indexEpoch
    generation &+= 1
    pendingDraw = nil
    searching = false
    let hadIndex = ready
    scanning = true
    ready = false
    error = nil
    status = "Scanning…"
    let scanRoot = useCurrentConfig && !root.isEmpty ? root : Preferences.normalized(prefs.root)
    let ignores = useCurrentConfig ? loadedIgnores : Preferences.paths(prefs.ignores)
    let includes = useCurrentConfig ? loadedIncludes : Preferences.paths(prefs.includes)
    engine.scan(root: scanRoot, ignores: ignores, includes: includes) { [weak self] result in
      guard let self = self, !self.closed, self.indexEpoch == epoch else { return }
      self.scanning = false
      switch result {
      case .success(let reply):
        guard reply.status == "ok" else {
          self.ready = hadIndex
          self.status = "Scan cancelled; previous index retained"
          if hadIndex { self.submit(background: true) }
          return
        }
        self.root = reply.root ?? scanRoot
        self.loadedIgnores = reply.ignores ?? ignores
        self.loadedIncludes = reply.includes ?? includes
        if !useCurrentConfig {
          self.prefs.root = self.root
          self.prefs.ignores = self.loadedIgnores.filter { $0 != "/System/Volumes/Data" }.joined(
            separator: "\n")
          self.prefs.includes = self.loadedIncludes.joined(separator: "\n")
          do { try self.prefs.save() } catch { self.error = error.localizedDescription }
        }
        self.ready = true
        self.live = true
        self.snapshot = self.checkpointPath
        self.snapshotDate = "Not saved yet"
        self.loadedMS = reply.load_ms ?? 0
        self.indexedCount = reply.total ?? 0
        self.processedEventCount = 0
        self.setLive()
        self.startTimer()
        self.submit(background: true)
      case .failure(let e):
        self.ready = hadIndex
        self.error = e.localizedDescription
        self.status = "Scan failed; previous index retained"
      }
    }
  }
  func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url {
      prefs.root = url.path
      snapshotOnly = false
      live = true
      do {
        try prefs.save()
        scan()
      } catch { self.error = error.localizedDescription }
    }
  }
  func applyPreferences() {
    guard !snapshotOnly else { return }
    let ignores = Set(Preferences.paths(prefs.ignores) + ["/System/Volumes/Data"])
    if root != Preferences.normalized(prefs.root) || ignores != Set(loadedIgnores)
      || Set(Preferences.paths(prefs.includes)) != Set(loadedIncludes)
    {
      scan()
    } else {
      submit(background: true)
    }
  }
  func sort(by key: String) {
    guard total <= prefs.sortLimit else {
      error = "Sorting is limited to \(prefs.sortLimit) results. Adjust the limit in Preferences."
      return
    }
    if sortKey != key {
      sortKey = key
      sortAscending = true
    } else if sortAscending {
      sortAscending = false
    } else {
      sortKey = ""
    }
    submit(background: true)
  }
  func selectionChanged(_ indices: IndexSet) {
    selectionEpoch &+= 1
    let epoch = selectionEpoch
    let ticket = displayedGeneration
    selectionLoading = true
    selectedPaths = []
    selectionCount = 0
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
        self.selectionCount = reply.selection_count ?? 0
        if self.actions.preview.isVisible {
          if self.selectionCount == 0 {
            self.actions.preview.update([])
          } else {
            self.resolveSelection { [weak self] in self?.actions.preview.update($0) }
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
          self.resolveSelection { [weak self] in self?.actions.preview.update($0) }
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
    selectionCount = reply.selection_count ?? indices.count
    if selectionCount == 0 && actions.preview.isVisible { actions.preview.update([]) }
  }
  func resolveSelection(_ completion: @escaping ([String]) -> Void) {
    guard !selectionLoading, selectionCount > 0 else { return }
    let epoch = selectionEpoch
    let index = indexEpoch
    engine.perform({ try decode(cn_selection_paths($0)) }) { [weak self] result in
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
  }
  func historyEdited() {
    let tail = history.last ?? ""
    if historyCursor != history.count - 1 || (!tail.isEmpty && query.isEmpty)
      || (!tail.isEmpty && !query.isEmpty && tail.first != query.first)
    {
      history.append(query)
    } else {
      history[history.count - 1] = query
    }
    if history.count > 50 { history.removeFirst() }
    historyCursor = history.count - 1
  }
  func rememberQuery() {
    if history.last != query { history.append(query) }
    if history.count > 50 { history.removeFirst() }
    historyCursor = history.count - 1
  }
  func navigateHistory(_ delta: Int) {
    historyCursor = min(max(0, historyCursor + delta), history.count - 1)
    let value = history[historyCursor]
    if query != value {
      navigatingHistory = true
      query = value
    }
  }
  func enableLive() {
    guard ready else { return }
    snapshotOnly = false
    live = true
    prefs.root = root
    prefs.ignores = loadedIgnores.joined(separator: "\n")
    prefs.includes = loadedIncludes.joined(separator: "\n")
    do { try prefs.save() } catch { self.error = error.localizedDescription }
    setLive()
    startTimer()
  }
}
