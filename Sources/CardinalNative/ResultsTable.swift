import AppKit
import SwiftUI

final class ResultsView: NSTableView {
  var firstDraw: ((UInt64) -> Void)?
  var resultGeneration: UInt64 = 0
  var fileAction: ((String) -> Void)?
  var focusSearch: (() -> Void)?
  var canDrag: ((IndexSet, NSPoint) -> Bool)?
  override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
    canDrag?(rowIndexes, mouseDownPoint) ?? false
  }
  var frameTimes: [Double] = []
  var recordDrawIntervals = false
  var previousDraw = 0.0
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let now = ProcessInfo.processInfo.systemUptime
    if recordDrawIntervals {
      if previousDraw > 0 { frameTimes.append((now - previousDraw) * 1000) }
      previousDraw = now
    }
    let drawnGeneration = resultGeneration
    DispatchQueue.main.async { [weak self] in self?.firstDraw?(drawnGeneration) }
  }
  override func keyDown(with event: NSEvent) {
    if event.modifierFlags.contains(.command),
      let key = event.charactersIgnoringModifiers?.lowercased()
    {
      if let command = [
        "o": "open", "r": "reveal", "c": event.modifierFlags.contains(.shift) ? "paths" : "copy",
      ][key] {
        fileAction?(command)
        return
      }
    }
    if event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
      if let command: String = [
        UInt16(49): "preview", 120: "rename", 100: "trash", 101: "terminal",
      ][event.keyCode] {
        fileAction?(command)
        return
      }
      if event.keyCode == 126 && selectedRow == 0 && !event.modifierFlags.contains(.shift) {
        deselectAll(nil)
        focusSearch?()
        return
      }
    }
    super.keyDown(with: event)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let row = row(at: convert(event.locationInWindow, from: nil))
    if row >= 0 && !selectedRowIndexes.contains(row) {
      selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
    return super.menu(for: event)
  }
  @objc func copy(_ sender: Any?) { fileAction?("copy") }

}

struct ResultsTable: NSViewRepresentable {
  @ObservedObject var model: Model
  func makeCoordinator() -> Coordinator { Coordinator(model) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    let table = ResultsView()
    table.rowHeight = 24
    table.usesAlternatingRowBackgroundColors = true
    table.allowsMultipleSelection = true
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    for (name, width) in [
      ("Name", 260.0), ("Path", 450.0), ("Size", 100.0), ("Modified", 155.0), ("Created", 155.0),
    ] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
      column.title = tr(
        "columns." + [
          "Name": "filename", "Path": "path", "Size": "size", "Modified": "modified",
          "Created": "created",
        ][name]!, name)
      column.width = model.prefs.tableColumns[name] ?? width
      table.addTableColumn(column)
    }
    table.dataSource = context.coordinator
    table.delegate = context.coordinator
    table.target = context.coordinator
    table.doubleAction = #selector(Coordinator.openSelected)
    table.fileAction = { [weak coordinator = context.coordinator] in
      coordinator?.actions.perform($0)
    }
    table.canDrag = { [weak coordinator = context.coordinator, weak table] indices, point in
      guard let table = table else { return false }
      return coordinator?.canDrag(table, indices: indices, point: point) ?? false
    }
    table.focusSearch = { [weak model] in model?.focusSearch?() }
    let menu = NSMenu()
    for (title, action) in [
      ("Open", "open"), ("Reveal in Finder", "reveal"), ("Quick Look", "preview"),
      ("Copy Files", "copy"), ("Copy Paths", "paths"), ("Copy Filenames", "names"),
      ("Rename…", "rename"), ("Move to Trash", "trash"), ("Open in Terminal", "terminal"),
      ("Reveal in Double Commander", "commander"), ("Reset Column Widths", "columns"),
    ] {
      let item = menu.addItem(
        withTitle: title, action: #selector(Coordinator.menuAction(_:)), keyEquivalent: "")
      item.representedObject = action
      item.target = context.coordinator
    }
    table.menu = menu
    table.setDraggingSourceOperationMask(.copy, forLocal: false)
    table.firstDraw = { [weak model] in model?.drew($0) }
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    context.coordinator.table = table
    scroll.contentView.postsBoundsChangedNotifications = true
    context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak model, weak table] _ in
      guard let table = table else { return }
      let range = table.rows(in: table.visibleRect)
      if range.location != NSNotFound { model?.visibleStart = range.location }
    }
    model.tableAction = { [weak coordinator = context.coordinator] in coordinator?.navigate($0) }
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) { context.coordinator.update() }

  final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSDraggingSource {
    let model: Model
    weak var table: ResultsView?
    var generation: UInt64 = 0
    var revision: UInt64 = .max
    let icons = FileIcons()
    let actions: FileActions
    var suppressSelection = false
    var scrollObserver: NSObjectProtocol?
    init(_ model: Model) {
      self.model = model
      actions = model.actions
    }
    deinit {
      if let observer = scrollObserver { NotificationCenter.default.removeObserver(observer) }
    }
    func update() {
      guard let table = table else { return }
      for column in table.tableColumns {
        let key = [
          "Name": "filename", "Path": "path", "Size": "size", "Modified": "modified",
          "Created": "created",
        ][column.identifier.rawValue]!
        column.title = tr("columns." + key, column.identifier.rawValue)
      }
      let keys = [
        "open": "contextMenu.openItem", "reveal": "contextMenu.revealInFinder",
        "preview": "contextMenu.quickLook", "copy": "contextMenu.copyFiles",
        "paths": "contextMenu.copyPaths", "names": "contextMenu.copyFilenames",
        "columns": "contextMenu.resetColumnWidths",
        "rename": "statusBar.shortcuts.rename", "trash": "statusBar.shortcuts.trash",
        "terminal": "statusBar.shortcuts.terminal", "commander": "contextMenu.revealInFinder",
      ]
      for item in table.menu?.items ?? [] {
        if let action = item.representedObject as? String, let key = keys[action] {
          item.title = tr(key, item.title)
          if action == "commander" {
            item.title = item.title.replacingOccurrences(of: "Finder", with: "Double Commander")
          }
        }
      }
      guard revision != model.revision else { return }
      let replaced = generation != model.displayedGeneration
      generation = model.displayedGeneration
      table.resultGeneration = generation
      revision = model.revision
      suppressSelection = true
      defer { suppressSelection = false }
      if replaced { table.deselectAll(nil) }
      // A full reload releases AppKit's old row state when the count
      // changes dramatically. Repeated same-count searches can reuse
      // visible cells without rebuilding their constraints.
      if table.numberOfRows != model.total { table.reloadData() }
      if replaced && !model.backgroundResult && model.total > 0 { table.scrollRowToVisible(0) }
      if let restored = model.restoredSelection {
        table.selectRowIndexes(
          restored.intersection(IndexSet(integersIn: 0..<model.total)), byExtendingSelection: false)
        model.restoredSelection = nil
        model.selectionChanged(table.selectedRowIndexes)
      }
      let range = table.rows(in: table.visibleRect)
      if range.location != NSNotFound && range.location < model.total {
        for row in range.location..<min(NSMaxRange(range), model.total) {
          for (column, descriptor) in table.tableColumns.enumerated() {
            if let cell = table.view(atColumn: column, row: row, makeIfNecessary: false)
              as? NSTableCellView
            {
              configure(cell, column: descriptor.identifier, row: row)
            }
          }
        }
      }
      table.needsDisplay = true
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.total }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      let column = tableColumn!.identifier
      let cell =
        (tableView.makeView(withIdentifier: column, owner: self) as? NSTableCellView)
        ?? makeCell(column)
      configure(cell, column: column, row: row)
      return cell
    }
    private func configure(_ cell: NSTableCellView, column: NSUserInterfaceItemIdentifier, row: Int)
    {
      cell.imageView?.image = nil
      cell.toolTip = nil
      guard let item = model.rows[row] else {
        cell.textField?.stringValue = column.rawValue == "Name" ? "Loading…" : ""
        DispatchQueue.main.async { [weak model] in model?.ensure(row) }
        return
      }
      switch column.rawValue {
      case "Name":
        cell.textField?.stringValue = URL(fileURLWithPath: item.path).lastPathComponent
        icon(item, cell: cell)
      case "Path":
        cell.textField?.stringValue =
          item.path == "/" ? "/" : URL(fileURLWithPath: item.path).deletingLastPathComponent().path
      case "Size":
        cell.textField?.stringValue =
          item.is_directory
          ? "—"
          : item.size.map {
            ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
          } ?? "—"
      default:
        cell.textField?.stringValue =
          (column.rawValue == "Created" ? item.created : item.modified).map {
            Date(timeIntervalSince1970: Double($0)).formatted(date: .numeric, time: .shortened)
          } ?? "—"
      }
      if column.rawValue == "Name" || column.rawValue == "Path", let label = cell.textField {
        let text = label.stringValue as NSString
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let value = NSMutableAttributedString(
          string: label.stringValue,
          attributes: [
            .paragraphStyle: paragraph, .font: NSFont.systemFont(ofSize: 13),
          ])
        for term in model.highlights where !term.isEmpty {
          var start = 0
          while start < text.length {
            let found = text.range(
              of: term, options: model.displayedSensitive ? [] : [.caseInsensitive],
              range: NSRange(location: start, length: text.length - start))
            if found.location == NSNotFound || found.length == 0 { break }
            value.addAttribute(
              .backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: found)
            start = NSMaxRange(found)
          }
        }
        label.attributedStringValue = value
      }
      cell.toolTip = item.path
      DispatchQueue.main.async { [weak model] in model?.ensure(row + 24) }
    }
    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
      let cell = NSTableCellView()
      cell.identifier = identifier
      let label = NSTextField(labelWithString: "")
      label.lineBreakMode = .byTruncatingMiddle
      label.maximumNumberOfLines = 1
      label.cell?.usesSingleLineMode = true
      label.cell?.wraps = false
      label.font = .systemFont(ofSize: 13)
      label.translatesAutoresizingMaskIntoConstraints = false
      cell.addSubview(label)
      cell.textField = label
      var leading = cell.leadingAnchor
      if identifier.rawValue == "Name" {
        let image = NSImageView()
        image.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(image)
        cell.imageView = image
        NSLayoutConstraint.activate([
          image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
          image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
          image.widthAnchor.constraint(equalToConstant: 16),
          image.heightAnchor.constraint(equalToConstant: 16),
        ])
        leading = image.trailingAnchor
      }
      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: leading, constant: 5),
        label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])
      return cell
    }
    private func icon(_ row: Row, cell: NSTableCellView) {
      cell.imageView?.image = icons.image(row) { [weak self] key, image in
        guard let self = self, let table = self.table else { return }
        let range = table.rows(in: table.visibleRect)
        guard range.location != NSNotFound else { return }
        for (index, current) in self.model.rows
        where NSLocationInRange(index, range) && FileIcons.key(current) == key {
          guard
            let visible = table.view(atColumn: 0, row: index, makeIfNecessary: false)
              as? NSTableCellView,
            visible.toolTip == current.path
          else { continue }
          visible.imageView?.image = image
        }
      }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
      guard !suppressSelection, let table = table else { return }
      model.selectionChanged(table.selectedRowIndexes)
    }
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
      let key = [
        "Name": "filename", "Path": "fullPath", "Size": "size", "Modified": "mtime",
        "Created": "ctime",
      ][tableColumn.identifier.rawValue]!
      model.sort(by: key)
      for column in tableView.tableColumns { tableView.setIndicatorImage(nil, in: column) }
      if !model.sortKey.isEmpty {
        tableView.setIndicatorImage(
          NSImage(
            named: model.sortAscending
              ? NSImage.touchBarGoUpTemplateName : NSImage.touchBarGoDownTemplateName),
          in: tableColumn)
      }
    }
    func tableViewColumnDidResize(_ notification: Notification) {
      guard let table = table else { return }
      for column in table.tableColumns {
        model.prefs.tableColumns[column.identifier.rawValue] = column.width
      }
      do { try model.prefs.save() } catch { model.error = error.localizedDescription }
    }
    func canDrag(
      _ tableView: NSTableView, indices rowIndexes: IndexSet, point mouseDownPoint: NSPoint
    ) -> Bool {
      if rowIndexes.allSatisfy({ model.rows[$0] != nil }) { return true }
      guard let event = NSApp.currentEvent else { return false }
      model.resolveSelection { [weak self, weak tableView] paths in
        guard let self = self, let table = tableView, NSEvent.pressedMouseButtons & 1 != 0,
          !paths.isEmpty
        else { return }
        let items = paths.map { path -> NSDraggingItem in
          let item = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: path) as NSURL)
          item.setDraggingFrame(
            NSRect(origin: mouseDownPoint, size: NSSize(width: 24, height: 24)),
            contents: NSImage(systemSymbolName: "doc", accessibilityDescription: nil))
          return item
        }
        table.beginDraggingSession(with: items, event: event, source: self)
      }
      return false
    }
    func draggingSession(
      _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation { .copy }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
      -> NSPasteboardWriting?
    {
      guard let row = model.rows[row] else { return nil }
      return URL(fileURLWithPath: row.path) as NSURL
    }
    @objc func menuAction(_ sender: NSMenuItem) {
      guard let action = sender.representedObject as? String else { return }
      if action == "columns" {
        for (column, width) in zip(table?.tableColumns ?? [], [260.0, 450, 100, 155, 155]) {
          column.width = width
        }
      } else {
        actions.perform(action)
      }
    }
    @objc func openSelected() { actions.perform("open") }
    func navigate(_ action: String) {
      guard let table = table, model.total > 0 else { return }
      let next =
        action == "up" ? max(0, table.selectedRow - 1) : min(model.total - 1, table.selectedRow + 1)
      table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
      table.scrollRowToVisible(next)
      model.ensure(next)
      table.window?.makeFirstResponder(table)
    }
  }
}
