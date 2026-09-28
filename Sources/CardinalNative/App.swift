import AppKit
import CNative
import Carbon
import Darwin
import SwiftUI

struct ContentView: View {
  @ObservedObject var model: Model
  @ObservedObject var prefs: Preferences
  @FocusState var searchFocused: Bool
  @FocusState var directoryFocused: Bool
  @State private var indexDetailsOpen = false

  private var searchText: Binding<String> {
    model.activeTab == "files" ? $model.query : $model.eventFilter
  }
  private var busy: Bool {
    model.searching || model.scanning || model.selectionLoading
      || (!model.ready && model.error == nil)
  }
  private var lifecycle: String {
    model.scanning ? "Updating" : model.ready ? "Ready" : "Initializing"
  }

  var body: some View {
    VStack(spacing: 0) {
      searchBar.padding(10)
      notices
      if model.activeTab == "files" {
        ResultsTable(model: model).overlay(alignment: .center) {
          if model.ready && !model.searching && model.total == 0 && model.error == nil {
            Text("No matching files").foregroundColor(.secondary)
          }
        }
      } else {
        eventsList
      }
      Divider()
      GeometryReader { geometry in
        statusBar(showShortcuts: geometry.size.width >= 1100)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }.frame(height: 36)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    .background(Color(nsColor: .textBackgroundColor))
    .frame(minWidth: 800, minHeight: 420)
    .onAppear {
      model.focusSearch = { searchFocused = true }
      searchFocused = true
    }
    .onChange(of: model.query) { _ in model.changed() }
    .onChange(of: model.directory) { _ in model.changed() }
    .onChange(of: model.activeTab) { _ in
      model.restoredSelection = nil
      model.selectionChanged(IndexSet())
      model.actions.preview.hide()
      if model.activeTab == "events" { model.tableAction = nil }
      searchFocused = true
    }
    .sheet(isPresented: $model.preferencesOpen) { PreferencesView(prefs: prefs, model: model) }
  }

  private var searchBar: some View {
    HStack(spacing: 6) {
      Button {
        model.sensitive.toggle()
        model.changed()
      } label: {
        Text("Aa").font(.system(size: 12, weight: .medium))
          .foregroundColor(model.sensitive ? .accentColor : .secondary)
          .frame(width: 34, height: 32)
          .background(
            RoundedRectangle(cornerRadius: 9).fill(
              model.sensitive
                ? Color.accentColor.opacity(0.13) : Color(nsColor: .controlBackgroundColor))
          )
          .overlay(
            RoundedRectangle(cornerRadius: 9).strokeBorder(
              model.sensitive
                ? Color.accentColor.opacity(0.5) : Color(nsColor: .separatorColor).opacity(0.4)))
      }.buttonStyle(.plain)
        .help("Case sensitive")
        .accessibilityLabel("Case sensitive")
        .accessibilityValue(model.sensitive ? "On" : "Off")
      TextField(
        model.activeTab == "files" ? "Search for files and folders…" : "Filter events by path or name…",
        text: searchText
      )
      .textFieldStyle(.plain).focused($searchFocused)
      .onSubmit {
        if model.activeTab == "files" {
          model.rememberQuery()
          model.submit()
        }
      }
      .padding(.horizontal, 10).frame(height: 32)
      .background(searchFieldBackground)
      .help("Enter: search · Down: results · Option-Up/Down: history")
      TextField("Folder scope…", text: $model.directory)
        .textFieldStyle(.plain).focused($directoryFocused)
        .onSubmit { model.submit() }
        .padding(.horizontal, 10).frame(width: 215, height: 32)
        .background(searchFieldBackground)
        .disabled(model.activeTab != "files")
        .accessibilityLabel("Folder scope")
        .help("Filter file results by folder. Clear this field to search all folders.")
    }.font(.system(size: 13))
  }

  private var searchFieldBackground: some View {
    RoundedRectangle(cornerRadius: 9).fill(Color(nsColor: .controlBackgroundColor))
      .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor.opacity(0.18)))
  }

  @ViewBuilder private var notices: some View {
    if !model.snapshotOnly && !model.hasFullDiskAccess {
      HStack(spacing: 8) {
        Image(systemName: "lock.shield")
        Text("Full Disk Access Required")
          .help(
            "Enable Full Disk Access to search protected files.")
        Spacer()
        Button("Open System Settings") {
          FileActions.openPrivacySettings()
        }
      }.font(.caption).foregroundColor(.orange).padding(.horizontal, 12).padding(.bottom, 8)
    }
    if let error = model.error {
      HStack {
        Text(error).foregroundColor(.red).textSelection(.enabled)
        Spacer()
        Button("Dismiss") { model.error = nil }
      }.font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
    }
    if let message = model.shortcutMessage {
      Text(message).font(.caption).foregroundColor(.orange)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(
          .bottom, 8)
    }
  }

  private var eventsList: some View {
    VStack(spacing: 0) {
      HStack {
        Text("Time").frame(width: 90, alignment: .leading)
        Text("Event").frame(width: 180, alignment: .leading)
        Text("Filename").frame(width: 180, alignment: .leading)
        Text("Path").frame(maxWidth: .infinity, alignment: .leading)
      }.font(.system(size: 12, weight: .medium)).foregroundColor(.secondary)
        .padding(.horizontal, 10).frame(height: 25).background(
          Color(nsColor: .windowBackgroundColor))
      List(
        model.events.filter {
          model.eventFilter.isEmpty
            || $0.path.range(
              of: model.eventFilter, options: model.sensitive ? [] : [.caseInsensitive]) != nil
        }
      ) { event in
        HStack {
          Text(Date(timeIntervalSince1970: event.time), style: .time).frame(
            width: 90, alignment: .leading)
          Text(event.flags).frame(width: 180, alignment: .leading)
          Text(URL(fileURLWithPath: event.path).lastPathComponent).frame(
            width: 180, alignment: .leading
          ).lineLimit(1)
          Text(URL(fileURLWithPath: event.path).deletingLastPathComponent().path).lineLimit(1)
            .truncationMode(.middle)
        }.font(.system(size: 12)).lineLimit(1).frame(height: 24).textSelection(.enabled)
          .contextMenu {
            Button("Open") {
              model.actions.perform("open", paths: [event.path])
            }
            Button("Reveal in Finder") {
              model.actions.perform("reveal", paths: [event.path])
            }
            Button("Copy Path") {
              model.actions.perform("paths", paths: [event.path])
            }
          }
      }.listStyle(.plain)
    }
  }

  private func tab(_ key: String, count: Int) -> some View {
    Button {
      model.activeTab = key
    } label: {
      HStack(spacing: 5) {
        Text(key.capitalized)
        Text(count.formatted()).monospacedDigit().foregroundColor(.secondary)
      }.padding(.horizontal, 9).frame(height: 24)
        .background(
          Capsule().fill(model.activeTab == key ? Color(nsColor: .controlBackgroundColor) : .clear))
    }.buttonStyle(.plain)
      .accessibilityAddTraits(model.activeTab == key ? [.isSelected] : [])
  }

  private func statusBar(showShortcuts: Bool) -> some View {
    HStack(spacing: 10) {
      LifecycleStatus(
        busy: busy, hasError: model.error != nil, label: lifecycle
      ).help(model.indexStatus)
      HStack(spacing: 1) {
        tab("files", count: model.indexedCount)
        tab("events", count: model.processedEventCount)
      }.padding(2).background(Capsule().fill(Color.primary.opacity(0.06)))
      if model.scanning {
        Button {
          cn_cancel_scan()
        } label: {
          Image(systemName: "xmark.circle").frame(width: 14, height: 14)
        }
        .help("Cancel scan").accessibilityLabel(
          "Cancel scan")
      } else {
        Button {
          model.scan(useCurrentConfig: true)
        } label: {
          Image(systemName: "arrow.clockwise").frame(width: 14, height: 14)
        }
        .disabled(!model.ready || model.snapshotOnly)
        .help("Rescan").accessibilityLabel(
          "Rescan")
      }
      Button {
        model.preferencesOpen = true
      } label: {
        Image(systemName: "gearshape")
      }
      .help("Open preferences").accessibilityLabel(
        "Open preferences")
      Button {
        indexDetailsOpen.toggle()
      } label: {
        Image(systemName: "info.circle")
      }
      .help("Index details")
      .accessibilityLabel("Index details")
      .popover(isPresented: $indexDetailsOpen, arrowEdge: .top) { indexDetails }
      Spacer(minLength: 4)
      if showShortcuts && model.activeTab == "files" {
        Text(
          "F2 Rename   F8 Trash   F9 Terminal"
        )
        .foregroundColor(.secondary)
        Spacer(minLength: 4)
      }
      if model.selectionCount > 0 {
        Text(
          "\(model.selectionCount.formatted()) selected"
        )
        .foregroundColor(.secondary)
      }
      if model.activeTab == "files" {
        Text(
          "Search: \(model.total.formatted()) · \(Int(model.backendMS.rounded())) ms"
        )
        .monospacedDigit().help(model.status)
      }
    }.buttonStyle(.plain).font(.system(size: 11)).lineLimit(1).padding(.horizontal, 12)
  }

  private var indexDetails: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(
        model.snapshotOnly
          ? "Read-only snapshot" : "Live updates"
      ).font(.headline)
      Text(model.snapshot).font(.caption).textSelection(.enabled).fixedSize(
        horizontal: false, vertical: true)
      Text(model.snapshotDate).font(.caption).foregroundColor(.secondary)
      Text(model.indexStatus).font(.caption).foregroundColor(.secondary)
      Text(model.status).font(.caption).foregroundColor(.secondary)
      Divider()
      if model.snapshotOnly {
        Button("Enable live updates") { model.enableLive() }.disabled(
          !model.ready)
      } else {
        Toggle("Live updates", isOn: $model.live)
          .onChange(of: model.live) { _ in model.setLive() }.disabled(!model.ready)
      }
      HStack {
        Button("Choose index…") {
          indexDetailsOpen = false
          model.choose()
        }
        Button("Index folder…") {
          indexDetailsOpen = false
          model.chooseFolder()
        }.disabled(model.scanning)
      }
      Picker("Delay", selection: $model.debounce) {
        Text("0 ms").tag(0)
        Text("100 ms").tag(100)
        Text("300 ms").tag(300)
      }
    }.padding(18).frame(width: 390)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var model: Model!
  var window: NativeWindow!
  var actions: FileActions!
  var benchmark: Benchmark?
  var scrollCheck: ScrollCheck?
  var selectionCheck: SelectionCheck?
  var selfCheck: SelfCheck?
  var liveCheck: LiveCheck?
  var statusItem: NSStatusItem?
  var hotKey: EventHotKeyRef?
  var handler: EventHandlerRef?
  var monitor: Any?
  var instanceLock: Int32 = -1
  func applicationDidFinishLaunching(_ notification: Notification) {
    let args = CommandLine.arguments
    let isolated =
      args.contains("--benchmark") || args.contains("--self-check") || args.contains("--snapshot")
      || args.contains("--live-check") || args.contains("--scroll-check")
      || args.contains("--selection-check")
    let prefs = Preferences(isolated: isolated)
    model = Model(prefs: prefs)
    model.snapshotOnly = isolated
    model.live = !isolated
    if !isolated {
      do {
        try FileManager.default.createDirectory(
          atPath: Preferences.directory, withIntermediateDirectories: true)
        instanceLock = Darwin.open(
          Preferences.directory + "/instance.lock", O_CREAT | O_WRONLY, 0o600)
        guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
          NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.cardinal.native-prototype"
          )
          .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier })?
          .activate(options: .activateIgnoringOtherApps)
          NSApp.terminate(nil)
          return
        }
        try prefs.save()
      } catch { model.error = error.localizedDescription }
      if FileManager.default.fileExists(atPath: Preferences.index) {
        model.snapshot = Preferences.index
      }
    }
    if let index = args.firstIndex(of: "--index"), args.indices.contains(index + 1) {
      model.snapshot = args[index + 1]
    }
    actions = model.actions
    window = NativeWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "EverythingMac"
    window.delegate = self
    window.preview = actions.preview
    window.contentView = NSHostingView(rootView: ContentView(model: model, prefs: prefs))
    if !isolated { window.setFrameAutosaveName("CardinalNativeWindow") }
    if isolated || !window.setFrameUsingName("CardinalNativeWindow") { window.center() }
    window.makeKeyAndOrderFront(nil)
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    prefs.onApply = { [weak self] in
      self?.configureMenu()
      self?.configureTray()
    }
    configureMenu()
    configureTray()
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      guard let self = self else { return event }
      return self.key(event)
    }
    if !isolated { registerShortcut() }
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
    if let index = args.firstIndex(of: "--selection-check"), args.indices.contains(index + 1) {
      selectionCheck = SelectionCheck(model: model, window: window, output: args[index + 1])
      selectionCheck?.start()
      return
    }
    if FileManager.default.fileExists(atPath: model.snapshot) || isolated {
      model.load()
    } else {
      model.scan()
    }
  }
  func configureMenu() {
    let menu = NSMenu()
    func submenu(_ title: String) -> NSMenu {
      let item = NSMenuItem()
      let child = NSMenu(title: title)
      item.submenu = child
      menu.addItem(item)
      return child
    }
    let app = submenu("EverythingMac")
    app.addItem(
      withTitle: "About EverythingMac",
      action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    let preferences = app.addItem(
      withTitle: "Preferences…", action: #selector(showPreferences),
      keyEquivalent: ",")
    preferences.target = self
    app.addItem(
      withTitle: "Hide", action: #selector(NSApplication.hide(_:)),
      keyEquivalent: "h")
    app.addItem(
      withTitle: "Quit EverythingMac", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "q")
    let edit = submenu("Edit")
    for (title, action, key) in [
      ("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a"),
    ] {
      edit.addItem(
        withTitle: title, action: Selector(action),
        keyEquivalent: key)
    }
    let view = submenu("View")
    view.addItem(
      withTitle: "Toggle Fullscreen",
      action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f"
    ).keyEquivalentModifierMask = [.control, .command]
    let windows = submenu("Window")
    windows.addItem(
      withTitle: "Minimize",
      action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windows.addItem(
      withTitle: "Close Window",
      action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    NSApp.windowsMenu = windows
    let help = submenu("Help")
    let updates = help.addItem(
      withTitle: "Get Updates", action: #selector(showUpdates),
      keyEquivalent: "")
    updates.target = self
    NSApp.mainMenu = menu
  }
  @objc func showPreferences() { model.preferencesOpen = true }
  @objc func showUpdates() {
    NSWorkspace.shared.open(URL(string: "https://github.com/seedds/cardinal_native/releases")!)
  }
  @objc func showWindow() {
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    model.focusSearch?()
  }
  @objc func toggleWindow() {
    if window.isVisible && NSApp.isActive { window.orderOut(nil) } else { showWindow() }
  }
  func configureTray() {
    if let old = statusItem {
      NSStatusBar.system.removeStatusItem(old)
      statusItem = nil
    }
    guard model.prefs.tray && !model.snapshotOnly else { return }
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.button?.image = NSImage(
      systemSymbolName: "magnifyingglass", accessibilityDescription: "EverythingMac")
    let menu = NSMenu()
    let open = menu.addItem(
      withTitle: "Open EverythingMac", action: #selector(showWindow),
      keyEquivalent: "")
    open.target = self
    menu.addItem(
      withTitle: "Quit", action: #selector(NSApplication.terminate(_:)),
      keyEquivalent: "")
    item.menu = menu
    statusItem = item
  }
  func registerShortcut() {
    var type = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
    InstallEventHandler(
      GetApplicationEventTarget(),
      { _, _, context in
        guard let context = context else { return OSStatus(eventNotHandledErr) }
        let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { delegate.toggleWindow() }
        return noErr
      }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    let result = RegisterEventHotKey(
      UInt32(kVK_Space), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x4341_5244, id: 1),
      GetApplicationEventTarget(), 0, &hotKey)
    if result != noErr {
      model.shortcutMessage =
        "Command-Shift-Space is already in use. Quit the other EverythingMac or Cardinal app to use this shortcut here."
    }
  }
  func key(_ event: NSEvent) -> NSEvent? {
    guard window.isKeyWindow, !model.preferencesOpen else { return event }
    if event.modifierFlags.contains(.command),
      event.charactersIgnoringModifiers?.lowercased() == "f"
    {
      model.focusSearch?()
      return nil
    }
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
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showWindow()
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let model = model, window != nil, !model.closeFinished else { return .terminateNow }
    model.close { error in
      if let error = error {
        let alert = NSAlert()
        alert.messageText = "Native index could not be saved"
        alert.informativeText = error.localizedDescription
        alert.runModal()
      }
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    guard let model = model, !model.snapshotOnly else { return }
    model.hasFullDiskAccess = ["Library/Containers/com.apple.stocks", "Library/Safari"].contains {
      (try? FileManager.default.contentsOfDirectory(
        atPath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent($0).path))
        != nil
    }
  }
  func applicationWillTerminate(_ notification: Notification) {
    if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
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
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.run()
    withExtendedLifetime(delegate) {}
  }
}
