import SwiftUI

enum MultiviewLayout: String, CaseIterable, Identifiable {
    case pip, grid2x2, grid3x3

    var id: String { rawValue }
    var title: String {
        switch self {
        case .pip: return L("Picture-in-Picture")
        case .grid2x2: return L("2×2 Grid")
        case .grid3x3: return L("3×3 Grid")
        }
    }
}

struct Multiview: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ui = MultiviewUI()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Picker(L("Layout"), selection: Binding(get: { ui.layout }, set: { ui.layout = $0 })) {
                    ForEach(MultiviewLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .onAppear {
            if ui.mainItem == nil { ui.mainItem = model.playingItem }          // B6
            ui.secondaryItems = model.libraryIndex.live.lazy.filter { $0.id != ui.mainItem?.id }.prefix(8).map { $0 }  // B7
        }
    }

    @ViewBuilder
    private var content: some View {
        switch ui.layout {
        case .pip:
            ZStack {
                if let mainItem = ui.mainItem {
                    PlayerView(item: mainItem).ignoresSafeArea()
                }
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ForEach(ui.secondaryItems.prefix(3)) { item in
                            Button { ui.mainItem = item } label: {
                                PlayerView(item: item)
                                    .frame(width: 300, height: 170)
                                    .cornerRadius(12)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.25), lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(20)
                }
            }
        case .grid2x2:
            grid(columns: 2, count: 4)
        case .grid3x3:
            grid(columns: 3, count: 9)
        }
    }

    private func grid(columns: Int, count: Int) -> some View {
        let all = ([ui.mainItem].compactMap { $0 } + ui.secondaryItems).prefix(count)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: columns), spacing: 8) {
            ForEach(Array(all.enumerated()), id: \.offset) { _, item in
                PlayerView(item: item)
                    .aspectRatio(16/9, contentMode: .fit)
                    .onTapGesture { ui.mainItem = item }
            }
        }
        .padding(8)
    }
}

private final class MultiviewUI: ObservableObject {
    @Published var layout: MultiviewLayout = .pip
    @Published var mainItem: MediaItem?
    @Published var secondaryItems: [MediaItem] = []
}
