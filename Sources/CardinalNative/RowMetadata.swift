import Foundation
import Darwin

// Filesystem calls can be slow on cold, cloud-backed or external paths. They must
// never occupy the serial search/page queue or delay a filename becoming visible.
final class RowMetadataOperation: Operation, @unchecked Sendable {
  let row: Row
  let completion: (RowMetadataOperation, Row) -> Void

  init(row: Row, completion: @escaping (RowMetadataOperation, Row) -> Void) {
    self.row = row
    self.completion = completion
  }

  override func main() {
    guard !isCancelled else { return }
    let attributes = try? FileManager.default.attributesOfItem(atPath: row.path)
    var info = stat()
    let allocatedSize: Int64? = lstat(row.path, &info) == 0 ? Int64(info.st_blocks) * 512 : nil
    func timestamp(_ key: FileAttributeKey) -> UInt32? {
      guard let date = attributes?[key] as? Date else { return nil }
      let seconds = date.timeIntervalSince1970
      return seconds > 0 && seconds <= Double(UInt32.max) ? UInt32(seconds) : nil
    }
    let result = Row(
      index: row.index, id: row.id, path: row.path,
      size: (attributes?[.size] as? NSNumber)?.int64Value,
      allocated_size: allocatedSize,
      modified: timestamp(.modificationDate), created: timestamp(.creationDate),
      is_directory: (attributes?[.type] as? FileAttributeType).map { $0 == .typeDirectory }
        ?? row.is_directory,
      metadata_loaded: true)
    guard !isCancelled else { return }
    DispatchQueue.main.async { self.completion(self, result) }
  }
}

extension Model {
  func cancelMetadata() {
    metadataQueue.cancelAllOperations()
    pendingMetadata.removeAll()
  }

  func loadVisibleMetadata(_ range: NSRange) {
    guard !closed, range.location != NSNotFound else { return }
    for (index, operation) in pendingMetadata where !NSLocationInRange(index, range) {
      operation.cancel()
      pendingMetadata.removeValue(forKey: index)
    }
    let ticket = displayedGeneration
    for index in range.location..<min(NSMaxRange(range), total) {
      guard let row = rows[index], !row.metadata_loaded, pendingMetadata[index] == nil else { continue }
      let operation = RowMetadataOperation(row: row) { [weak self] operation, loaded in
        guard let self = self, self.pendingMetadata[index] === operation else { return }
        self.pendingMetadata.removeValue(forKey: index)
        guard !self.closed, !operation.isCancelled, self.displayedGeneration == ticket,
          self.rows[index]?.path == loaded.path else { return }
        self.rows[index] = loaded
        self.revision &+= 1
      }
      pendingMetadata[index] = operation
      metadataQueue.addOperation(operation)
    }
  }
}
