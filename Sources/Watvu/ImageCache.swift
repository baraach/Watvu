import SwiftUI
import AppKit
import ImageIO

/// Recently shown card artwork, already shrunk to display size.
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()

    /// Longest side kept, in pixels: a 220 × 330 point poster on a Retina screen.
    static let maxEdge = 660

    func clear() { cache.removeAllObjects() }

    private init() {
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    /// Decodes downloaded artwork at display size, so a huge source image never
    /// sits in memory at full resolution.
    func store(_ data: Data, for url: URL) -> NSImage? {
        guard let image = Self.decode(data) else { return nil }
        let pixels = Int(image.size.width * image.size.height)
        cache.setObject(image, forKey: url.absoluteString as NSString, cost: pixels * 4)
        return image
    }

    private static func decode(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return NSImage(data: data)   // formats only AppKit reads
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxEdge),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

struct CachedAsyncImage<Content: View>: View {
    let url: URL
    let content: (Image) -> Content

    @StateObject private var loader = ImageLoader()

    var body: some View {
        Group {
            if let image = loader.image ?? ImageCache.shared.image(for: url) {
                // Off-screen cards stay alive in lazy grids: they mustn't keep their art.
                content(Image(nsImage: image))
                    .onDisappear { loader.releaseImage() }
            } else if loader.failed {
                Theme.gradient(for: url.absoluteString)
            } else {
                ProgressView()
                    .onAppear { loader.load(url: url) }
                    .onDisappear { loader.cancel() }
            }
        }
    }
}

private final class ImageLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var failed = false
    private var task: Task<Void, Never>?

    func load(url: URL) {
        guard task == nil else { return }
        task = Task {
            // A dead logo is normal on big playlists: show the placeholder.
            let data = try? await URLSession.shared.data(from: url).0
            guard !Task.isCancelled else { return }
            let loaded = data.flatMap { ImageCache.shared.store($0, for: url) }
            await MainActor.run {
                self.task = nil
                self.image = loaded
                self.failed = loaded == nil
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    func releaseImage() { image = nil }
}
