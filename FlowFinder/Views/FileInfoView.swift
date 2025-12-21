import SwiftUI
import QuickLookThumbnailing
import ImageIO
import CoreLocation
import AVFoundation
import CoreMedia

struct FileInfoView: View {
    @EnvironmentObject private var appSettings: AppSettings
    let item: FileItem
    @Environment(\.dismiss) private var dismiss

    @State private var thumbnail: NSImage?
    @State private var fileAttributes: FileAttributes?
    @State private var mediaMetadata: MediaMetadata?
    @State private var isLoadingAttributes = true
    @State private var attributesTask: Task<Void, Never>?
    @State private var metadataTask: Task<Void, Never>?

    private var hasMediaInfo: Bool {
        mediaMetadata != nil && !(mediaMetadata?.isEmpty ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar with close button
            HStack {
                Text("Info")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(spacing: 0) {
                    // Header with icon and name
                    headerSection

                    Divider()
                        .padding(.vertical, 12)

                    // General Info
                    if let attrs = fileAttributes {
                        infoSection(title: "General", items: generalInfo(attrs))

                        Divider()
                            .padding(.vertical, 12)

                        // More Info
                        infoSection(title: "More Info", items: moreInfo(attrs))

                        // Media Info
                        if hasMediaInfo, let media = mediaMetadata {
                            Divider()
                                .padding(.vertical, 12)
                            mediaInfoSections(media)
                        }

                        if !attrs.extendedAttributes.isEmpty {
                            Divider()
                                .padding(.vertical, 12)

                            // Extended Attributes
                            infoSection(title: "Extended Attributes", items: attrs.extendedAttributes.map { ($0.key, $0.value) })
                        }

                        Divider()
                            .padding(.vertical, 12)

                        // Permissions
                        infoSection(title: "Permissions", items: permissionsInfo(attrs))
                    } else if isLoadingAttributes {
                        ProgressView()
                            .padding()
                    }

                    Spacer(minLength: 20)
                }
                .padding(20)
            }
        }
        .frame(width: 380, height: hasMediaInfo ? 700 : 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            loadThumbnail()
            loadFileAttributes()
            loadMediaMetadata()
        }
        .onDisappear {
            attributesTask?.cancel()
            metadataTask?.cancel()
        }
    }

    @ViewBuilder
    private func mediaInfoSections(_ media: MediaMetadata) -> some View {
        if !media.imageInfo.isEmpty {
            infoSection(title: "Image", items: media.imageInfo)
            Divider()
                .padding(.vertical, 8)
        }

        if !media.cameraInfo.isEmpty {
            infoSection(title: "Camera", items: media.cameraInfo)
            Divider()
                .padding(.vertical, 8)
        }

        if !media.exposureInfo.isEmpty {
            infoSection(title: "Exposure", items: media.exposureInfo)
            Divider()
                .padding(.vertical, 8)
        }

        if !media.locationInfo.isEmpty {
            infoSection(title: "Location", items: media.locationInfo)
            Divider()
                .padding(.vertical, 8)
        }

        if !media.videoInfo.isEmpty {
            infoSection(title: "Video", items: media.videoInfo)
            Divider()
                .padding(.vertical, 8)
        }

        if !media.audioInfo.isEmpty {
            infoSection(title: "Audio", items: media.audioInfo)
            Divider()
                .padding(.vertical, 8)
        }

        if !media.pdfInfo.isEmpty {
            infoSection(title: "PDF", items: media.pdfInfo)
            Divider()
                .padding(.vertical, 8)
        }

        if !media.archiveInfo.isEmpty {
            infoSection(title: "Archive", items: media.archiveInfo)
        }
    }

    private func loadMediaMetadata() {
        metadataTask?.cancel()
        metadataTask = Task.detached(priority: .userInitiated) { [url = item.url] in
            let metadata = await MediaMetadata(url: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.mediaMetadata = metadata
            }
        }
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            // Thumbnail or icon
            Group {
                if let thumbnail = thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 128, height: 128)
                        .cornerRadius(8)
                        .shadow(radius: 4)
                } else {
                    Image(nsImage: item.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 128, height: 128)
                }
            }

            // File name
            Text(item.displayName(showFileExtensions: appSettings.showFileExtensions))
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)

            // Kind
            Text(kindDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func infoSection(title: String, items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .padding(.bottom, 4)

            ForEach(items, id: \.0) { label, value in
                HStack(alignment: .top) {
                    Text(label + ":")
                        .foregroundColor(.secondary)
                        .frame(width: 100, alignment: .trailing)

                    Text(value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kindDescription: String {
        item.kindDescription
    }

    private func generalInfo(_ attrs: FileAttributes) -> [(String, String)] {
        var info: [(String, String)] = []

        info.append(("Kind", attrs.kind))
        info.append(("Size", attrs.formattedSize))

        if let itemCount = attrs.itemCount {
            info.append(("Contains", "\(itemCount) items"))
        }

        info.append(("Location", attrs.location))

        return info
    }

    private func moreInfo(_ attrs: FileAttributes) -> [(String, String)] {
        var info: [(String, String)] = []

        info.append(("Created", attrs.formattedCreationDate))
        info.append(("Modified", attrs.formattedModificationDate))
        info.append(("Last Opened", attrs.formattedLastAccessDate))

        if let contentType = attrs.contentType {
            info.append(("Content Type", contentType))
        }

        if let version = attrs.version {
            info.append(("Version", version))
        }

        if let copyright = attrs.copyright {
            info.append(("Copyright", copyright))
        }

        return info
    }

    private func permissionsInfo(_ attrs: FileAttributes) -> [(String, String)] {
        var info: [(String, String)] = []

        info.append(("Owner", attrs.ownerName))
        info.append(("Group", attrs.groupName))
        info.append(("Permissions", attrs.permissionsString))
        info.append(("Readable", attrs.isReadable ? "Yes" : "No"))
        info.append(("Writable", attrs.isWritable ? "Yes" : "No"))
        info.append(("Executable", attrs.isExecutable ? "Yes" : "No"))

        if attrs.isHidden {
            info.append(("Hidden", "Yes"))
        }

        return info
    }

    private func loadThumbnail() {
        let size = CGSize(width: 256, height: 256)
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .all
        )

        QLThumbnailGenerator.shared.generateRepresentations(for: request) { thumbnail, type, error in
            if let thumbnail = thumbnail {
                DispatchQueue.main.async {
                    self.thumbnail = thumbnail.nsImage
                }
            }
        }
    }

    private func loadFileAttributes() {
        attributesTask?.cancel()
        isLoadingAttributes = true
        attributesTask = Task.detached(priority: .userInitiated) { [url = item.url] in
            let attrs = FileAttributes(url: url)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.fileAttributes = attrs
                self.isLoadingAttributes = false
            }
        }
    }
}

struct FileAttributes {
    let url: URL
    let kind: String
    let size: Int64
    let formattedSize: String
    let itemCount: Int?
    let location: String
    let creationDate: Date?
    let modificationDate: Date?
    let lastAccessDate: Date?
    let formattedCreationDate: String
    let formattedModificationDate: String
    let formattedLastAccessDate: String
    let contentType: String?
    let ownerName: String
    let groupName: String
    let permissions: Int16
    let permissionsString: String
    let isReadable: Bool
    let isWritable: Bool
    let isExecutable: Bool
    let isHidden: Bool
    let version: String?
    let copyright: String?
    let extendedAttributes: [(key: String, value: String)]

    init(url: URL) {
        self.url = url

        let fileManager = FileManager.default
        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey,
            .totalFileSizeKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .isDirectoryKey,
            .creationDateKey,
            .contentModificationDateKey,
            .contentAccessDateKey,
            .contentTypeKey,
            .localizedTypeDescriptionKey,
            .isHiddenKey,
            .isReadableKey,
            .isWritableKey,
            .isExecutableKey
        ]

        let resourceValues = try? url.resourceValues(forKeys: resourceKeys)
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)

        // Kind
        self.kind = resourceValues?.localizedTypeDescription ?? "Unknown"

        // Size
        let isDirectory = resourceValues?.isDirectory ?? false
        if isDirectory {
            // Calculate folder size
            let (totalSize, count) = FileAttributes.calculateFolderSize(url: url)
            self.size = totalSize
            self.itemCount = count
        } else {
            self.size = Int64(resourceValues?.totalFileSize ?? resourceValues?.fileSize ?? 0)
            self.itemCount = nil
        }

        let byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .file
        self.formattedSize = byteFormatter.string(fromByteCount: size)

        // Location
        self.location = url.deletingLastPathComponent().path

        // Dates
        self.creationDate = resourceValues?.creationDate
        self.modificationDate = resourceValues?.contentModificationDate
        self.lastAccessDate = resourceValues?.contentAccessDate

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .medium

        self.formattedCreationDate = creationDate.map { dateFormatter.string(from: $0) } ?? "Unknown"
        self.formattedModificationDate = modificationDate.map { dateFormatter.string(from: $0) } ?? "Unknown"
        self.formattedLastAccessDate = lastAccessDate.map { dateFormatter.string(from: $0) } ?? "Unknown"

        // Content type
        self.contentType = resourceValues?.contentType?.identifier

        // Owner and Group
        self.ownerName = attributes?[.ownerAccountName] as? String ?? "Unknown"
        self.groupName = attributes?[.groupOwnerAccountName] as? String ?? "Unknown"

        // Permissions
        self.permissions = (attributes?[.posixPermissions] as? Int16) ?? 0
        self.permissionsString = FileAttributes.formatPermissions(permissions)

        // Access flags
        self.isReadable = resourceValues?.isReadable ?? false
        self.isWritable = resourceValues?.isWritable ?? false
        self.isExecutable = resourceValues?.isExecutable ?? false
        self.isHidden = resourceValues?.isHidden ?? false

        // Extended attributes
        var extAttrs: [(String, String)] = []
        if let xattrNames = try? fileManager.listExtendedAttributes(atPath: url.path) {
            for name in xattrNames {
                if let data = try? fileManager.extendedAttribute(name, atPath: url.path) {
                    let value = String(data: data, encoding: .utf8) ?? "\(data.count) bytes"
                    extAttrs.append((name, value))
                }
            }
        }
        self.extendedAttributes = extAttrs

        // App bundle info
        if let bundle = Bundle(url: url) {
            self.version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
            self.copyright = bundle.infoDictionary?["NSHumanReadableCopyright"] as? String
        } else {
            self.version = nil
            self.copyright = nil
        }
    }

    private static func calculateFolderSize(url: URL) -> (Int64, Int) {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        var itemCount = 0

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return (0, 0)
        }

        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) {
                if resourceValues.isDirectory == false {
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                }
                itemCount += 1
            }
        }

        return (totalSize, itemCount)
    }

    private static func formatPermissions(_ permissions: Int16) -> String {
        let owner = formatPermissionTriple((permissions >> 6) & 0o7)
        let group = formatPermissionTriple((permissions >> 3) & 0o7)
        let other = formatPermissionTriple(permissions & 0o7)
        return "\(owner)\(group)\(other) (\(String(format: "%o", permissions)))"
    }

    private static func formatPermissionTriple(_ value: Int16) -> String {
        let r = (value & 0o4) != 0 ? "r" : "-"
        let w = (value & 0o2) != 0 ? "w" : "-"
        let x = (value & 0o1) != 0 ? "x" : "-"
        return "\(r)\(w)\(x)"
    }
}

// Extension to read extended attributes
extension FileManager {
    func listExtendedAttributes(atPath path: String) throws -> [String] {
        let length = listxattr(path, nil, 0, 0)
        guard length > 0 else { return [] }

        var buffer = [CChar](repeating: 0, count: length)
        let result = listxattr(path, &buffer, length, 0)
        guard result > 0 else { return [] }

        var names: [String] = []
        var current = ""
        for char in buffer {
            if char == 0 {
                if !current.isEmpty {
                    names.append(current)
                    current = ""
                }
            } else {
                current.append(Character(UnicodeScalar(UInt8(bitPattern: char))))
            }
        }
        return names
    }

    func extendedAttribute(_ name: String, atPath path: String) throws -> Data {
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return Data() }

        var buffer = [UInt8](repeating: 0, count: length)
        let result = getxattr(path, name, &buffer, length, 0, 0)
        guard result > 0 else { return Data() }

        return Data(buffer)
    }
}

// Media metadata extraction for images, videos, PDFs, and archives
struct MediaMetadata {
    var imageInfo: [(String, String)] = []
    var cameraInfo: [(String, String)] = []
    var exposureInfo: [(String, String)] = []
    var locationInfo: [(String, String)] = []
    var videoInfo: [(String, String)] = []
    var audioInfo: [(String, String)] = []
    var pdfInfo: [(String, String)] = []
    var archiveInfo: [(String, String)] = []
    var documentInfo: [(String, String)] = []

    var isEmpty: Bool {
        imageInfo.isEmpty && cameraInfo.isEmpty && exposureInfo.isEmpty &&
        locationInfo.isEmpty && videoInfo.isEmpty && audioInfo.isEmpty &&
        pdfInfo.isEmpty && archiveInfo.isEmpty && documentInfo.isEmpty
    }

    init(url: URL) async {
        let ext = url.pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "gif", "tiff", "tif", "heic", "heif", "bmp", "webp", "raw", "cr2", "nef", "arw", "dng", "svg"]
        let videoExtensions = ["mp4", "mov", "m4v", "avi", "mkv", "wmv", "flv", "webm", "mpeg", "mpg", "3gp"]
        let audioExtensions = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg", "wma"]
        let archiveExtensions = ["zip", "tar", "gz", "bz2", "xz", "7z", "rar"]

        if imageExtensions.contains(ext) {
            loadImageMetadata(from: url)
        } else if videoExtensions.contains(ext) {
            await loadVideoMetadata(from: url)
        } else if audioExtensions.contains(ext) {
            await loadAudioMetadata(from: url)
        } else if ext == "pdf" {
            loadPDFMetadata(from: url)
        } else if archiveExtensions.contains(ext) {
            loadArchiveMetadata(from: url)
        }
    }

    private mutating func loadImageMetadata(from url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return }

        // Basic image info
        var width: Int?
        var height: Int?

        if let w = properties[kCGImagePropertyPixelWidth as String] as? Int {
            width = w
            imageInfo.append(("Width", "\(w) pixels"))
        }
        if let h = properties[kCGImagePropertyPixelHeight as String] as? Int {
            height = h
            imageInfo.append(("Height", "\(h) pixels"))
        }

        // Aspect ratio
        if let w = width, let h = height, h > 0 {
            let ratio = Double(w) / Double(h)
            let aspectRatio = simplifyAspectRatio(width: w, height: h)
            imageInfo.append(("Aspect Ratio", "\(aspectRatio) (\(String(format: "%.3f", ratio)))"))
        }

        // Check for animation (GIF, APNG)
        let frameCount = CGImageSourceGetCount(source)
        if frameCount > 1 {
            imageInfo.append(("Animated", "Yes (\(frameCount) frames)"))

            // Try to get GIF duration
            if let gifProps = properties[kCGImagePropertyGIFDictionary as String] as? [String: Any],
               let loopCount = gifProps[kCGImagePropertyGIFLoopCount as String] as? Int {
                imageInfo.append(("Loop Count", loopCount == 0 ? "Infinite" : "\(loopCount)"))
            }
        }

        if let depth = properties[kCGImagePropertyDepth as String] as? Int {
            imageInfo.append(("Bit Depth", "\(depth) bits"))
        }
        if let colorModel = properties[kCGImagePropertyColorModel as String] as? String {
            imageInfo.append(("Color Model", colorModel))
        }
        if let profileName = properties[kCGImagePropertyProfileName as String] as? String {
            imageInfo.append(("Color Profile", profileName))
        }
        if let dpiWidth = properties[kCGImagePropertyDPIWidth as String] as? Double {
            imageInfo.append(("DPI", String(format: "%.0f", dpiWidth)))
        }
        if let hasAlpha = properties[kCGImagePropertyHasAlpha as String] as? Bool {
            imageInfo.append(("Has Alpha", hasAlpha ? "Yes" : "No"))
        }

        // EXIF data
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            loadExifData(exif)
        }

        // TIFF data (often contains camera make/model)
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            loadTiffData(tiff)
        }

        // GPS data
        if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            loadGpsData(gps)
        }

        // IPTC data
        if let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            loadIptcData(iptc)
        }
    }

    private mutating func loadExifData(_ exif: [String: Any]) {
        // Camera info
        if let lensMake = exif[kCGImagePropertyExifLensMake as String] as? String {
            cameraInfo.append(("Lens Make", lensMake))
        }
        if let lensModel = exif[kCGImagePropertyExifLensModel as String] as? String {
            cameraInfo.append(("Lens Model", lensModel))
        }
        if let focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double {
            cameraInfo.append(("Focal Length", String(format: "%.2f mm", focalLength)))
        }
        if let focalLength35mm = exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] as? Int {
            cameraInfo.append(("35mm Equivalent", "\(focalLength35mm) mm"))
        }

        // Exposure info
        if let exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double {
            if exposureTime < 1 {
                let denominator = Int(round(1.0 / exposureTime))
                exposureInfo.append(("Shutter Speed", "1/\(denominator) s"))
            } else {
                exposureInfo.append(("Shutter Speed", String(format: "%.1f s", exposureTime)))
            }
        }
        if let fNumber = exif[kCGImagePropertyExifFNumber as String] as? Double {
            exposureInfo.append(("Aperture", String(format: "f/%.1f", fNumber)))
        }
        if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int], let isoValue = iso.first {
            exposureInfo.append(("ISO", "\(isoValue)"))
        }
        if let exposureBias = exif[kCGImagePropertyExifExposureBiasValue as String] as? Double {
            exposureInfo.append(("Exposure Bias", String(format: "%.1f EV", exposureBias)))
        }
        if let exposureMode = exif[kCGImagePropertyExifExposureMode as String] as? Int {
            let modeNames = [0: "Auto", 1: "Manual", 2: "Auto Bracket"]
            exposureInfo.append(("Exposure Mode", modeNames[exposureMode] ?? "Unknown"))
        }
        if let exposureProgram = exif[kCGImagePropertyExifExposureProgram as String] as? Int {
            let programNames = [
                0: "Unknown", 1: "Manual", 2: "Program AE", 3: "Aperture Priority",
                4: "Shutter Priority", 5: "Creative", 6: "Action", 7: "Portrait", 8: "Landscape"
            ]
            exposureInfo.append(("Exposure Program", programNames[exposureProgram] ?? "Unknown"))
        }
        if let meteringMode = exif[kCGImagePropertyExifMeteringMode as String] as? Int {
            let modeNames = [
                0: "Unknown", 1: "Average", 2: "Center-weighted", 3: "Spot",
                4: "Multi-spot", 5: "Pattern", 6: "Partial"
            ]
            exposureInfo.append(("Metering Mode", modeNames[meteringMode] ?? "Unknown"))
        }
        if let whiteBalance = exif[kCGImagePropertyExifWhiteBalance as String] as? Int {
            exposureInfo.append(("White Balance", whiteBalance == 0 ? "Auto" : "Manual"))
        }
        if let flash = exif[kCGImagePropertyExifFlash as String] as? Int {
            let flashFired = (flash & 1) != 0
            exposureInfo.append(("Flash", flashFired ? "Fired" : "Did not fire"))
        }
        if let brightnessValue = exif[kCGImagePropertyExifBrightnessValue as String] as? Double {
            exposureInfo.append(("Brightness", String(format: "%.2f", brightnessValue)))
        }

        // Date
        if let dateOriginal = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            imageInfo.insert(("Date Taken", formatExifDate(dateOriginal)), at: 0)
        }

        // Software
        if let software = exif[kCGImagePropertyExifUserComment as String] as? String {
            imageInfo.append(("Comment", software))
        }
    }

    private mutating func loadTiffData(_ tiff: [String: Any]) {
        if let make = tiff[kCGImagePropertyTIFFMake as String] as? String {
            cameraInfo.insert(("Make", make), at: 0)
        }
        if let model = tiff[kCGImagePropertyTIFFModel as String] as? String {
            cameraInfo.insert(("Model", model), at: min(1, cameraInfo.count))
        }
        if let software = tiff[kCGImagePropertyTIFFSoftware as String] as? String {
            cameraInfo.append(("Software", software))
        }
        if let artist = tiff[kCGImagePropertyTIFFArtist as String] as? String {
            imageInfo.append(("Artist", artist))
        }
        if let copyright = tiff[kCGImagePropertyTIFFCopyright as String] as? String {
            imageInfo.append(("Copyright", copyright))
        }
    }

    private mutating func loadGpsData(_ gps: [String: Any]) {
        var latitude: Double?
        var longitude: Double?
        var latRef: String?
        var lonRef: String?

        if let lat = gps[kCGImagePropertyGPSLatitude as String] as? Double {
            latitude = lat
        }
        if let lon = gps[kCGImagePropertyGPSLongitude as String] as? Double {
            longitude = lon
        }
        if let ref = gps[kCGImagePropertyGPSLatitudeRef as String] as? String {
            latRef = ref
        }
        if let ref = gps[kCGImagePropertyGPSLongitudeRef as String] as? String {
            lonRef = ref
        }

        if let lat = latitude, let lon = longitude {
            let latSign = (latRef == "S") ? -1.0 : 1.0
            let lonSign = (lonRef == "W") ? -1.0 : 1.0
            let finalLat = lat * latSign
            let finalLon = lon * lonSign

            let latDir = finalLat >= 0 ? "N" : "S"
            let lonDir = finalLon >= 0 ? "E" : "W"

            locationInfo.append(("Coordinates", String(format: "%.6f°%@, %.6f°%@",
                abs(finalLat), latDir, abs(finalLon), lonDir)))

            // DMS format
            let latDMS = toDMS(abs(finalLat))
            let lonDMS = toDMS(abs(finalLon))
            locationInfo.append(("Position", "\(latDMS)\(latDir) \(lonDMS)\(lonDir)"))
        }

        if let altitude = gps[kCGImagePropertyGPSAltitude as String] as? Double {
            let altRef = gps[kCGImagePropertyGPSAltitudeRef as String] as? Int ?? 0
            let altSign = altRef == 1 ? -1.0 : 1.0
            locationInfo.append(("Altitude", String(format: "%.1f m", altitude * altSign)))
        }

        if let speed = gps[kCGImagePropertyGPSSpeed as String] as? Double {
            let speedRef = gps[kCGImagePropertyGPSSpeedRef as String] as? String ?? "K"
            let unit = speedRef == "M" ? "mph" : (speedRef == "N" ? "knots" : "km/h")
            locationInfo.append(("Speed", String(format: "%.1f %@", speed, unit)))
        }

        if let imgDirection = gps[kCGImagePropertyGPSImgDirection as String] as? Double {
            locationInfo.append(("Direction", String(format: "%.1f°", imgDirection)))
        }

        if let timestamp = gps[kCGImagePropertyGPSTimeStamp as String] as? String {
            locationInfo.append(("GPS Time", timestamp))
        }
        if let datestamp = gps[kCGImagePropertyGPSDateStamp as String] as? String {
            locationInfo.append(("GPS Date", datestamp))
        }
    }

    private mutating func loadIptcData(_ iptc: [String: Any]) {
        if let caption = iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String {
            imageInfo.append(("Caption", caption))
        }
        if let keywords = iptc[kCGImagePropertyIPTCKeywords as String] as? [String] {
            imageInfo.append(("Keywords", keywords.joined(separator: ", ")))
        }
        if let city = iptc[kCGImagePropertyIPTCCity as String] as? String {
            locationInfo.append(("City", city))
        }
        if let country = iptc[kCGImagePropertyIPTCCountryPrimaryLocationName as String] as? String {
            locationInfo.append(("Country", country))
        }
    }

    private mutating func loadVideoMetadata(from url: URL) async {
        let asset = AVURLAsset(url: url)

        // Duration
        if let duration = try? await asset.load(.duration),
           duration.seconds > 0 {
            videoInfo.append(("Duration", formatDuration(duration.seconds)))
        }

        // Video track info
        if let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first {
            let size = (try? await videoTrack.load(.naturalSize)) ?? .zero
            let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
            if size != .zero {
                let isPortrait = transform.a == 0 && abs(transform.b) == 1
                let width = isPortrait ? Int(size.height) : Int(size.width)
                let height = isPortrait ? Int(size.width) : Int(size.height)
                videoInfo.append(("Resolution", "\(width) × \(height)"))
            }

            let frameRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
            if frameRate > 0 {
                videoInfo.append(("Frame Rate", String(format: "%.2f fps", frameRate)))
            }

            let bitRate = (try? await videoTrack.load(.estimatedDataRate)) ?? 0
            if bitRate > 0 {
                videoInfo.append(("Video Bitrate", formatBitrate(bitRate)))
            }

            // Codec
            if let formatDescriptions = try? await videoTrack.load(.formatDescriptions),
               let formatDesc = formatDescriptions.first {
                let codec = CMFormatDescriptionGetMediaSubType(formatDesc)
                let codecString = fourCharCodeToString(codec)
                videoInfo.append(("Video Codec", codecString))
            }
        }

        // Audio track info
        if let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first {
            if let formatDescriptions = try? await audioTrack.load(.formatDescriptions),
               let formatDesc = formatDescriptions.first {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                    let sampleRate = asbd.pointee.mSampleRate
                    audioInfo.append(("Sample Rate", "\(Int(sampleRate)) Hz"))

                    let channels = asbd.pointee.mChannelsPerFrame
                    let channelString = channels == 1 ? "Mono" : (channels == 2 ? "Stereo" : "\(channels) channels")
                    audioInfo.append(("Channels", channelString))
                }

                let codec = CMFormatDescriptionGetMediaSubType(formatDesc)
                let codecString = fourCharCodeToString(codec)
                audioInfo.append(("Audio Codec", codecString))
            }

            let bitRate = (try? await audioTrack.load(.estimatedDataRate)) ?? 0
            if bitRate > 0 {
                audioInfo.append(("Audio Bitrate", formatBitrate(bitRate)))
            }
        }

        // Metadata
        await loadAVMetadata(from: asset)
    }

    private mutating func loadAudioMetadata(from url: URL) async {
        let asset = AVURLAsset(url: url)

        // Duration
        if let duration = try? await asset.load(.duration),
           duration.seconds > 0 {
            audioInfo.append(("Duration", formatDuration(duration.seconds)))
        }

        // Audio track info
        if let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first {
            if let formatDescriptions = try? await audioTrack.load(.formatDescriptions),
               let formatDesc = formatDescriptions.first {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                    let sampleRate = asbd.pointee.mSampleRate
                    audioInfo.append(("Sample Rate", "\(Int(sampleRate)) Hz"))

                    let channels = asbd.pointee.mChannelsPerFrame
                    let channelString = channels == 1 ? "Mono" : (channels == 2 ? "Stereo" : "\(channels) channels")
                    audioInfo.append(("Channels", channelString))

                    let bitsPerChannel = asbd.pointee.mBitsPerChannel
                    if bitsPerChannel > 0 {
                        audioInfo.append(("Bit Depth", "\(bitsPerChannel) bits"))
                    }
                }

                let codec = CMFormatDescriptionGetMediaSubType(formatDesc)
                let codecString = fourCharCodeToString(codec)
                audioInfo.append(("Codec", codecString))
            }

            let bitRate = (try? await audioTrack.load(.estimatedDataRate)) ?? 0
            if bitRate > 0 {
                audioInfo.append(("Bitrate", formatBitrate(bitRate)))
            }
        }

        // Metadata
        await loadAVMetadata(from: asset)
    }

    private mutating func loadAVMetadata(from asset: AVURLAsset) async {
        guard let metadata = try? await asset.load(.metadata) else { return }

        for item in metadata {
            guard let key = item.commonKey?.rawValue ?? item.key as? String,
                  let value = try? await item.load(.stringValue) else { continue }

            switch key {
            case "title", AVMetadataKey.commonKeyTitle.rawValue:
                audioInfo.insert(("Title", value), at: 0)
            case "artist", AVMetadataKey.commonKeyArtist.rawValue:
                audioInfo.append(("Artist", value))
            case "albumName", AVMetadataKey.commonKeyAlbumName.rawValue:
                audioInfo.append(("Album", value))
            case "creationDate", AVMetadataKey.commonKeyCreationDate.rawValue:
                videoInfo.insert(("Created", value), at: 0)
            case "make", AVMetadataKey.commonKeyMake.rawValue:
                cameraInfo.append(("Make", value))
            case "model", AVMetadataKey.commonKeyModel.rawValue:
                cameraInfo.append(("Model", value))
            case "software", AVMetadataKey.commonKeySoftware.rawValue:
                cameraInfo.append(("Software", value))
            case "location", AVMetadataKey.commonKeyLocation.rawValue:
                locationInfo.append(("Location", value))
            default:
                break
            }
        }
    }

    // PDF metadata
    private mutating func loadPDFMetadata(from url: URL) {
        guard let pdfDoc = CGPDFDocument(url as CFURL) else { return }

        // Page count
        let pageCount = pdfDoc.numberOfPages
        pdfInfo.append(("Pages", "\(pageCount)"))

        // Get first page dimensions
        if let page = pdfDoc.page(at: 1) {
            let mediaBox = page.getBoxRect(.mediaBox)
            let width = Int(mediaBox.width)
            let height = Int(mediaBox.height)
            pdfInfo.append(("Page Size", "\(width) × \(height) pts"))

            // Convert to inches (72 pts per inch)
            let widthInches = mediaBox.width / 72.0
            let heightInches = mediaBox.height / 72.0
            pdfInfo.append(("Dimensions", String(format: "%.2f × %.2f in", widthInches, heightInches)))
        }

        // PDF metadata from info dictionary
        if let info = pdfDoc.info {
            if let title = getStringFromPDFDict(info, key: "Title") {
                pdfInfo.append(("Title", title))
            }
            if let author = getStringFromPDFDict(info, key: "Author") {
                pdfInfo.append(("Author", author))
            }
            if let subject = getStringFromPDFDict(info, key: "Subject") {
                pdfInfo.append(("Subject", subject))
            }
            if let creator = getStringFromPDFDict(info, key: "Creator") {
                pdfInfo.append(("Creator", creator))
            }
            if let producer = getStringFromPDFDict(info, key: "Producer") {
                pdfInfo.append(("Producer", producer))
            }
            if let creationDate = getStringFromPDFDict(info, key: "CreationDate") {
                pdfInfo.append(("Created", formatPDFDate(creationDate)))
            }
            if let modDate = getStringFromPDFDict(info, key: "ModDate") {
                pdfInfo.append(("Modified", formatPDFDate(modDate)))
            }
        }

        // PDF version
        var majorVersion: Int32 = 0
        var minorVersion: Int32 = 0
        pdfDoc.getVersion(majorVersion: &majorVersion, minorVersion: &minorVersion)
        pdfInfo.append(("PDF Version", "\(majorVersion).\(minorVersion)"))

        // Encryption status
        if pdfDoc.isEncrypted {
            pdfInfo.append(("Encrypted", "Yes"))
            pdfInfo.append(("Unlocked", pdfDoc.isUnlocked ? "Yes" : "No"))
        }

        // Check permissions
        if pdfDoc.allowsCopying {
            pdfInfo.append(("Allows Copying", "Yes"))
        }
        if pdfDoc.allowsPrinting {
            pdfInfo.append(("Allows Printing", "Yes"))
        }
    }

    private func getStringFromPDFDict(_ dict: CGPDFDictionaryRef, key: String) -> String? {
        var cfString: CGPDFStringRef?
        if CGPDFDictionaryGetString(dict, key, &cfString), let cfString = cfString,
           let string = CGPDFStringCopyTextString(cfString) as String? {
            return string
        }
        return nil
    }

    // Archive metadata
    private mutating func loadArchiveMetadata(from url: URL) {
        let ext = url.pathExtension.lowercased()

        if ext == "zip" {
            loadZipMetadata(from: url)
        } else {
            // For other archives, just show basic info
            archiveInfo.append(("Format", ext.uppercased()))
        }
    }

    private mutating func loadZipMetadata(from url: URL) {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fileHandle.close() }

        // Read ZIP end of central directory to get file count
        guard let fileSize = try? fileHandle.seekToEnd() else { return }

        // Search for End of Central Directory signature (0x06054b50)
        let searchSize = min(fileSize, 65557) // Max comment size + EOCD size
        let searchStart = fileSize - searchSize

        try? fileHandle.seek(toOffset: searchStart)
        guard let searchData = try? fileHandle.readToEnd() else { return }

        // Find EOCD signature
        let signature: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        var eocdOffset: Int?

        for i in stride(from: searchData.count - 22, through: 0, by: -1) {
            if searchData[i] == signature[0] &&
               searchData[i+1] == signature[1] &&
               searchData[i+2] == signature[2] &&
               searchData[i+3] == signature[3] {
                eocdOffset = i
                break
            }
        }

        if let offset = eocdOffset {
            // Parse EOCD
            let totalEntries = UInt16(searchData[offset + 10]) | (UInt16(searchData[offset + 11]) << 8)
            let centralDirSize = UInt32(searchData[offset + 12]) |
                                (UInt32(searchData[offset + 13]) << 8) |
                                (UInt32(searchData[offset + 14]) << 16) |
                                (UInt32(searchData[offset + 15]) << 24)

            archiveInfo.append(("Format", "ZIP"))
            archiveInfo.append(("Files", "\(totalEntries)"))

            // Estimate compression ratio
            if centralDirSize > 0 {
                let compressedSize = fileSize
                archiveInfo.append(("Archive Size", formatFileSize(Int64(compressedSize))))
            }
        }
    }

    // Helper functions
    private func formatExifDate(_ dateString: String) -> String {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

        if let date = inputFormatter.date(from: dateString) {
            let outputFormatter = DateFormatter()
            outputFormatter.dateStyle = .long
            outputFormatter.timeStyle = .medium
            return outputFormatter.string(from: date)
        }
        return dateString
    }

    private func formatPDFDate(_ dateString: String) -> String {
        // PDF dates are in format: D:YYYYMMDDHHmmSSOHH'mm'
        var cleaned = dateString
        if cleaned.hasPrefix("D:") {
            cleaned = String(cleaned.dropFirst(2))
        }

        if cleaned.count >= 14 {
            let year = String(cleaned.prefix(4))
            let month = String(cleaned.dropFirst(4).prefix(2))
            let day = String(cleaned.dropFirst(6).prefix(2))
            let hour = String(cleaned.dropFirst(8).prefix(2))
            let minute = String(cleaned.dropFirst(10).prefix(2))
            let second = String(cleaned.dropFirst(12).prefix(2))

            return "\(year)-\(month)-\(day) \(hour):\(minute):\(second)"
        }

        return dateString
    }

    private func simplifyAspectRatio(width: Int, height: Int) -> String {
        func gcd(_ a: Int, _ b: Int) -> Int {
            return b == 0 ? a : gcd(b, a % b)
        }

        let divisor = gcd(width, height)
        let w = width / divisor
        let h = height / divisor

        // Common aspect ratios
        let ratio = Double(width) / Double(height)
        if abs(ratio - 16.0/9.0) < 0.01 { return "16:9" }
        if abs(ratio - 4.0/3.0) < 0.01 { return "4:3" }
        if abs(ratio - 3.0/2.0) < 0.01 { return "3:2" }
        if abs(ratio - 1.0) < 0.01 { return "1:1" }
        if abs(ratio - 21.0/9.0) < 0.01 { return "21:9" }
        if abs(ratio - 9.0/16.0) < 0.01 { return "9:16" }

        // If simplified ratio is reasonable, use it
        if w <= 100 && h <= 100 {
            return "\(w):\(h)"
        }

        return String(format: "%.2f:1", ratio)
    }

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func toDMS(_ decimal: Double) -> String {
        let degrees = Int(decimal)
        let minutesDecimal = (decimal - Double(degrees)) * 60
        let minutes = Int(minutesDecimal)
        let seconds = (minutesDecimal - Double(minutes)) * 60
        return String(format: "%d°%02d'%.2f\"", degrees, minutes, seconds)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    private func formatBitrate(_ bitrate: Float) -> String {
        if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", bitrate / 1_000_000)
        } else {
            return String(format: "%.0f kbps", bitrate / 1000)
        }
    }

    private func fourCharCodeToString(_ code: FourCharCode) -> String {
        let chars: [Character] = [
            Character(UnicodeScalar((code >> 24) & 0xFF)!),
            Character(UnicodeScalar((code >> 16) & 0xFF)!),
            Character(UnicodeScalar((code >> 8) & 0xFF)!),
            Character(UnicodeScalar(code & 0xFF)!)
        ]
        return String(chars).trimmingCharacters(in: .whitespaces)
    }
}

struct FileInfoWindow: View {
    @EnvironmentObject private var appSettings: AppSettings
    let item: FileItem
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack {
                Text("Info - \(item.displayName(showFileExtensions: appSettings.showFileExtensions))")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            FileInfoView(item: item)
        }
    }
}
