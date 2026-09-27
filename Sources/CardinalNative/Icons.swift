import AppKit
import Darwin
import QuickLookThumbnailing

final class FileIcons {
  let basic = NSCache<NSString, NSImage>()
  let thumbnails = NSCache<NSString, NSImage>()
  let queue = DispatchQueue(label: "cardinal.native.icons", qos: .utility)
  var pending = Set<String>()
  var requests: [String: QLThumbnailGenerator.Request] = [:]
  var attempted = Set<String>()
  init() {
    basic.countLimit = 512
    thumbnails.countLimit = 512
  }
  static func key(_ row: Row) -> String {
    "\(row.path)|\(row.size ?? -1)|\(row.modified ?? 0)|\(row.created ?? 0)|\(row.is_directory)"
  }
  func image(_ row: Row, thumbnails enabled: Bool, completion: @escaping (String, NSImage) -> Void)
    -> NSImage?
  {
    let key = Self.key(row)
    if enabled, let image = thumbnails.object(forKey: key as NSString) { return image }
    let cached = basic.object(forKey: key as NSString)
    if cached == nil && !pending.contains(key) && pending.count < 64 {
      pending.insert(key)
      queue.async { [weak self] in
        let image = NSWorkspace.shared.icon(forFile: row.path)
        DispatchQueue.main.async {
          guard let self = self else { return }
          self.pending.remove(key)
          self.basic.setObject(image, forKey: key as NSString)
          completion(key, self.thumbnails.object(forKey: key as NSString) ?? image)
        }
      }
    }
    if enabled && !row.is_directory && row.size != nil && requests.count < 4
      && !attempted.contains(key)
    {
      var info = stat()
      // Do not materialize cloud-only file contents for a thumbnail.
      if lstat(row.path, &info) == 0 && info.st_flags & 0x4000_0000 == 0 {
        if attempted.count >= 512 { attempted.removeAll(keepingCapacity: true) }
        attempted.insert(key)
        let request = QLThumbnailGenerator.Request(
          fileAt: URL(fileURLWithPath: row.path), size: CGSize(width: 32, height: 32), scale: 2,
          representationTypes: .thumbnail)
        requests[key] = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
          [weak self] representation, _ in
          DispatchQueue.main.async {
            guard let self = self, self.requests.removeValue(forKey: key) != nil else { return }
            if let image = representation?.nsImage {
              self.thumbnails.setObject(image, forKey: key as NSString)
              completion(key, image)
            }
          }
        }
      }
    }
    return cached
  }
  func cancelOutside(_ keys: Set<String>) {
    for (key, request) in requests where !keys.contains(key) {
      QLThumbnailGenerator.shared.cancel(request)
      requests.removeValue(forKey: key)
      attempted.remove(key)
    }
  }
}
