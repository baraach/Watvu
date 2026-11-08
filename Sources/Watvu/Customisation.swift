import Foundation

/// Per-item and per-category user customisations (rename, thumbnail, move,
/// hide, catch-up offset), persisted to `customisation.json`.
struct ItemOverride: Codable, Hashable {
    var name: String?
    var logo: String?
    var group: String?
    var hidden: Bool?
    var catchupOffsetSeconds: Int?
}

extension AppModel {
    var overridesURL: URL { baseDirectory.appendingPathComponent("customisation.json") }

    func saveOverrides() {
        write(overrides, to: overridesURL)
    }

    func setItemOverride(for id: String, _ change: (inout ItemOverride) -> Void) {
        var o = overrides[id] ?? ItemOverride()
        change(&o)
        overrides[id] = o
        saveOverrides()
    }

    // Effective display values
    func effectiveName(_ item: MediaItem) -> String { overrides[item.id]?.name ?? item.name }
    func effectiveLogo(_ item: MediaItem) -> String? { overrides[item.id]?.logo ?? item.logo }
    func effectiveGroup(_ item: MediaItem) -> String { overrides[item.id]?.group ?? item.group }

    func isItemHidden(_ id: String) -> Bool {
        overrides[id]?.hidden ?? isHidden(id)
    }

    func isCategoryHidden(_ group: String) -> Bool {
        overrides["cat:\(group)"]?.hidden ?? false
    }

    /// IDs of hidden items, for filtering many items at once.
    var hiddenItemIDs: Set<String> {
        var ids = Set(UserDefaults.standard.stringArray(forKey: "hiddenItems") ?? [])
        for (key, value) in overrides {
            if value.hidden == true { ids.insert(key) } else if value.hidden == false { ids.remove(key) }
        }
        return ids
    }

    /// Names of hidden categories, for filtering many items at once.
    var hiddenCategories: Set<String> {
        Set(overrides.compactMap { key, value in
            key.hasPrefix("cat:") && value.hidden == true ? String(key.dropFirst(4)) : nil
        })
    }

    func catchupOffset(for channel: MediaItem) -> Int {
        overrides[channel.id]?.catchupOffsetSeconds ?? 0
    }

    func setCatchupOffset(_ seconds: Int, for channelID: String) {
        setItemOverride(for: channelID) { $0.catchupOffsetSeconds = seconds == 0 ? nil : seconds }
    }

    // MARK: Operations

    func renameItem(_ id: String, to name: String) {
        setItemOverride(for: id) { $0.name = name.trimmed.isEmpty ? nil : name.trimmed }
    }

    func setItemLogo(_ id: String, url: String) {
        setItemOverride(for: id) { $0.logo = url.trimmed.isEmpty ? nil : url.trimmed }
    }

    func moveItemToCategory(_ id: String, group: String) {
        setItemOverride(for: id) { $0.group = group }
    }

    func renameCategory(_ old: String, to new: String) {
        guard !new.trimmed.isEmpty, old != new else { return }
        for item in items where effectiveGroup(item) == old {
            setItemOverride(for: item.id) { $0.group = new }
        }
        var cat = overrides["cat:\(old)"] ?? ItemOverride()
        cat.hidden = nil
        overrides["cat:\(new)"] = cat
        overrides.removeValue(forKey: "cat:\(old)")
        saveOverrides()
    }

    func mergeCategory(_ from: String, into: String) {
        guard from != into else { return }
        for item in items where effectiveGroup(item) == from {
            setItemOverride(for: item.id) { $0.group = into }
        }
        overrides.removeValue(forKey: "cat:\(from)")
        saveOverrides()
    }

    func setCategoryHidden(_ hidden: Bool, _ group: String) {
        let key = "cat:\(group)"
        var o = overrides[key] ?? ItemOverride()
        o.hidden = hidden
        overrides[key] = o
        saveOverrides()
    }

    func resetCustomisations() {
        overrides = [:]
        saveOverrides()
    }

    // MARK: Name clean-up

    /// Applies cleaned names to every item whose name changes. Returns count.
    @discardableResult
    func cleanUpNames() -> Int {
        var changed = 0
        for item in items {
            let cleaned = NameCleaner.cleaned(item.name)
            if cleaned != item.name && !cleaned.isEmpty {
                setItemOverride(for: item.id) { $0.name = cleaned }
                changed += 1
            }
        }
        return changed
    }
}
