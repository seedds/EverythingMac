import AppKit
import SwiftUI

struct SearchHelpEntry: Identifiable {
  let title: String
  let detail: String
  let example: String?
  var id: String { title }
  init(_ title: String, _ detail: String, _ example: String? = nil) {
    self.title = title
    self.detail = detail
    self.example = example
  }
}

enum SearchHelp {
  // Every query example is exercised through the production engine by FeatureCheck.
  static let entries: [SearchHelpEntry] = [
    .init(
      "Names and phrases",
      "Search file and folder names by substring. Quotes keep words together; spaces between terms mean AND. Text with a colon that is not one of the filters below, such as note:draft, is matched against names too.",
      "report"),
    .init("Quoted phrase", "Match a phrase containing spaces.", "\"annual report\""),
    .init(
      "Prefix, suffix, exact name",
      "A leading slash anchors the start; a trailing slash anchors the end; both match the whole name.",
      "/report/"),
    .init(
      "Path matching",
      "Separate path fragments with slashes. The Folder scope field restricts results without changing the index.",
      "project/report"),
    .init("Wildcards", "Use * for any sequence and ? for one character.", "report*.txt"),
    .init(
      "Boolean grouping",
      "Spaces combine terms with AND; | means OR; ! excludes a term. Use parentheses to group alternatives.",
      "(report | invoice) !draft"),
    .init(
      "Regular expressions",
      "The regex: prefix uses a regular expression. Case sensitivity follows Aa.", "regex:^report"),
    .init("Files and folders", "file: returns files; folder: returns directories.", "file: report"),
    .init("Folders only", "Find directory names.", "folder: project"),
    .init(
      "Extensions",
      "ext: accepts a semicolon-separated list of extensions. Apps and document packages match too, so ext:app finds apps.",
      "ext:pdf;txt"),
    .init(
      "File categories",
      "type:picture, type:video, type:audio, type:document and type:executable match known filename extensions, including apps, installers and document packages such as .pages.",
      "type:document"),
    .init(
      "Category shortcuts", "audio:, video:, doc: and exe: are category shortcuts.", "doc: report"),
    .init(
      "Size",
      "size: compares logical file size with >, >=, <, <= or a range. This differs from the Size on disk column.",
      "size:>1MB"),
    .init(
      "Modified date",
      "dm: (datemodified:) filters modification dates. Supports dates, ranges and relative periods.",
      "dm:today"),
    .init("Created date", "dc: (datecreated:) filters creation dates.", "dc:pastweek"),
    .init(
      "Folder and descendants",
      "infolder: (in:) restricts results to a folder and its descendants.", "infolder:~/Documents"),
    .init(
      "Direct children", "parent: and nosubfolders: restrict results to direct children.",
      "parent:~/Downloads"),
    .init(
      "Exclusion patterns",
      "Preferences → Exclude patterns removes matching entries from the index. node_modules matches names anywhere; *.log matches names by extension; **/build/** prunes build directories. A trailing / means directories only. Patterns are case-sensitive and still apply inside Include paths."
    ),
    .init(
      "Saved searches",
      "Search Library stores named queries with their folder scope and Aa setting. Selecting one restores the visible fields and runs the search. Rename, update, or delete from its menu."
    ),
    .init(
      "Search history",
      "Successful searches enter history after Enter, entering results, or a two-second editing pause. The most recent 100 distinct searches are kept. Open Search Library beside the search field to browse and restore past searches. Clear History leaves saved searches intact."
    ),
  ]
  static func shortcuts(_ activation: String) -> [SearchHelpEntry] {
    [
      .init(
        "Global activation: \(activation)",
        "Show or hide EverythingMac. Change or disable this shortcut in Preferences."),
      .init(
        "Cmd-F · Enter · Down",
        "Focus search; submit a search; enter results. Up from the first result returns to search."),
      .init(
        "Option-Up / Option-Down",
        "Navigate recent search history."),
      .init(
        "Cmd-O · Cmd-R · Space",
        "Open selected files; reveal in Finder; toggle Quick Look. Arrow keys navigate while previewing."
      ),
      .init("Cmd-C · Cmd-Shift-C", "Copy selected files; copy their paths as text."),
      .init(
        "F2 · F8 · F9",
        "Rename; move selected files to Trash; open the folder in the configured terminal."),
      .init("Cmd-A · Shift-arrow · Cmd-click", "Select all results; extend or modify selection."),
      .init(
        "Cmd-/ · Escape · Cmd-Q",
        "Open Search & Shortcuts; hide the main window; save the index and quit."
      ),
    ]
  }
}

struct SearchHelpView: View {
  var prefs: Preferences
  let useExample: (String) -> Void
  @State private var filter = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Search & Shortcuts").font(.title2.bold())
      TextField("Find an operator, shortcut, or example", text: $filter)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(
            (SearchHelp.entries + SearchHelp.shortcuts(prefs.shortcut?.label ?? "Disabled")).filter
            {
              filter.isEmpty
                || ($0.title + " " + $0.detail + " " + ($0.example ?? ""))
                  .localizedCaseInsensitiveContains(filter)
            }
          ) { entry in
            VStack(alignment: .leading, spacing: 5) {
              Text(entry.title).font(.headline)
              Text(entry.detail).fixedSize(horizontal: false, vertical: true).textSelection(
                .enabled)
              if let example = entry.example {
                HStack {
                  Text(example).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                  Spacer()
                  Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(example, forType: .string)
                  }
                  Button("Use example") { useExample(example) }
                }
              }
            }
            Divider()
          }
        }.padding(.trailing, 8)
      }
    }.padding(20).frame(minWidth: 580, minHeight: 430).background(
      Color(nsColor: .windowBackgroundColor))
  }
}
