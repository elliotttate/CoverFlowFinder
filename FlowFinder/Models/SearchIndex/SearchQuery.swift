import Foundation

/// Represents a parsed search query with filters
struct SearchQuery {
    /// The filename pattern to search for (nil means match all)
    var filenamePattern: String?

    /// Whether the filename pattern is a regex
    var isRegex: Bool = false

    /// Extension filter (e.g., ["pdf", "doc"])
    var extensions: [String] = []

    /// Type filter
    var fileType: FileTypeFilter?

    /// Size filters
    var minSize: Int64?
    var maxSize: Int64?

    /// Date modified filters
    var modifiedAfter: Date?
    var modifiedBefore: Date?

    /// Date created filters
    var createdAfter: Date?
    var createdBefore: Date?

    /// Path must contain this string
    var pathContains: String?

    enum FileTypeFilter {
        case file
        case folder
    }

    /// Parse a query string into a SearchQuery
    static func parse(_ query: String) -> SearchQuery {
        var result = SearchQuery()
        var remainingTerms: [String] = []

        let components = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        for component in components {
            if component.hasPrefix("/") && component.hasSuffix("/") && component.count > 2 {
                // Regex pattern
                let pattern = String(component.dropFirst().dropLast())
                result.filenamePattern = pattern
                result.isRegex = true
            } else if component.lowercased().hasPrefix("ext:") {
                // Extension filter: ext:pdf or ext:pdf,doc,docx
                let extPart = String(component.dropFirst(4))
                result.extensions = extPart.lowercased().split(separator: ",").map(String.init)
            } else if component.lowercased().hasPrefix("type:") {
                // Type filter: type:file or type:folder
                let typePart = String(component.dropFirst(5)).lowercased()
                if typePart == "file" || typePart == "files" {
                    result.fileType = .file
                } else if typePart == "folder" || typePart == "folders" || typePart == "dir" || typePart == "directory" {
                    result.fileType = .folder
                }
            } else if component.lowercased().hasPrefix("size:") {
                // Size filter: size:>10MB or size:<1KB or size:10MB-100MB
                let sizePart = String(component.dropFirst(5))
                parseSize(sizePart, into: &result)
            } else if component.lowercased().hasPrefix("path:") {
                // Path filter: path:Documents
                result.pathContains = String(component.dropFirst(5))
            } else if component.lowercased().hasPrefix("dm:") {
                // Date modified filter: dm:today or dm:2024-01
                let datePart = String(component.dropFirst(3))
                parseDateModified(datePart, into: &result)
            } else if component.lowercased().hasPrefix("dc:") {
                // Date created filter: dc:today or dc:2024-01
                let datePart = String(component.dropFirst(3))
                parseDateCreated(datePart, into: &result)
            } else {
                // Regular search term
                remainingTerms.append(component)
            }
        }

        // Combine remaining terms as filename pattern (if not already a regex)
        if !remainingTerms.isEmpty && !result.isRegex {
            result.filenamePattern = remainingTerms.joined(separator: " ")
        }

        return result
    }

    /// Check if an indexed file matches this query
    func matches(_ file: IndexedFile) -> Bool {
        // Check extension filter
        if !extensions.isEmpty {
            if !extensions.contains(file.fileExtension) {
                return false
            }
        }

        // Check type filter
        if let typeFilter = fileType {
            switch typeFilter {
            case .file:
                if file.isDirectory { return false }
            case .folder:
                if !file.isDirectory { return false }
            }
        }

        // Check size filters
        if let minSize = minSize, file.size < minSize {
            return false
        }
        if let maxSize = maxSize, file.size > maxSize {
            return false
        }

        // Check path filter
        if let pathContains = pathContains {
            if !file.path.localizedCaseInsensitiveContains(pathContains) {
                return false
            }
        }

        // Check date modified filters
        if let modAfter = modifiedAfter, let modDate = file.modificationDate {
            if modDate < modAfter { return false }
        }
        if let modBefore = modifiedBefore, let modDate = file.modificationDate {
            if modDate > modBefore { return false }
        }

        // Check date created filters
        if let createAfter = createdAfter, let createDate = file.creationDate {
            if createDate < createAfter { return false }
        }
        if let createBefore = createdBefore, let createDate = file.creationDate {
            if createDate > createBefore { return false }
        }

        return true
    }

    // MARK: - Private Parsing Helpers

    private static func parseSize(_ sizePart: String, into query: inout SearchQuery) {
        let sizeStr = sizePart.uppercased()

        if sizeStr.hasPrefix(">") {
            // Greater than
            if let bytes = parseSizeValue(String(sizeStr.dropFirst())) {
                query.minSize = bytes
            }
        } else if sizeStr.hasPrefix("<") {
            // Less than
            if let bytes = parseSizeValue(String(sizeStr.dropFirst())) {
                query.maxSize = bytes
            }
        } else if sizeStr.contains("-") {
            // Range: 10MB-100MB
            let parts = sizeStr.split(separator: "-")
            if parts.count == 2 {
                query.minSize = parseSizeValue(String(parts[0]))
                query.maxSize = parseSizeValue(String(parts[1]))
            }
        } else {
            // Exact size (treat as approximate - within 10%)
            if let bytes = parseSizeValue(sizeStr) {
                query.minSize = Int64(Double(bytes) * 0.9)
                query.maxSize = Int64(Double(bytes) * 1.1)
            }
        }
    }

    private static func parseSizeValue(_ str: String) -> Int64? {
        var numStr = str
        var multiplier: Int64 = 1

        if str.hasSuffix("KB") || str.hasSuffix("K") {
            numStr = str.replacingOccurrences(of: "KB", with: "").replacingOccurrences(of: "K", with: "")
            multiplier = 1024
        } else if str.hasSuffix("MB") || str.hasSuffix("M") {
            numStr = str.replacingOccurrences(of: "MB", with: "").replacingOccurrences(of: "M", with: "")
            multiplier = 1024 * 1024
        } else if str.hasSuffix("GB") || str.hasSuffix("G") {
            numStr = str.replacingOccurrences(of: "GB", with: "").replacingOccurrences(of: "G", with: "")
            multiplier = 1024 * 1024 * 1024
        } else if str.hasSuffix("TB") || str.hasSuffix("T") {
            numStr = str.replacingOccurrences(of: "TB", with: "").replacingOccurrences(of: "T", with: "")
            multiplier = 1024 * 1024 * 1024 * 1024
        } else if str.hasSuffix("B") {
            numStr = str.replacingOccurrences(of: "B", with: "")
        }

        guard let num = Double(numStr) else { return nil }
        return Int64(num * Double(multiplier))
    }

    private static func parseDateModified(_ datePart: String, into query: inout SearchQuery) {
        let (after, before) = parseDateRange(datePart)
        query.modifiedAfter = after
        query.modifiedBefore = before
    }

    private static func parseDateCreated(_ datePart: String, into query: inout SearchQuery) {
        let (after, before) = parseDateRange(datePart)
        query.createdAfter = after
        query.createdBefore = before
    }

    private static func parseDateRange(_ datePart: String) -> (after: Date?, before: Date?) {
        let calendar = Calendar.current
        let now = Date()

        let lowered = datePart.lowercased()

        // Special keywords
        if lowered == "today" {
            let startOfDay = calendar.startOfDay(for: now)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)
            return (startOfDay, endOfDay)
        } else if lowered == "yesterday" {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
            let startOfDay = calendar.startOfDay(for: yesterday)
            let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)
            return (startOfDay, endOfDay)
        } else if lowered == "thisweek" {
            let startOfWeek = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))
            let endOfWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: startOfWeek!)
            return (startOfWeek, endOfWeek)
        } else if lowered == "thismonth" {
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            let endOfMonth = calendar.date(byAdding: .month, value: 1, to: startOfMonth!)
            return (startOfMonth, endOfMonth)
        } else if lowered == "thisyear" {
            let startOfYear = calendar.date(from: calendar.dateComponents([.year], from: now))
            let endOfYear = calendar.date(byAdding: .year, value: 1, to: startOfYear!)
            return (startOfYear, endOfYear)
        }

        // Try parsing as YYYY-MM-DD, YYYY-MM, or YYYY
        let dateFormatter = DateFormatter()

        // Try YYYY-MM-DD
        dateFormatter.dateFormat = "yyyy-MM-dd"
        if let date = dateFormatter.date(from: datePart) {
            let endDate = calendar.date(byAdding: .day, value: 1, to: date)
            return (date, endDate)
        }

        // Try YYYY-MM
        dateFormatter.dateFormat = "yyyy-MM"
        if let date = dateFormatter.date(from: datePart) {
            let endDate = calendar.date(byAdding: .month, value: 1, to: date)
            return (date, endDate)
        }

        // Try YYYY
        dateFormatter.dateFormat = "yyyy"
        if let date = dateFormatter.date(from: datePart) {
            let endDate = calendar.date(byAdding: .year, value: 1, to: date)
            return (date, endDate)
        }

        return (nil, nil)
    }
}
