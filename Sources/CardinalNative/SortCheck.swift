import AppKit

// Exercise real header clicks and disk persistence without touching user preferences.
enum SortCheck {
  static func table(for model: Model) -> (ResultsView, ResultsTable.Coordinator) {
    let table = ResultsView()
    for name in Preferences.sortColumns.keys.sorted() {
      table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name)))
    }
    let coordinator = ResultsTable.Coordinator(model)
    coordinator.table = table
    coordinator.updateSortIndicator()
    return (table, coordinator)
  }

  static func run(output: String) {
    _ = NSApplication.shared
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("cardinal-sort-" + UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("preferences.json")
    var checks: [String] = []
    var failure: String?
    do {
      for (column, key) in Preferences.sortColumns.sorted(by: { $0.key < $1.key }) {
        let model = Model(prefs: Preferences(fileURL: file))
        let (table, coordinator) = table(for: model)
        let header = table.tableColumns.first { $0.identifier.rawValue == column }!
        for click in 1...3 {
          coordinator.tableView(table, didClick: header)
          if let error = model.error { throw messageError(error) }
          // No in-memory preferences or model state is shared with the reopened app.
          let reopened = Model(prefs: Preferences(fileURL: file))
          let expectedKey = click == 3 ? "" : key
          let ascending = click != 2
          guard reopened.sortKey == expectedKey, reopened.sortAscending == ascending else {
            throw messageError("\(column) sort state did not survive reopening")
          }
          let (newTable, newCoordinator) = self.table(for: reopened)
          newCoordinator.updateSortIndicator()
          for candidate in newTable.tableColumns {
            let image = newTable.indicatorImage(in: candidate)
            if candidate.identifier.rawValue == column && click != 3 {
              let expected = ascending ? NSImage.touchBarGoUpTemplateName : NSImage.touchBarGoDownTemplateName
              guard image != nil, image?.name() == expected else {
                throw messageError("\(column) sort arrow did not survive reopening")
              }
            } else if image != nil {
              throw messageError("Unexpected sort arrow on \(candidate.identifier.rawValue)")
            }
          }
          checks.append("\(column): \(click == 3 ? "unsorted" : ascending ? "ascending" : "descending") restored")
        }
      }
      try Data("{\"sortLimit\":1234}".utf8).write(to: file, options: .atomic)
      let legacy = Model(prefs: Preferences(fileURL: file))
      guard legacy.sortKey.isEmpty, legacy.sortAscending, legacy.prefs.sortLimit == 1234 else {
        throw messageError("Existing preferences without sort fields did not retain defaults")
      }
      try Data("{\"sortKey\":\"invalid\"}".utf8).write(to: file, options: .atomic)
      guard Model(prefs: Preferences(fileURL: file)).sortKey.isEmpty else {
        throw messageError("Invalid saved sort column was accepted")
      }
      checks.append("Existing and invalid preferences fall back to unsorted")
    } catch { failure = error.localizedDescription }
    do {
      try JSONSerialization.data(withJSONObject: ["checks": checks, "error": failure as Any? ?? NSNull()],
        options: [.prettyPrinted, .sortedKeys])
        .write(to: URL(fileURLWithPath: output, isDirectory: false))
    } catch { fputs("Sort-check report failed: \(error)\n", stderr); exit(1) }
    if failure != nil { exit(1) }
  }
}
