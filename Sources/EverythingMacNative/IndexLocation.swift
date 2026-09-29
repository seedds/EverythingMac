import Foundation

enum IndexLocation {
  static let filename = "everything-mac.db"
  // Compatibility with EverythingMac versions that used the upstream Cardinal filename.
  static let legacyFilename = "cardinal.db"

  static func existingIndex(in directory: String) -> String {
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    let current = root.appendingPathComponent(filename).path
    let legacy = root.appendingPathComponent(legacyFilename).path
    let files = FileManager.default
    return !files.fileExists(atPath: current) && files.fileExists(atPath: legacy) ? legacy : current
  }

  // Call only after taking the app instance lock. Snapshot and diagnostic modes never migrate.
  static func migrate(in directory: String) throws {
    let root = URL(fileURLWithPath: directory, isDirectory: true)
    let current = root.appendingPathComponent(filename)
    let legacy = root.appendingPathComponent(legacyFilename)
    let files = FileManager.default
    guard !files.fileExists(atPath: current.path), files.fileExists(atPath: legacy.path) else { return }
    try files.moveItem(at: legacy, to: current)
  }
}
