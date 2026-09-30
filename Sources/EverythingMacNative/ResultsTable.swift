import AppKit
import SwiftUI

final class ResultCell: NSTableCellView {
  var representedPath: String?
}

final class ResultsView: NSTableView {
  var firstDraw: ((UInt64) -> Void)?
  var resultGeneration: UInt64 = 0
  var fileAction: ((String) -> Void)?
  var focusSearch: (() -> Void)?
  var canDrag: ((IndexSet, NSPoint) -> Bool)?
  /// Reports keyboard focus so file commands in the menu bar apply only to results.
  var focusChanged: ((Bool) -> Void)?
  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted { focusChanged?(true) }
    return accepted
  }
  override func resignFirstResponder() -> Bool {
    let accepted = super.resignFirstResponder()
    if accepted { focusChanged?(false) }
    return accepted
  }
  override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
    canDrag?(rowIndexes, mouseDownPoint) ?? false
  }
  var frameTimes: [Double] = []
  var recordDrawIntervals = false
  var previousDraw = 0.0
  /// Set while a result generation's first draw has not been reported.
  var awaitingFirstDraw = false
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    if recordDrawIntervals {
      let now = ProcessInfo.processInfo.systemUptime
      if previousDraw > 0 { frameTimes.append((now - previousDraw) * 1000) }
      previousDraw = now
    }
    guard awaitingFirstDraw else { return }
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
  /// Column identifiers and default widths, in their initial display order.
  static let columns: [(name: String, width: CGFloat)] = [
    ("Name", 260), ("Path", 450), ("Size", 100), ("Modified", 155), ("Created", 155),
  ]
  let model: Model
  func makeCoordinator() -> Coordinator { Coordinator(model) }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    let table = ResultsView()
    table.rowHeight = 24
    table.usesAlternatingRowBackgroundColors = true
    table.allowsMultipleSelection = true
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    for (name, width) in Self.columns {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
      column.title = name == "Name" ? "Filename" : name == "Size" ? "Size on disk" : name
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
    let groups: [[(String, String, String)]] = [
      [("Open", "open", "arrow.up.forward.app"), ("Reveal in Finder", "reveal", "folder"),
       ("Quick Look", "preview", "eye")],
      [("Copy Files", "copy", "doc.on.doc"), ("Copy Paths", "paths", "link"),
       ("Copy Filenames", "names", "textformat")],
      [("Rename…", "rename", "pencil"), ("Open in Terminal", "terminal", "terminal"),
       ("Reveal in Double Commander", "commander", "rectangle.split.2x1")],
      [("Move to Trash", "trash", "trash")],
    ]
    for group in groups {
      if !menu.items.isEmpty { menu.addItem(.separator()) }
      for (title, action, symbol) in group {
        let item = menu.addItem(
          withTitle: title, action: #selector(Coordinator.menuAction(_:)), keyEquivalent: "")
        item.representedObject = action
        item.target = context.coordinator
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
      }
    }
    table.menu = menu
    // Column layout belongs to the header, as in Finder.
    let headerMenu = NSMenu()
    let reset = headerMenu.addItem(
      withTitle: "Reset Column Widths", action: #selector(Coordinator.menuAction(_:)),
      keyEquivalent: "")
    reset.representedObject = "columns"
    reset.target = context.coordinator
    table.headerView?.menu = headerMenu
    table.setDraggingSourceOperationMask(.copy, forLocal: false)
    table.focusChanged = { [weak model] focused in
      if model?.resultsFocused != focused { model?.resultsFocused = focused }
    }
    table.firstDraw = { [weak model, weak table] in
      model?.drew($0)
      table?.awaitingFirstDraw = model?.pendingDraw != nil
    }
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.hasHorizontalScroller = true
    context.coordinator.table = table
    context.coordinator.updateSortIndicator()
    scroll.contentView.postsBoundsChangedNotifications = true
    context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
      forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
    ) { [weak model, weak table] _ in
      guard let table = table else { return }
      let range = table.rows(in: table.visibleRect)
      if range.location != NSNotFound {
        model?.visibleStart = range.location
        model?.loadVisibleMetadata(range)
        model?.ensure(NSMaxRange(range) + 24)
      }
    }
    model.tableAction = { [weak coordinator = context.coordinator] in coordinator?.navigate($0) }
    model.tableUpdate = { [weak coordinator = context.coordinator] in coordinator?.update() }
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
    var displayedSort: String?
    var columnSave: DispatchWorkItem?
    init(_ model: Model) {
      self.model = model
      actions = model.actions
    }
    deinit {
      if let observer = scrollObserver { NotificationCenter.default.removeObserver(observer) }
    }
    func update() {
      guard let table = table else { return }
      updateSortIndicator()
      guard revision != model.revision else { return }
      let replaced = generation != model.displayedGeneration
      generation = model.displayedGeneration
      table.resultGeneration = generation
      revision = model.revision
      suppressSelection = true
      defer { suppressSelection = false }
      if replaced && !model.backgroundResult { table.deselectAll(nil) }
      // A full reload releases AppKit's old row state when the count
      // changes dramatically. Repeated same-count searches can reuse
      // visible cells without rebuilding their constraints.
      if table.numberOfRows != model.total {
        if replaced && model.backgroundResult {
          table.noteNumberOfRowsChanged()
        } else {
          table.reloadData()
        }
      }
      if replaced && !model.backgroundResult && model.total > 0 { table.scrollRowToVisible(0) }
      if let restored = model.restoredSelection {
        let selection = restored.intersection(IndexSet(integersIn: 0..<model.total))
        if selection != table.selectedRowIndexes {
          table.selectRowIndexes(selection, byExtendingSelection: false)
        }
        model.restoredSelection = nil
      }
      if replaced {
        // The first-draw measurement needs a table draw for the new generation.
        table.awaitingFirstDraw = model.pendingDraw != nil
        table.needsDisplay = true
      }
      let dirty = model.dirtyRows
      model.dirtyRows = IndexSet()
      let range = table.rows(in: table.visibleRect)
      guard range.location != NSNotFound && range.location < model.total else { return }
      let visible = range.location..<min(NSMaxRange(range), model.total)
      model.loadVisibleMetadata(range)
      model.ensure(visible.upperBound + 24)
      // A replaced result set invalidates every visible cell; otherwise only
      // rows whose page or metadata arrived need new content.
      let rows = replaced ? IndexSet(integersIn: visible) : dirty.intersection(IndexSet(integersIn: visible))
      for row in rows {
        for (column, descriptor) in table.tableColumns.enumerated() {
          if let cell = table.view(atColumn: column, row: row, makeIfNecessary: false)
            as? ResultCell
          {
            configure(cell, column: descriptor.identifier, row: row)
          }
        }
      }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { model.total }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
      -> NSView?
    {
      let column = tableColumn!.identifier
      let cell =
        (tableView.makeView(withIdentifier: column, owner: self) as? ResultCell)
        ?? makeCell(column)
      configure(cell, column: column, row: row)
      return cell
    }
    private func configure(_ cell: ResultCell, column: NSUserInterfaceItemIdentifier, row: Int)
    {
      cell.imageView?.image = nil
      cell.toolTip = nil
      cell.representedPath = nil
      guard let item = model.rows[row] else {
        cell.textField?.stringValue = column.rawValue == "Name" ? "Loading…" : ""
        DispatchQueue.main.async { [weak model] in model?.ensure(row) }
        return
      }
      cell.representedPath = item.path
      guard let label = cell.textField else { return }
      switch column.rawValue {
      case "Name":
        // String-only parsing: URL(fileURLWithPath:) can stat the path on the UI thread.
        setText(label, (item.path as NSString).lastPathComponent, highlight: true)
        icon(item, cell: cell)
      case "Path":
        setText(
          label, item.path == "/" ? "/" : (item.path as NSString).deletingLastPathComponent,
          highlight: true)
      case "Size":
        label.stringValue =
          item.is_directory ? "—" : item.allocated_size.map(Self.sizes.string(fromByteCount:)) ?? "—"
      default:
        label.stringValue =
          (column.rawValue == "Created" ? item.created : item.modified).map {
            Self.dates.string(from: Date(timeIntervalSince1970: Double($0)))
          } ?? "—"
      }
    }
    static let sizes: ByteCountFormatter = {
      let formatter = ByteCountFormatter()
      formatter.countStyle = .file
      return formatter
    }()
    static let dates: DateFormatter = {
      let formatter = DateFormatter()
      formatter.dateStyle = .short
      formatter.timeStyle = .short
      return formatter
    }()
    static let truncating: NSParagraphStyle = {
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byTruncatingMiddle
      return paragraph
    }()
    /// Builds attributed text only when a highlighted term occurs in the value.
    private func setText(_ label: NSTextField, _ string: String, highlight: Bool) {
      let text = string as NSString
      var ranges: [NSRange] = []
      if highlight {
        let options: NSString.CompareOptions = model.displayedSensitive ? [] : [.caseInsensitive]
        for term in model.highlights where !term.isEmpty {
          var start = 0
          while start < text.length {
            let found = text.range(
              of: term, options: options,
              range: NSRange(location: start, length: text.length - start))
            if found.location == NSNotFound || found.length == 0 { break }
            ranges.append(found)
            start = NSMaxRange(found)
          }
        }
      }
      guard !ranges.isEmpty else {
        label.stringValue = string
        return
      }
      let value = NSMutableAttributedString(
        string: string,
        attributes: [
          .paragraphStyle: Self.truncating, .font: NSFont.systemFont(ofSize: 13),
          // Semantic colors follow dark mode and emphasized (selected) rows.
          .foregroundColor: label.textColor ?? .labelColor,
        ])
      for range in ranges {
        value.addAttribute(
          .backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.45), range: range)
      }
      label.attributedStringValue = value
    }
    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> ResultCell {
      let cell = ResultCell()
      cell.identifier = identifier
      let label = NSTextField(labelWithString: "")
      label.lineBreakMode = .byTruncatingMiddle
      label.maximumNumberOfLines = 1
      label.cell?.usesSingleLineMode = true
      label.cell?.wraps = false
      label.font = .systemFont(ofSize: 13)
      if identifier.rawValue != "Name" { label.textColor = .secondaryLabelColor }
      if identifier.rawValue != "Name" && identifier.rawValue != "Path" {
        // Numbers and dates align on their right edge, as in Finder.
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
      }
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
    private func icon(_ row: Row, cell: ResultCell) {
      cell.imageView?.image = icons.image(row) { [weak self] key, image in
        self?.iconLoaded(key, image)
      }
    }
    /// Shows a finished icon in matching visible cells. Visible rows whose request
    /// was skipped while the loader was saturated are requested again.
    private func iconLoaded(_ key: String, _ image: NSImage) {
      guard let table = table else { return }
      // Columns can be reordered, so the Name column is not necessarily first.
      let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier("Name"))
      let range = table.rows(in: table.visibleRect)
      guard column >= 0, range.location != NSNotFound else { return }
      for index in range.location..<NSMaxRange(range) {
        guard
          let visible = table.view(atColumn: column, row: index, makeIfNecessary: false)
            as? ResultCell,
          let current = model.rows[index], visible.representedPath == current.path
        else { continue }
        if FileIcons.key(current) == key {
          visible.imageView?.image = image
        } else if visible.imageView?.image == nil {
          icon(current, cell: visible)
        }
      }
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
      guard !suppressSelection, let table = table else { return }
      model.selectionChanged(table.selectedRowIndexes)
    }
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
      let key = Preferences.sortColumns[tableColumn.identifier.rawValue]!
      model.sort(by: key)
      updateSortIndicator()
    }
    func updateSortIndicator() {
      guard let table = table else { return }
      let state = "\(model.sortKey):\(model.sortAscending)"
      guard displayedSort != state else { return }
      displayedSort = state
      for column in table.tableColumns {
        let selected = Preferences.sortColumns[column.identifier.rawValue] == model.sortKey
        let image = selected ? NSImage(named: model.sortAscending
          ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator") : nil
        table.setIndicatorImage(image, in: column)
        if selected { table.highlightedTableColumn = column }
      }
      if model.sortKey.isEmpty { table.highlightedTableColumn = nil }
    }
    func tableViewColumnDidResize(_ notification: Notification) {
      guard let table = table else { return }
      for column in table.tableColumns {
        model.prefs.tableColumns[column.identifier.rawValue] = column.width
      }
      // Resizing posts many notifications per drag; write once it settles.
      columnSave?.cancel()
      let work = DispatchWorkItem { [weak model] in
        guard let model = model else { return }
        do { try model.prefs.save() } catch { model.error = error.localizedDescription }
      }
      columnSave = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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
          let item = NSDraggingItem(pasteboardWriter: fileURL(path) as NSURL)
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
      return fileURL(row.path) as NSURL
    }
    @objc func menuAction(_ sender: NSMenuItem) {
      guard let action = sender.representedObject as? String else { return }
      if action == "columns" {
        // Match by identifier: the display order changes when columns are dragged.
        for (name, width) in ResultsTable.columns {
          table?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(name))?.width = width
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
