import SwiftUI

/// Library-wide search results, shown in place of Home or Settings while
/// the toolbar search field has text.
struct SearchResultsView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var found = LibraryResults()

    var body: some View {
        let results = found.items
        LibraryPage {
            PageHeader(
                title: "Search",
                subtitle: "\(results.count) result\(results.count == 1 ? "" : "s") for “\(model.searchText.trimmed)”"
            )
            .padding(.bottom, 10)
        } content: {
            if results.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 292, maximum: 380), spacing: 20)],
                    alignment: .leading,
                    spacing: 24
                ) {
                    ForEach(found.visible) { item in
                        MediaCard(item: item, style: .landscape)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onAppear { found.showMore(after: item) }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
        }
        .background(Theme.background)
        .task(id: LibraryPageKey(query: query, indexCount: model.libraryIndex.revision)) {
            await found.load(query, index: model.libraryIndex)
        }
    }

    private var query: LibraryQuery {
        var query = model.libraryQuery(kind: nil, favoritesOnly: false, search: model.searchText, sort: .name, groupSimilar: false)
        query.playlistID = nil
        query.group = nil
        return query
    }
}
