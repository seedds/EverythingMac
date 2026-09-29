import AppKit

final class FileIcons {
  let basic = NSCache<NSString, NSImage>()
  let queue = DispatchQueue(label: "everything.mac.icons", qos: .utility)
  var pending = Set<String>()
  init() {
    basic.countLimit = 512
  }
  // Metadata arriving later must not invalidate an icon already loaded for the path.
  static func key(_ row: Row) -> String { "\(row.path)|\(row.is_directory)" }
  func image(_ row: Row, completion: @escaping (String, NSImage) -> Void)
    -> NSImage?
  {
    let key = Self.key(row)
    let cached = basic.object(forKey: key as NSString)
    if cached == nil && !pending.contains(key) && pending.count < 64 {
      pending.insert(key)
      queue.async { [weak self] in
        let image = NSWorkspace.shared.icon(forFile: row.path)
        DispatchQueue.main.async {
          guard let self = self else { return }
          self.pending.remove(key)
          self.basic.setObject(image, forKey: key as NSString)
          completion(key, image)
        }
      }
    }
    return cached
  }
}
