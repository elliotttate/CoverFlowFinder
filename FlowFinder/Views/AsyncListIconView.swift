import SwiftUI
import AppKit

struct AsyncListIconView: View {
    @EnvironmentObject private var settings: AppSettings
    let item: FileItem
    let size: CGFloat

    @State private var image: NSImage?
    /// The key of the request in flight or completed; a completion only applies if it's still current.
    @State private var loadedKey: LoadKey?
    @State private var requestToken: ThumbnailRequestToken?

    private let thumbnailCache = ThumbnailCacheManager.shared

    /// What the icon depends on: file, file version and pixel size.
    private struct LoadKey: Equatable {
        let url: URL
        let version: FileItem.ContentVersion
        let pixelSize: Int
    }

    private var targetPixelSize: CGFloat {
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return max(64, size * scale * settings.thumbnailQualityValue)
    }

    private var currentKey: LoadKey {
        LoadKey(url: item.url, version: item.contentVersion, pixelSize: Int(targetPixelSize))
    }

    var body: some View {
        Image(nsImage: image ?? item.placeholderIcon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .onAppear {
                loadIconIfNeeded()
            }
            .onDisappear {
                cancelRequest()
            }
            // Item, size or quality changed: load for the new key (reads current values)
            .onChange(of: currentKey) { oldKey, newKey in
                if oldKey.url != newKey.url {
                    image = nil
                }
                loadIconIfNeeded()
            }
    }

    private func loadIconIfNeeded() {
        let key = currentKey
        if key == loadedKey {
            return
        }
        cancelRequest()
        loadedKey = key

        let item = item
        // No polling: a request already pending elsewhere is joined and completes this one too.
        let token = thumbnailCache.requestThumbnail(for: item, maxPixelSize: targetPixelSize, owner: nil) { result in
            // Ignore answers for an older key (item, size or quality changed meanwhile)
            guard loadedKey == key else { return }
            requestToken = nil
            switch result {
            case .loaded(let thumbnail):
                image = thumbnail
            case .failed:
                loadFallbackIcon(for: item, key: key)
            case .cancelled:
                // Load again next time
                loadedKey = nil
            }
        }
        if loadedKey == key {
            requestToken = token
        }
    }

    private func cancelRequest() {
        guard let requestToken else { return }
        thumbnailCache.cancel(requestToken)
        self.requestToken = nil
        // The abandoned request's key must load again next time
        loadedKey = nil
    }

    private func loadFallbackIcon(for item: FileItem, key: LoadKey) {
        DispatchQueue.global(qos: .utility).async {
            let icon = item.icon
            DispatchQueue.main.async {
                guard loadedKey == key else { return }
                image = icon
            }
        }
    }
}
