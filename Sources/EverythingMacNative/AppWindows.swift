import AppKit
import SwiftUI

// Read SwiftUI's window without replacing its content or owning its lifecycle.
struct WindowReader: NSViewRepresentable {
  var attach: (NSWindow) -> Void
  func makeNSView(context: Context) -> ReaderView { ReaderView(attach: attach) }
  func updateNSView(_ view: ReaderView, context: Context) { view.attach = attach }

  final class ReaderView: NSView {
    var attach: (NSWindow) -> Void
    init(attach: @escaping (NSWindow) -> Void) {
      self.attach = attach
      super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // Let SwiftUI finish creating the window and installing its delegate first.
      DispatchQueue.main.async { [weak self] in
        guard let self = self, let window = self.window else { return }
        self.attach(window)
      }
    }
  }
}

// Keep the search window alive on close. Forward all other delegate callbacks
// to SwiftUI so its scene bookkeeping and native window behavior remain intact.
final class SearchWindowDelegate: NSObject, NSWindowDelegate {
  let original: NSWindowDelegate?
  init(forwarding original: NSWindowDelegate?) { self.original = original }
  func windowShouldClose(_ sender: NSWindow) -> Bool {
    sender.orderOut(nil)
    return false
  }
  override func responds(to selector: Selector!) -> Bool {
    super.responds(to: selector) || original?.responds(to: selector) == true
  }
  override func forwardingTarget(for selector: Selector!) -> Any? {
    if original?.responds(to: selector) == true { return original }
    return super.forwardingTarget(for: selector)
  }
}

struct OpenSettingsButton: View {
  var body: some View {
    Group {
      if #available(macOS 14, *) {
        SettingsLink { Image(systemName: "gearshape") }
      } else {
        Button {
          let selector = NSSelectorFromString(
            ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 13
              ? "showSettingsWindow:" : "showPreferencesWindow:")
          NSApp.sendAction(selector, to: nil, from: nil)
        } label: { Image(systemName: "gearshape") }
      }
    }
    .help("Open settings").accessibilityLabel("Open settings")
  }
}

struct SettingsContent: View {
  @ObservedObject var model: Model
  @State private var window: NSWindow?
  @State private var session = UUID()
  @State private var presented = false

  private func beginPresentation() {
    guard !presented else { return }
    presented = true
    session = UUID()
  }

  var body: some View {
    PreferencesView(prefs: model.prefs, model: model) { window?.performClose(nil) }
      .id(session)
      .background(WindowReader {
        window = $0
        $0.identifier = NSUserInterfaceItemIdentifier("EverythingMacSettings")
        if $0.isKeyWindow { beginPresentation() }
      })
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
        guard let keyWindow = $0.object as? NSWindow, keyWindow === window else { return }
        beginPresentation()
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
        guard let closedWindow = $0.object as? NSWindow, closedWindow === window else { return }
        // SwiftUI retains Settings content between presentations. Read fresh
        // preferences on the next visit, including changes made while closed.
        presented = false
        model.recordingShortcut = false
      }
  }
}
