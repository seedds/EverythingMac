import AppKit
import SwiftUI

struct SearchState: Codable, Equatable, Hashable {
  var query: String
  var directory: String
  var sensitive: Bool
  var isEmpty: Bool {
    query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
  var detail: String {
    [query, directory.isEmpty ? "" : "Folder: \(directory)", sensitive ? "Case sensitive" : ""]
      .filter { !$0.isEmpty }.joined(separator: " · ")
  }
}
struct SavedSearch: Codable, Identifiable {
  var id: UUID = UUID()
  var name: String
  var state: SearchState
}
struct RecentSearch: Codable, Identifiable {
  var id: UUID = UUID()
  var state: SearchState
  var usedAt: Date = Date()
}
struct SearchSuggestion: Identifiable {
  let id: UUID
  let title: String
  let state: SearchState
  let saved: Bool
}
private struct SearchLibraryDocument: Codable {
  var version = 1
  var saved: [SavedSearch] = []
  var recent: [RecentSearch] = []
}

final class SearchLibrary: ObservableObject {
  @Published private(set) var saved: [SavedSearch] = []
  @Published private(set) var recent: [RecentSearch] = []
  @Published var error: String?
  var willRemoveHistory: ((SearchState?) -> Void)?
  private var writable = true
  private let url: URL?
  private let queue = DispatchQueue(label: "everything.search-library")
  // Only accessed on queue. A failed write prevents later queued writes from masking it.
  private var writeFailure: Error?
  init(url: URL?) {
    self.url = url
    guard let url = url else { return }
    do {
      let data = try Data(contentsOf: url)
      let doc = try JSONDecoder().decode(SearchLibraryDocument.self, from: data)
      guard doc.version == 1 else { throw messageError("Unsupported search library version") }
      saved = doc.saved
      recent = Array(doc.recent.prefix(100))
    } catch let e as NSError
      where e.domain == NSCocoaErrorDomain && e.code == NSFileReadNoSuchFileError
    {
      // A new installation starts with an empty library.
    } catch {
      writable = false
      self.error =
        "Cannot load search library: \(error.localizedDescription). The original file has been preserved."
    }
  }
  func record(_ state: SearchState) {
    guard !state.isEmpty, writable else { return }
    recent.removeAll { $0.state == state }
    recent.insert(RecentSearch(state: state), at: 0)
    recent = Array(recent.prefix(100))
    persist()
  }
  func save(name: String, state: SearchState, id: UUID? = nil) throws {
    guard writable else { throw messageError(error ?? "Search library is unavailable") }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { throw messageError("Enter a name for the saved search.") }
    guard
      !saved.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame }
      )
    else {
      throw messageError("A saved search with that name already exists.")
    }
    if let id = id, let i = saved.firstIndex(where: { $0.id == id }) {
      saved[i].name = name
      saved[i].state = state
    } else {
      saved.append(SavedSearch(name: name, state: state))
    }
    persist()
  }
  func deleteSaved(_ id: UUID) {
    guard writable else { return }
    saved.removeAll { $0.id == id }
    persist()
  }
  func deleteRecent(_ id: UUID) {
    guard writable, let entry = recent.first(where: { $0.id == id }) else { return }
    willRemoveHistory?(entry.state)
    recent.removeAll { $0.id == id }
    persist()
  }
  func clearHistory() {
    guard writable else { return }
    willRemoveHistory?(nil)
    recent = []
    persist()
  }
  func suggestions(_ text: String, limit: Int = 8) -> [SearchSuggestion] {
    guard !text.isEmpty else { return [] }
    var seen = Set<SearchState>()
    let bookmarks = saved.filter {
      $0.name.localizedCaseInsensitiveContains(text)
        || $0.state.query.localizedCaseInsensitiveContains(text)
    }
    .map { SearchSuggestion(id: $0.id, title: $0.name, state: $0.state, saved: true) }
    let history = recent.filter { $0.state.query.localizedCaseInsensitiveContains(text) }
      .map {
        SearchSuggestion(
          id: $0.id, title: $0.state.query.isEmpty ? $0.state.directory : $0.state.query,
          state: $0.state, saved: false)
      }
    return Array((bookmarks + history).filter { seen.insert($0.state).inserted }.prefix(limit))
  }
  private func persist() {
    guard writable, let url = url else { return }
    let doc = SearchLibraryDocument(saved: saved, recent: recent)
    queue.async { [weak self] in
      guard let self = self, self.writeFailure == nil else { return }
      do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
      } catch {
        self.writeFailure = error
        DispatchQueue.main.async {
          self.writable = false
          self.error = "Cannot save search library: \(error.localizedDescription)"
        }
      }
    }
  }
  func flush() throws { try queue.sync { if let error = writeFailure { throw error } } }
}

extension Model {
  var currentSearchState: SearchState {
    SearchState(query: query, directory: directory, sensitive: sensitive)
  }
  func restoreSearch(_ state: SearchState) {
    historyRecordWork?.cancel()
    suppressedHistoryState = nil
    recordRequestedState = state
    query = state.query
    directory = state.directory
    sensitive = state.sensitive
    observedSearchState = state  // suppress SwiftUI's separate onChange callbacks
    activeTab = "files"
    inputAt = ProcessInfo.processInfo.systemUptime
    dismissSuggestions()
    libraryOpen = false
    submit()
    focusSearch?()
  }
  func recordSuccessfulSearch(_ state: SearchState, ticket: UInt64) {
    successfulSearchState = state
    successfulSearchTicket = ticket
    historyRecordWork?.cancel()
    guard suppressedHistoryState != state else { return }
    if recordRequestedState == state {
      library.record(state)
      recordRequestedState = nil
      return
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, !self.closed, self.currentSearchState == state,
        self.successfulSearchTicket == ticket, self.successfulSearchState == state
      else { return }
      self.library.record(state)
    }
    historyRecordWork = work
    DispatchQueue.main.asyncAfter(
      deadline: .now() + max(0, 2 - (ProcessInfo.processInfo.systemUptime - inputAt)), execute: work
    )
  }
  func suppressHistoryRecording(_ state: SearchState?) {
    guard state == nil || state == currentSearchState else { return }
    historyRecordWork?.cancel()
    recordRequestedState = nil
    suppressedHistoryState = currentSearchState
  }
  func dismissSuggestions() {
    suggestionsVisible = false
    suggestionIndex = nil
  }
  var suggestions: [SearchSuggestion] { library.suggestions(query) }
  func handleSuggestionKey(_ event: NSEvent) -> Bool {
    guard activeTab == "files", searchFieldFocused, suggestionsVisible, !suggestions.isEmpty else {
      return false
    }
    if event.keyCode == 53 {
      dismissSuggestions()
      return true
    }
    if event.keyCode == 125, event.modifierFlags.contains(.option), suggestionIndex == nil {
      suggestionIndex = 0
      return true
    }
    guard let index = suggestionIndex else { return false }
    if event.keyCode == 125 || event.keyCode == 126 {
      suggestionIndex = min(max(0, index + (event.keyCode == 125 ? 1 : -1)), suggestions.count - 1)
      return true
    }
    if event.keyCode == 36, index < suggestions.count {
      restoreSearch(suggestions[index].state)
      return true
    }
    return false
  }
}

struct SearchLibraryView: View {
  @ObservedObject var model: Model
  @ObservedObject var library: SearchLibrary
  @State private var filter = ""
  @State private var editID: UUID?
  @State private var name = ""
  @State private var editing = false
  @State private var stateToSave: SearchState?
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Search Library").font(.headline)
        Spacer()
        Button("Save Current Search") {
          editID = nil
          name = ""
          stateToSave = model.currentSearchState
          editing = true
        }
      }
      TextField("Find saved or recent searches", text: $filter)
      if editing {
        HStack {
          TextField("Search name", text: $name)
          Button("Save") {
            do {
              try library.save(
                name: name, state: stateToSave ?? model.currentSearchState, id: editID)
              editing = false
              error = nil
            } catch { self.error = error.localizedDescription }
          }
          Button("Cancel") {
            editing = false
            error = nil
          }
        }
      }
      if let error = error ?? library.error { Text(error).font(.caption).foregroundColor(.red) }
      ScrollView {
        VStack(alignment: .leading, spacing: 8) {
          Text("Saved Searches").font(.headline)
          if library.saved.isEmpty {
            Text("Save a query and folder scope to reuse them.").foregroundColor(.secondary)
          }
          ForEach(
            library.saved.filter {
              filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter)
                || $0.state.detail.localizedCaseInsensitiveContains(filter)
            }
          ) { item in
            HStack {
              entry(item.name, state: item.state)
              Menu {
                Button("Rename…") {
                  editID = item.id
                  name = item.name
                  stateToSave = item.state
                  editing = true
                }
                Button("Update from Current Search") {
                  do {
                    try library.save(name: item.name, state: model.currentSearchState, id: item.id)
                  } catch { self.error = error.localizedDescription }
                }
                Button("Delete") { library.deleteSaved(item.id) }
              } label: {
                Image(systemName: "ellipsis")
              }.frame(width: 35)
            }
          }
          Divider()
          HStack {
            Text("Recent Searches").font(.headline)
            Spacer()
            Button("Clear History") { library.clearHistory() }
          }
          ForEach(
            library.recent.filter {
              filter.isEmpty || $0.state.detail.localizedCaseInsensitiveContains(filter)
            }
          ) { item in
            HStack {
              entry(
                item.state.query.isEmpty ? item.state.directory : item.state.query,
                state: item.state)
              Button {
                library.deleteRecent(item.id)
              } label: {
                Image(systemName: "xmark")
              }.help("Remove from history")
            }
          }
        }
      }
    }.padding(16).frame(width: 460, height: 390).background(Color(nsColor: .windowBackgroundColor))
  }
  private func entry(_ title: String, state: SearchState) -> some View {
    Button {
      model.restoreSearch(state)
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).lineLimit(1)
        Text(state.detail).font(.caption).foregroundColor(.secondary).lineLimit(2)
      }.frame(maxWidth: .infinity, alignment: .leading)
    }.buttonStyle(.plain).help(state.detail)
  }
}

struct SearchSuggestionsView: View {
  @ObservedObject var model: Model
  @ObservedObject var library: SearchLibrary
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(Array(model.suggestions.enumerated()), id: \.element.id) { index, item in
        Button {
          model.restoreSearch(item.state)
        } label: {
          HStack {
            Image(systemName: item.saved ? "bookmark" : "clock")
            VStack(alignment: .leading) {
              Text(item.title).lineLimit(1)
              Text(item.state.detail).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Spacer()
          }.padding(6).background(
            model.suggestionIndex == index ? Color.accentColor.opacity(0.18) : Color.clear)
        }.buttonStyle(.plain)
      }
      Text("Option-Down: suggestions · Down: results · Esc: dismiss").font(.caption)
        .foregroundColor(.secondary).padding(4)
    }.padding(5).frame(width: 420).background(Color(nsColor: .windowBackgroundColor))
      .cornerRadius(8).shadow(radius: 5)
  }
}
