import SwiftUI
import AppKit

struct AsyncListIconView: View {
    let item: FileItem
    let size: CGFloat

    @State private var image: NSImage?
    @State private var lastLoadKey: String?
    @State private var pendingRetryKey: String?

    private let thumbnailCache = ThumbnailCacheManager.shared

    var body: some View {
        Image(nsImage: image ?? item.placeholderIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .onAppear {
                loadIconIfNeeded()
            }
            .onChange(of: item.url) { _ in
                image = nil
                lastLoadKey = nil
                pendingRetryKey = nil
                loadIconIfNeeded()
            }
            .onChange(of: size) { _ in
                loadIconIfNeeded(force: true)
            }
    }

    private func loadIconIfNeeded(force: Bool = false) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let targetPixelSize = max(64, size * scale)
        let loadKey = "\(item.url.path)|\(Int(targetPixelSize))"

        if !force, loadKey == lastLoadKey {
            return
        }
        lastLoadKey = loadKey

        if let cached = thumbnailCache.getCachedThumbnail(for: item.url, maxPixelSize: targetPixelSize) {
            image = cached
            return
        }

        if thumbnailCache.isPending(url: item.url, maxPixelSize: targetPixelSize) {
            scheduleRetry(loadKey: loadKey)
            return
        }

        if thumbnailCache.hasFailed(url: item.url) {
            loadFallbackIcon()
            return
        }

        thumbnailCache.generateThumbnail(for: item, maxPixelSize: targetPixelSize) { _, thumbnail in
            if let thumbnail {
                image = thumbnail
            } else {
                loadFallbackIcon()
            }
        }
    }

    private func scheduleRetry(loadKey: String) {
        guard pendingRetryKey != loadKey else { return }
        pendingRetryKey = loadKey

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard pendingRetryKey == loadKey else { return }
            pendingRetryKey = nil
            loadIconIfNeeded(force: true)
        }
    }

    private func loadFallbackIcon() {
        DispatchQueue.global(qos: .utility).async {
            let icon = item.icon
            DispatchQueue.main.async {
                image = icon
            }
        }
    }
}
