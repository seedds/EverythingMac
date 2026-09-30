import AppKit
import CNative
import Carbon
import Darwin
import SwiftUI

struct ContentView: View {
  @Bindable var model: Model
  var prefs: Preferences
  @State private var focusQuery: (() -> Void)?
  @State private var eventSelection = Set<FileEvent.ID>()

  private var searchText: Binding<String> {
    model.activeTab == "files" ? $model.query : $model.eventFilter
  }
  private var busy: Bool {
    model.searching || model.scanning || model.walking || (!model.ready && model.error == nil)
  }
  private var lifecycle: String {
    model.scanning || model.walking ? "Updating"
      : !model.ready ? "Initializing"
      : !model.live && !model.snapshotOnly ? "Paused" : "Ready"
  }

  var body: some View {
    VStack(spacing: 0) {
      searchBar.padding(10)
      notices
      Divider()
      if model.activeTab == "files" {
        ResultsTable(model: model).overlay { EmptyResults(model: model) }
      } else {
        eventsTable
      }
      Divider()
      GeometryReader { geometry in
        statusBar(showShortcuts: geometry.size.width >= 1100)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }.frame(height: 32)
        .background(.bar)
    }
    .frame(minWidth: 800, minHeight: 420)
    .onAppear {
      model.focusSearch = { focusQuery?() }
      focusQuery?()
    }
    .onChange(of: model.query) { model.changed() }
    .onChange(of: model.directory) { model.changed() }
    .onChange(of: model.sensitive) { model.changed() }
    .onChange(of: model.activeTab) {
      model.restoredSelection = nil
      model.selectionChanged(IndexSet())
      model.actions.preview.hide()
      eventSelection = []
      if model.activeTab == "events" {
        model.tableAction = nil
        model.resultsFocused = false
      }
      focusQuery?()
    }
  }

  private var searchBar: some View {
    HStack(spacing: 8) {
      Toggle(isOn: $model.sensitive) {
        Text("Aa").font(.system(size: 12, weight: .medium)).frame(width: 18)
      }
      .toggleStyle(.button)
      .help("Case sensitive")
      .accessibilityLabel("Case sensitive")
      Button { model.libraryOpen.toggle() } label: {
        Image(systemName: "clock.arrow.circlepath")
      }
      .help("Search Library").accessibilityLabel("Search Library")
      .popover(isPresented: $model.libraryOpen) {
        SearchLibraryView(model: model, library: model.library)
      }
      SearchField(
        text: searchText,
        placeholder: model.activeTab == "files"
          ? "Search for files and folders" : "Filter events by path or name",
        accessibilityLabel: model.activeTab == "files" ? "Search" : "Filter events",
        onSubmit: {
          guard model.activeTab == "files" else { return }
          model.rememberQuery()
          model.submit()
        },
        focus: { focus in DispatchQueue.main.async { focusQuery = focus } }
      )
      .help("Return: search · Down Arrow: results · Option-Up/Down Arrow: history")
      SearchField(
        text: $model.directory, placeholder: "Folder scope", symbol: "folder",
        accessibilityLabel: "Folder scope",
        onSubmit: { model.rememberQuery(); model.submit() }
      )
      .frame(width: 215)
      .disabled(model.activeTab != "files")
      .help("Filter file results by folder. Clear this field to search all folders.")
    }
    .controlSize(.large)
  }

  @ViewBuilder private var notices: some View {
    if !model.snapshotOnly && !model.hasFullDiskAccess {
      banner("Full Disk Access is required to search protected files.",
        symbol: "lock.shield", tint: .orange) {
        Button("Open System Settings…") { FileActions.openPrivacySettings() }
      }
    }
    if let error = model.error {
      banner(error, symbol: "exclamationmark.triangle.fill", tint: .red) {
        Button("Dismiss") { model.error = nil }
      }
    }
    if let message = model.shortcutMessage {
      banner(message, symbol: "keyboard", tint: .orange) {
        Button("Dismiss") { model.shortcutMessage = nil }
      }
    }
  }

  private func banner<Actions: View>(
    _ message: String, symbol: String, tint: Color, @ViewBuilder actions: () -> Actions
  ) -> some View {
    HStack(spacing: 8) {
      Label {
        Text(message).textSelection(.enabled).lineLimit(3)
      } icon: {
        Image(systemName: symbol).foregroundStyle(tint)
      }
      Spacer()
      actions()
    }
    .font(.callout).controlSize(.small)
    .padding(.horizontal, 12).padding(.bottom, 8)
  }

  private var eventsTable: some View {
    Table(model.filteredEvents, selection: $eventSelection) {
      TableColumn("Time") { event in
        Text(Date(timeIntervalSince1970: event.time), style: .time).monospacedDigit()
      }.width(min: 70, ideal: 90)
      TableColumn("Event", value: \.flags).width(min: 80, ideal: 180)
      TableColumn("Filename", value: \.name).width(min: 80, ideal: 200)
      TableColumn("Folder") { event in
        Text(event.folder).truncationMode(.middle).foregroundStyle(.secondary)
      }
    }
    .contextMenu(forSelectionType: FileEvent.ID.self) { ids in
      let paths = model.filteredEvents.filter { ids.contains($0.id) }.map(\.path)
      if !paths.isEmpty {
        Button("Open") { model.actions.perform("open", paths: paths) }
        Button("Reveal in Finder") { model.actions.perform("reveal", paths: paths) }
        Divider()
        Button("Copy Path") { model.actions.perform("paths", paths: paths) }
      }
    } primaryAction: { ids in
      let paths = model.filteredEvents.filter { ids.contains($0.id) }.map(\.path)
      if !paths.isEmpty { model.actions.perform("open", paths: paths) }
    }
  }

  private func statusBar(showShortcuts: Bool) -> some View {
    HStack(spacing: 10) {
      LifecycleStatus(
        busy: busy, hasError: model.error != nil, paused: lifecycle == "Paused", label: lifecycle
      ).help(indexDetails)
      ViewTabs(
        selection: $model.activeTab, files: model.indexedCount,
        events: model.processedEventCount)
      if model.scanning {
        Button { cn_cancel_scan() } label: { Image(systemName: "xmark.circle") }
          .help("Cancel scan").accessibilityLabel("Cancel scan")
      } else {
        Button { model.scan(useCurrentConfig: true) } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(!model.ready || model.snapshotOnly)
        .help("Rescan").accessibilityLabel("Rescan")
      }
      Spacer(minLength: 4)
      if showShortcuts && model.activeTab == "files" {
        Text("F2 Rename   F8 Trash   F9 Terminal").foregroundStyle(.secondary)
        Spacer(minLength: 4)
      }
      if model.selectionCount > 0 {
        Text("\(model.selectionCount.formatted()) selected").foregroundStyle(.secondary)
      }
      if model.activeTab == "files" {
        Text("Search: \(model.total.formatted()) · \(Int(model.backendMS.rounded())) ms")
          .monospacedDigit().help(model.status)
      }
    }
    .buttonStyle(.borderless).controlSize(.small)
    .font(.system(size: 11)).lineLimit(1).padding(.horizontal, 12)
  }

  /// Index details shown when hovering over the lifecycle status.
  private var indexDetails: String {
    [
      model.snapshotOnly ? "Read-only snapshot" : model.live ? "Live updates" : "Live updates paused",
      model.snapshot, model.snapshotDate, model.indexStatus,
    ].filter { !$0.isEmpty }.joined(separator: "\n")
  }
}

/// Reads the search state in its own view, so each search does not re-render the window.
struct EmptyResults: View {
  var model: Model
  var body: some View {
    if model.ready && !model.searching && model.total == 0 && model.error == nil {
      ContentUnavailableView.search(text: model.query)
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  let model: Model
  var window: NSWindow?
  private var windowDelegate: SearchWindowDelegate?
  private var previewResponder: PreviewResponder?
  private var launched = false
  private var started = false
  var benchmark: Benchmark?
  var scrollCheck: ScrollCheck?
  var selectionCheck: SelectionCheck?
  var rescanCheck: RescanCheck?
  var idleCheck: IdleCheck?
  var featureCheck: FeatureCheck?
  var selfCheck: SelfCheck?
  var liveCheck: LiveCheck?
  var helpWindow: NSWindow?
  let shortcutManager = ActivationShortcutManager()
  var handler: EventHandlerRef?
  var monitor: Any?
  var instanceLock: Int32 = -1
  override init() {
    let args = CommandLine.arguments
    let isolated = ["--benchmark", "--self-check", "--snapshot", "--live-check",
      "--scroll-check", "--selection-check", "--feature-check", "--icon-check", "--rescan-check",
      "--idle-check"]
      .contains(where: args.contains)
    model = Model(prefs: Preferences(isolated: isolated))
    model.snapshotOnly = isolated
    model.live = !isolated
    super.init()
  }

  @MainActor func attachSearchWindow(_ window: NSWindow) {
    guard self.window == nil else { return }
    self.window = window
    window.identifier = NSUserInterfaceItemIdentifier("EverythingMacSearch")
    windowDelegate = SearchWindowDelegate(forwarding: window.delegate)
    window.delegate = windowDelegate
    let responder = PreviewResponder(preview: model.actions.preview)
    responder.nextResponder = window.nextResponder
    window.nextResponder = responder
    previewResponder = responder
    NotificationCenter.default.addObserver(
      self, selector: #selector(searchWindowVisibilityChanged),
      name: NSWindow.didChangeOcclusionStateNotification, object: window)
    window.setContentSize(NSSize(width: 1200, height: 800))
    if !model.snapshotOnly { window.setFrameAutosaveName("EverythingMacWindow") }
    if model.snapshotOnly || !window.setFrameUsingName("EverythingMacWindow") { window.center() }
    startIfReady()
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    let args = CommandLine.arguments
    if let index = args.firstIndex(of: "--icon-check"), args.indices.contains(index + 1) {
      IconCheck.run(output: args[index + 1])
      return
    }
    launched = true
    startIfReady()
  }

  @MainActor private func startIfReady() {
    guard launched, let window = window, !started else { return }
    started = true
    let args = CommandLine.arguments
    let isolated = model.snapshotOnly
    let prefs = model.prefs
    var migrationError: Error?
    if !isolated {
      do {
        try FileManager.default.createDirectory(
          atPath: Preferences.directory, withIntermediateDirectories: true)
        instanceLock = Darwin.open(
          Preferences.directory + "/instance.lock", O_CREAT | O_WRONLY, 0o600)
        guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
          NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.everything.mac"
          )
          .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
          .activate()
          NSApp.terminate(nil)
          return
        }
        do { try IndexLocation.migrate(in: Preferences.directory) }
        catch { migrationError = error }
        try prefs.save()
      } catch { model.error = error.localizedDescription }
      if FileManager.default.fileExists(atPath: Preferences.index) {
        model.snapshot = Preferences.index
      }
    }
    if let index = args.firstIndex(of: "--index"), args.indices.contains(index + 1) {
      model.snapshot = args[index + 1]
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    prefs.applyShortcut = { [weak self] shortcut in
      guard let self = self, !self.model.snapshotOnly else { return }
      try self.shortcutManager.apply(shortcut)
      self.model.shortcutMessage = nil
    }
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self = self else { return event }
      return self.key(event)
    }
    if !isolated { registerShortcut() }
    if let index = args.firstIndex(of: "--feature-check"), args.indices.contains(index + 1) {
      featureCheck = FeatureCheck(model: model, window: window, delegate: self, output: args[index + 1])
      featureCheck?.start()
      return
    }
    if let index = args.firstIndex(of: "--benchmark"), args.indices.contains(index + 1) {
      benchmark = Benchmark(model: model, window: window, output: args[index + 1])
      benchmark?.start()
    }
    if let index = args.firstIndex(of: "--self-check"), args.indices.contains(index + 1) {
      selfCheck = SelfCheck(model: model, output: args[index + 1])
      selfCheck?.start()
    }
    if let index = args.firstIndex(of: "--scroll-check"), args.indices.contains(index + 1) {
      scrollCheck = ScrollCheck(model: model, window: window, output: args[index + 1])
      scrollCheck?.start()
    }
    if let index = args.firstIndex(of: "--live-check"), args.indices.contains(index + 1) {
      liveCheck = LiveCheck(model: model, output: args[index + 1])
      liveCheck?.start()
      return
    }
    if let index = args.firstIndex(of: "--rescan-check"), args.indices.contains(index + 2) {
      rescanCheck = RescanCheck(model: model, output: args[index + 1], index: args[index + 2])
      rescanCheck?.start()
      return
    }
    if let index = args.firstIndex(of: "--idle-check"), args.indices.contains(index + 2) {
      idleCheck = IdleCheck(
        model: model, window: window, output: args[index + 1], index: args[index + 2])
      idleCheck?.start()
      return
    }
    if let index = args.firstIndex(of: "--selection-check"), args.indices.contains(index + 1) {
      selectionCheck = SelectionCheck(model: model, window: window, output: args[index + 1])
      selectionCheck?.start()
      return
    }
    if let error = migrationError {
      model.error = "Cannot migrate the existing index: \(error.localizedDescription). The original index has been preserved."
      model.status = "Index unavailable"
      return
    }
    if FileManager.default.fileExists(atPath: model.snapshot) || isolated {
      model.load()
    } else {
      model.scan()
    }
  }
  @objc func showSearchHelp() {
    if helpWindow == nil {
      let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 600),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
      panel.title = "Search & Shortcuts"
      panel.isReleasedWhenClosed = false
      panel.contentView = NSHostingView(rootView: SearchHelpView(prefs: model.prefs) { [weak self] example in
        guard let self = self else { return }
        self.helpWindow?.orderOut(nil)
        self.showWindow()
        self.model.restoreSearch(SearchState(query: example, directory: "", sensitive: self.model.sensitive))
      })
      panel.center(); helpWindow = panel
    }
    helpWindow?.makeKeyAndOrderFront(nil)
  }
  @objc func searchWindowVisibilityChanged() { model.searchWindowVisibilityChanged() }
  @objc func showUpdates() {
    NSWorkspace.shared.open(URL(string: "https://github.com/seedds/EverythingMac/releases")!)
  }
  @objc func showWindow() {
    guard let window = window else { return }
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    model.focusSearch?()
  }
  @objc func toggleWindow() {
    guard let window = window else { return }
    if window.isVisible && NSApp.isActive { window.orderOut(nil) } else { showWindow() }
  }
  func registerShortcut() {
    var type = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, context in
        guard let context = context else { return OSStatus(eventNotHandledErr) }
        let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async {
          if !delegate.model.recordingShortcut { delegate.toggleWindow() }
        }
        return noErr
      }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    do { try shortcutManager.apply(model.prefs.shortcut) }
    catch { model.shortcutMessage = error.localizedDescription }
  }

  func key(_ event: NSEvent) -> NSEvent? {
    guard let window = window, window.isKeyWindow else { return event }
    // While an input method composes text (such as Pinyin candidates), Return,
    // Escape, and the arrow keys choose or cancel candidates; this monitor runs first.
    if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
    if event.modifierFlags.contains(.command),
      event.charactersIgnoringModifiers?.lowercased() == "f"
    {
      model.focusSearch?()
      return nil
    }
    if model.libraryOpen { return event }
    if event.keyCode == 53 {
      window.orderOut(nil)
      return nil
    }
    if window.firstResponder is NSTextView {
      if event.keyCode == 125 || event.keyCode == 126 {
        if event.modifierFlags.contains(.option) {
          model.navigateHistory(event.keyCode == 126 ? -1 : 1)
          return nil
        }
        if event.keyCode == 125
          && !event.modifierFlags.intersection([.command, .option, .control]).isEmpty
        {
          return event
        }
        if event.keyCode == 125 {
          model.rememberQuery()
          model.tableAction?("down")
          return nil
        }
      }
    }
    return event
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showWindow()
    // The existing window is shown; SwiftUI must not open another one.
    return window == nil
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard started, !model.closeFinished else { return .terminateNow }
    model.close { error in
      if let error = error {
        let alert = NSAlert()
        alert.messageText = "Native index could not be saved"
        alert.informativeText = error.localizedDescription
        alert.runModal()
      }
      self.featureCheck?.didFinishTermination(error)
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    guard !model.snapshotOnly else { return }
    model.hasFullDiskAccess = ["Library/Containers/com.apple.stocks", "Library/Safari"].contains {
      (try? FileManager.default.contentsOfDirectory(
        atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path))
        != nil
    }
  }
  func applicationWillTerminate(_ notification: Notification) {
    if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    try? shortcutManager.apply(nil)
    if let handler = handler { RemoveEventHandler(handler) }
    if instanceLock >= 0 { Darwin.close(instanceLock) }
  }
}

@main struct Main {
  static func main() {
    if let index = CommandLine.arguments.firstIndex(of: "--sort-check"),
      CommandLine.arguments.indices.contains(index + 1) {
      SortCheck.run(output: CommandLine.arguments[index + 1])
      return
    }
    if CommandLine.arguments.contains("--probe") {
      Probe.run()
      return
    }
    EverythingMacApp.main()
  }
}

struct EverythingMacApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

  private var model: Model { delegate.model }
  /// File commands act on the results table only when it has keyboard focus,
  /// so they never take shortcuts from the search fields.
  private var canActOnFiles: Bool {
    model.activeTab == "files" && model.resultsFocused && model.hasSelection
  }
  private var liveUpdates: Binding<Bool> {
    Binding(get: { model.live }, set: { enabled in
      model.live = enabled
      model.setLive()
    })
  }
  private var showsMenuBarIcon: Binding<Bool> {
    Binding(
      get: { model.prefs.tray && !model.snapshotOnly },
      set: { inserted in
        guard !model.snapshotOnly, inserted != model.prefs.tray else { return }
        do { try model.prefs.update { $0.tray = inserted } }
        catch { model.error = error.localizedDescription }
      })
  }

  var body: some Scene {
    WindowGroup("EverythingMac") {
      ContentView(model: delegate.model, prefs: delegate.model.prefs)
        .background(WindowReader { delegate.attachSearchWindow($0) })
    }
    .commands {
      // The index and selection belong to one search window.
      CommandGroup(replacing: .newItem) {
        Button("Close Window") {
          NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil)
        }.keyboardShortcut("w")
      }
      CommandGroup(after: .newItem) {
        Divider()
        Button("Open") { model.actions.perform("open") }
          .keyboardShortcut("o").disabled(!canActOnFiles)
        Button("Reveal in Finder") { model.actions.perform("reveal") }
          .keyboardShortcut("r").disabled(!canActOnFiles)
        Button("Quick Look") { model.actions.perform("preview") }
          .keyboardShortcut("y").disabled(!canActOnFiles)
        Button("Copy Path") { model.actions.perform("paths") }
          .keyboardShortcut("c", modifiers: [.command, .option]).disabled(!canActOnFiles)
        Divider()
        Button("Open Index…") { model.choose() }
          .keyboardShortcut("o", modifiers: [.command, .shift])
          .disabled(model.scanning || model.closed)
      }
      CommandGroup(after: .textEditing) {
        Button("Find") { model.focusSearch?() }.keyboardShortcut("f")
      }
      CommandGroup(before: .toolbar) {
        Picker("Show", selection: Bindable(model).activeTab) {
          Text("Files").keyboardShortcut("1").tag("files")
          Text("Events").keyboardShortcut("2").tag("events")
        }
        .pickerStyle(.inline)
        Divider()
      }
      CommandMenu("Index") {
        if model.snapshotOnly {
          Button("Enable Live Updates") { model.enableLive() }.disabled(!model.ready)
        } else {
          Toggle("Live Updates", isOn: liveUpdates).disabled(!model.ready || model.scanning)
        }
        Divider()
        Button("Rescan") { model.scan(useCurrentConfig: true) }
          .keyboardShortcut("r", modifiers: [.command, .option])
          .disabled(!model.ready || model.scanning || model.snapshotOnly)
        Button("Cancel Scan") { cn_cancel_scan() }.disabled(!model.scanning)
      }
      CommandGroup(replacing: .help) {
        Button("Search & Shortcuts") { delegate.showSearchHelp() }
          .keyboardShortcut("/")
        Button("Get Updates") { delegate.showUpdates() }
      }
    }
    Settings {
      SettingsContent(model: delegate.model)
    }
    MenuBarExtra("EverythingMac", systemImage: "magnifyingglass", isInserted: showsMenuBarIcon) {
      Button("Open EverythingMac") { delegate.showWindow() }
      Divider()
      Button("Quit EverythingMac") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
  }
}
