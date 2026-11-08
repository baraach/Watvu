import Foundation

/// A Home shelf/section the user can show, hide and reorder.
enum HomeSection: String, CaseIterable, Identifiable, Codable {
    case hero, continueWatching, trending, recommended, popularTV, customFeeds, live, movies, series

    var id: String { rawValue }
    var title: String {
        switch self {
        case .hero: return "Featured"
        case .continueWatching: return "Continue watching"
        case .trending: return "Trending"
        case .recommended: return "Because you watch"
        case .popularTV: return "Popular on TV"
        case .customFeeds: return "Your feeds"
        case .live: return "Live TV"
        case .movies: return "Movies"
        case .series: return "Series"
        }
    }
}

extension AppModel {
    /// Persisted home layout: order + hidden sections.
    var homeOrder: [HomeSection] {
        get {
            // Sections added in later versions are appended to a saved order.
            let saved = (UserDefaults.standard.array(forKey: "homeOrder") as? [String])?.compactMap(HomeSection.init) ?? []
            return saved + HomeSection.allCases.filter { !saved.contains($0) }
        }
        set { UserDefaults.standard.set(newValue.map(\.rawValue), forKey: "homeOrder") }
    }

    var hiddenHomeSections: Set<HomeSection> {
        get { Set((UserDefaults.standard.array(forKey: "hiddenHomeSections") as? [String])?.compactMap(HomeSection.init) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).map(\.rawValue).sorted(), forKey: "hiddenHomeSections") }
    }

    func isHomeSectionVisible(_ section: HomeSection) -> Bool {
        !hiddenHomeSections.contains(section)
    }

    func moveHomeSection(_ section: HomeSection, up: Bool) {
        var order = homeOrder
        guard let index = order.firstIndex(of: section) else { return }
        let newIndex = up ? max(0, index - 1) : min(order.count - 1, index + 1)
        guard newIndex != index else { return }
        order.swapAt(index, newIndex)
        homeOrder = order
    }
}
