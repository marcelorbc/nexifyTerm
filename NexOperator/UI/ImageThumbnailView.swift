import SwiftUI
import AppKit

struct ImageThumbnailView: View {
    let url: URL
    let size: CGFloat

    @State private var thumbnail: NSImage?
    @State private var isLoading = true

    var body: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
                    .cornerRadius(6)
            } else if isLoading {
                ZStack {
                    Color.clear
                    ProgressView()
                        .scaleEffect(0.5)
                }
                .frame(width: size, height: size)
            } else {
                ZStack {
                    Color.clear
                    Image(systemName: "photo")
                        .font(.system(size: size * 0.25))
                        .foregroundColor(NexTheme.textSecondary.opacity(0.4))
                }
                .frame(width: size, height: size)
            }
        }
        .task(id: "\(url.path)_\(Int(size))") {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        isLoading = true
        let targetSize = Int(size * 2)

        if let cached = ThumbnailCache.shared.get(for: url, size: targetSize) {
            thumbnail = cached
            isLoading = false
            return
        }

        let result = await Task.detached(priority: .utility) {
            generateThumbnail(url: url, maxDimension: targetSize)
        }.value

        thumbnail = result
        isLoading = false

        if let result {
            ThumbnailCache.shared.set(result, for: url, size: targetSize)
        }
    }
}

private func generateThumbnail(url: URL, maxDimension: Int) -> NSImage? {
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        return NSImage(contentsOf: url)?.resized(to: maxDimension)
    }

    let options: [CFString: Any] = [
        kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true
    ]

    guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
        return NSImage(contentsOf: url)?.resized(to: maxDimension)
    }

    return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}

private extension NSImage {
    func resized(to maxDimension: Int) -> NSImage? {
        let maxDim = CGFloat(maxDimension)
        let ratio = min(maxDim / size.width, maxDim / size.height, 1.0)
        let newSize = NSSize(width: size.width * ratio, height: size.height * ratio)

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        draw(in: NSRect(origin: .zero, size: newSize),
             from: NSRect(origin: .zero, size: size),
             operation: .copy,
             fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private let lock = NSLock()

    private init() {
        cache.countLimit = 500
        cache.totalCostLimit = 100 * 1024 * 1024
    }

    func get(for url: URL, size: Int) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        return cache.object(forKey: key(url, size))
    }

    func set(_ image: NSImage, for url: URL, size: Int) {
        lock.lock()
        defer { lock.unlock() }
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: key(url, size), cost: cost)
    }

    func invalidate(for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        for s in [120, 240, 480] {
            cache.removeObject(forKey: key(url, s))
        }
    }

    private func key(_ url: URL, _ size: Int) -> NSString {
        "\(url.path)_\(size)" as NSString
    }
}
