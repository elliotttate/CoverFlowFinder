import AppKit
import SwiftUI

// MARK: - File Name Cell View

final class FileNameCellView: NSTableCellView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let tagDotsStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.cell?.truncatesLastVisibleLine = true
        nameLabel.maximumNumberOfLines = 1
        addSubview(nameLabel)

        tagDotsStack.translatesAutoresizingMaskIntoConstraints = false
        tagDotsStack.orientation = .horizontal
        tagDotsStack.spacing = 2
        tagDotsStack.alignment = .centerY
        addSubview(tagDotsStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            tagDotsStack.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 6),
            tagDotsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagDotsStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])

        // Allow name label to compress but keep minimum
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tagDotsStack.setContentHuggingPriority(.required, for: .horizontal)
    }

    func configure(item: FileItem, thumbnail: NSImage?, appSettings: AppSettings) {
        iconView.image = thumbnail ?? item.icon

        let iconSize = appSettings.listIconSizeValue
        for constraint in iconView.constraints {
            if constraint.firstAttribute == .width || constraint.firstAttribute == .height {
                constraint.constant = iconSize
            }
        }

        nameLabel.stringValue = item.name
        nameLabel.font = NSFont.systemFont(ofSize: appSettings.listFontSize)
        nameLabel.textColor = .labelColor

        // Setup tag dots
        tagDotsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if appSettings.showItemTags {
            for tagName in item.tags.prefix(3) {
                if let tag = FinderTag.from(name: tagName) {
                    let dot = NSView()
                    dot.translatesAutoresizingMaskIntoConstraints = false
                    dot.wantsLayer = true
                    dot.layer?.backgroundColor = NSColor(tag.color).cgColor
                    dot.layer?.cornerRadius = 5

                    NSLayoutConstraint.activate([
                        dot.widthAnchor.constraint(equalToConstant: 10),
                        dot.heightAnchor.constraint(equalToConstant: 10),
                    ])

                    tagDotsStack.addArrangedSubview(dot)
                }
            }
        }

        tagDotsStack.isHidden = tagDotsStack.arrangedSubviews.isEmpty
    }
}

// MARK: - Date Cell View

final class DateCellView: NSTableCellView {
    private let dateLabel = NSTextField(labelWithString: "")
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        dateLabel.translatesAutoresizingMaskIntoConstraints = false
        dateLabel.lineBreakMode = .byTruncatingTail
        dateLabel.maximumNumberOfLines = 1
        addSubview(dateLabel)

        NSLayoutConstraint.activate([
            dateLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            dateLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            dateLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(date: Date?, appSettings: AppSettings) {
        if let date = date {
            dateLabel.stringValue = Self.dateFormatter.string(from: date)
        } else {
            dateLabel.stringValue = "--"
        }
        dateLabel.font = NSFont.systemFont(ofSize: max(9, appSettings.listFontSize - 2))
        dateLabel.textColor = .secondaryLabelColor
    }
}

// MARK: - Size Cell View

final class SizeCellView: NSTableCellView {
    private let sizeLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.lineBreakMode = .byTruncatingTail
        sizeLabel.maximumNumberOfLines = 1
        sizeLabel.alignment = .left
        addSubview(sizeLabel)

        NSLayoutConstraint.activate([
            sizeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            sizeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            sizeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(item: FileItem, appSettings: AppSettings) {
        sizeLabel.stringValue = item.formattedSize
        sizeLabel.font = NSFont.systemFont(ofSize: max(9, appSettings.listFontSize - 2))
        sizeLabel.textColor = .secondaryLabelColor
    }
}

// MARK: - Kind Cell View

final class KindCellView: NSTableCellView {
    private let kindLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        kindLabel.translatesAutoresizingMaskIntoConstraints = false
        kindLabel.lineBreakMode = .byTruncatingTail
        kindLabel.maximumNumberOfLines = 1
        addSubview(kindLabel)

        NSLayoutConstraint.activate([
            kindLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            kindLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            kindLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(item: FileItem, appSettings: AppSettings) {
        kindLabel.stringValue = item.kindDescription
        kindLabel.font = NSFont.systemFont(ofSize: max(9, appSettings.listFontSize - 2))
        kindLabel.textColor = .secondaryLabelColor
    }
}

// MARK: - Tags Cell View

final class TagsCellView: NSTableCellView {
    private let tagsStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        tagsStack.translatesAutoresizingMaskIntoConstraints = false
        tagsStack.orientation = .horizontal
        tagsStack.spacing = 4
        tagsStack.alignment = .centerY
        addSubview(tagsStack)

        NSLayoutConstraint.activate([
            tagsStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            tagsStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            tagsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func configure(item: FileItem, appSettings: AppSettings) {
        // Clear existing tags
        tagsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard appSettings.showItemTags else {
            tagsStack.isHidden = true
            return
        }

        let tags = FileTagManager.getTags(for: item.url)
        tagsStack.isHidden = tags.isEmpty

        for tagName in tags.prefix(3) {
            let badge = TagBadgeView(tagName: tagName)
            tagsStack.addArrangedSubview(badge)
        }

        if tags.count > 3 {
            let moreLabel = NSTextField(labelWithString: "+\(tags.count - 3)")
            moreLabel.font = NSFont.systemFont(ofSize: 10)
            moreLabel.textColor = .secondaryLabelColor
            tagsStack.addArrangedSubview(moreLabel)
        }
    }
}

// MARK: - Tag Badge View (AppKit)

final class TagBadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var tagColor: NSColor = .controlAccentColor

    init(tagName: String) {
        super.init(frame: .zero)
        setupViews()
        configure(tagName: tagName)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 10)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    private func configure(tagName: String) {
        label.stringValue = tagName

        if let finderTag = FinderTag.from(name: tagName) {
            tagColor = NSColor(finderTag.color)
        } else {
            tagColor = .controlAccentColor
        }

        label.textColor = tagColor
        layer?.backgroundColor = tagColor.withAlphaComponent(0.3).cgColor
    }
}
