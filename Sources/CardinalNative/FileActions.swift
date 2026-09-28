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
final class NativeWindow: NSWindow {
  var preview: PreviewController?
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
  let queue = DispatchQueue(label: "cardinal.native.file-actions", qos: .userInitiated)
  let trashItem: (URL) throws -> Void
  init(_ model: Model, trashItem: @escaping (URL) throws -> Void = {
    try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
  }) {
    self.model = model
    self.trashItem = trashItem
    preview.navigate = { [weak model] in model?.tableAction?($0) }
  }
  func perform(_ action: String, paths explicitPaths: [String]? = nil) {
    guard let model = model else { return }
    guard explicitPaths != nil || !model.selectionLoading else {
      model.error = "Selection is loading; try again."
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
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects(urls as [NSURL])
    case "paths", "names":
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(
        action == "paths"
          ? paths.joined(separator: "\n") : urls.map(\.lastPathComponent).joined(separator: " "),
        forType: .string)
    case "rename": rename(paths)
    case "trash":
      let trashItem = self.trashItem
      run { for url in urls { try trashItem(url) } }
    case "terminal":
      let app = model.prefs.terminal
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
