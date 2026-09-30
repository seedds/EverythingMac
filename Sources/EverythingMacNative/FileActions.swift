import AppKit
import Darwin
import Quartz

final class PreviewController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
  var urls: [URL] = []
  var navigate: ((String) -> Void)?
  func show(_ paths: [String]) {
    urls = paths.map { URL(fileURLWithPath: $0) }
    guard !urls.isEmpty, let panel = QLPreviewPanel.shared() else { return }
    panel.dataSource = self
    panel.delegate = self
    panel.reloadData()
    panel.makeKeyAndOrderFront(nil)
  }
  var isVisible: Bool {
    QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared()?.isVisible == true
  }
  func hide() {
    if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared()?.orderOut(nil) }
  }
  func update(_ paths: [String]) {
    guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(),
      panel.isVisible
    else { return }
    urls = paths.map { URL(fileURLWithPath: $0) }
    panel.reloadData()
  }
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }
  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    urls[index] as NSURL
  }
  func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
    guard event.type == .keyDown else { return false }
    if event.keyCode == 125 || event.keyCode == 126 {
      navigate?(event.keyCode == 125 ? "down" : "up")
      return true
    }
    return false
  }
}
final class PreviewResponder: NSResponder {
  let preview: PreviewController
  init(preview: PreviewController) {
    self.preview = preview
    super.init()
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = preview
    panel.delegate = preview
  }
  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    panel.dataSource = nil
    panel.delegate = nil
  }
}

final class FileActions {
  weak var model: Model?
  let preview = PreviewController()
  let queue = DispatchQueue(label: "everything.mac.file-actions", qos: .userInitiated)
  let trashItem: (URL) throws -> Void
  /// Asked before trashing more than `trashConfirmationThreshold` items.
  let confirmTrash: (Int) -> Bool
  static let trashConfirmationThreshold = 50
  let pasteboard: NSPasteboard
  /// An action requested while the selection was loading; replaced by a newer request.
  private var pendingAction: DispatchWorkItem? {
    didSet { oldValue?.cancel() }
  }
  init(_ model: Model, trashItem: @escaping (URL) throws -> Void = {
    try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
  }, confirmTrash: @escaping (Int) -> Bool = FileActions.askToTrash,
    pasteboard: NSPasteboard = .general) {
    self.model = model
    self.trashItem = trashItem
    self.confirmTrash = confirmTrash
    self.pasteboard = pasteboard
    preview.navigate = { [weak model] in model?.tableAction?($0) }
  }
  func perform(_ action: String, paths explicitPaths: [String]? = nil) {
    guard let model = model else { return }
    pendingAction = nil
    if model.error == "Selection is loading; try again." { model.error = nil }
    // Every action (double-click, Space, F2, F8, F9, copy) waits for a click's
    // queued selection instead of failing while the engine is busy.
    if explicitPaths == nil, model.selectionLoading {
      let selection = model.selectionEpoch
      let index = model.indexEpoch
      let generation = model.generation
      let work = DispatchWorkItem { [weak self, weak model] in
        guard let self = self, let model = model else { return }
        self.pendingAction = nil
        guard !model.closed, model.activeTab == "files",
          model.selectionEpoch == selection, model.indexEpoch == index,
          model.generation == generation else { return }
        self.perform(action)
      }
      pendingAction = work
      // Resume on the next main turn, after the selection reply has been applied.
      model.selectionDidLoad = { [weak model] in
        model?.selectionDidLoad = nil
        DispatchQueue.main.async(execute: work)
      }
      return
    }
    guard let paths = explicitPaths else {
      // F9 needs only the first selected path, already retained by the UI.
      // Resolving row positions again races with live index/search updates and
      // needlessly expands large selections just to open one terminal window.
      if action == "terminal", model.selectionCount > 0, let path = model.selectedPaths.first {
        perform(action, paths: [path])
        return
      }
      model.resolveSelection { [weak self] paths in self?.perform(action, paths: paths) }
      return
    }
    guard !paths.isEmpty else { return }
    let urls = paths.map { URL(fileURLWithPath: $0) }
    switch action {
    case "open":
      for url in urls where !NSWorkspace.shared.open(url) {
        model.error = "Could not open \(url.path). It may have moved."
      }
    case "reveal": NSWorkspace.shared.activateFileViewerSelecting(urls)
    case "preview":
      if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared()?.isVisible == true {
        QLPreviewPanel.shared()?.orderOut(nil)
      } else {
        preview.show(paths)
      }
    case "copy":
      pasteboard.clearContents()
      pasteboard.writeObjects(urls as [NSURL])
    case "paths", "names":
      pasteboard.clearContents()
      pasteboard.setString(
        action == "paths"
          ? paths.joined(separator: "\n") : urls.map(\.lastPathComponent).joined(separator: " "),
        forType: .string)
    case "rename": rename(paths)
    case "trash":
      let targets = Self.trashTargets(paths)
      guard targets.count <= Self.trashConfirmationThreshold || confirmTrash(targets.count)
      else { return }
      let trashItem = self.trashItem
      run {
        // One failure must not leave the rest of the selection behind.
        var failures: [Error] = []
        for path in targets {
          do { try trashItem(URL(fileURLWithPath: path)) } catch { failures.append(error) }
        }
        if let first = failures.first {
          throw messageError(
            "Moved \(targets.count - failures.count) of \(targets.count) items to the Trash. \(first.localizedDescription)"
          )
        }
      }
    case "terminal":
      let app = model.prefs.terminalApplication
      run {
        let url = urls[0]
        let directory =
          (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
          ? url : url.deletingLastPathComponent()
        guard app.hasPrefix("/"), app.hasSuffix(".app"), FileManager.default.fileExists(atPath: app)
        else { throw messageError("Choose an installed terminal application in Preferences.") }
        try Self.launch(["-a", app, directory.path])
      }
    case "commander":
      run {
        try Self.launch(["-n", "-a", "Double Commander", "--args", "--client", "-T", paths[0]])
      }
    default: break
    }
  }
  func rename(_ paths: [String]) {
    guard paths.count == 1, let model = model else { return }
    let url = URL(fileURLWithPath: paths[0])
    let alert = NSAlert()
    alert.messageText = "Rename"
    alert.informativeText = url.path
    let field = NSTextField(string: url.lastPathComponent)
    field.frame = NSRect(x: 0, y: 0, width: 380, height: 24)
    alert.accessoryView = field
    alert.addButton(withTitle: "Rename")
    alert.addButton(withTitle: "Cancel")
    alert.window.initialFirstResponder = field
    field.selectText(nil)
    (field.currentEditor() as? NSTextView)?.setSelectedRange(
      NSRange(
        location: 0, length: (url.deletingPathExtension().lastPathComponent as NSString).length))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let name = field.stringValue
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
      model.error = "Enter a filename without slashes."
      return
    }
    run { _ = try Self.renameExclusive(path: url.path, name: name) }
  }
  static func renameExclusive(path: String, name: String) throws -> String {
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
      throw messageError("Invalid filename")
    }
    let destination = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(
      name
    ).path
    if path == destination { return destination }
    let result = path.withCString { from in
      destination.withCString { to in renamex_np(from, to, UInt32(RENAME_EXCL)) }
    }
    if result != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    return destination
  }

  /// Items inside a selected folder go to the Trash with that folder.
  static func trashTargets(_ paths: [String]) -> [String] {
    let selected = Set(paths)
    var seen = Set<String>()
    return paths.filter { path in
      var current = path
      while true {
        let parent = (current as NSString).deletingLastPathComponent
        if parent == current || parent.isEmpty { break }
        if selected.contains(parent) { return false }
        current = parent
      }
      return seen.insert(path).inserted
    }
  }
  static func askToTrash(_ count: Int) -> Bool {
    let alert = NSAlert()
    alert.messageText = "Move \(count) items to the Trash?"
    alert.informativeText = "You can restore them from the Trash in Finder."
    alert.addButton(withTitle: "Move to Trash")
    alert.addButton(withTitle: "Cancel")
    return alert.runModal() == .alertFirstButtonReturn
  }
  func run(_ operation: @escaping () throws -> Void) {
    queue.async { [weak self] in
      let result = Result { try operation() }
      DispatchQueue.main.async {
        guard let model = self?.model, !model.closed else { return }
        switch result {
        case .success:
          model.status = "File action completed"
          model.refreshPending = true
          model.poll()
        case .failure(let e): model.error = e.localizedDescription
        }
      }
    }
  }
  static func launch(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = arguments
    let error = Pipe()
    process.standardError = error
    try process.run()
    let data = error.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw messageError(String(data: data, encoding: .utf8) ?? "Application could not be opened.")
    }
  }
  static func openPrivacySettings() {
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
  }
}
