import AppKit
import SwiftUI

// MARK: - File Name Cell View

protocol FileNameCellViewDelegate: AnyObject {
    func fileNameCellView(_ cell: FileNameCellView, didRenameItem item: FileItem, to newName: String)
    func fileNameCellViewDidCancelRename(_ cell: FileNameCellView)
}

final class FileNameCellView: NSTableCellView, NSTextFieldDelegate {
    private let iconView = NSImageView()
    private let nameTextField = EditableTextField()
    private let tagDotsStack = NSStackView()

    weak var delegate: FileNameCellViewDelegate?
    private var currentItem: FileItem?
    private(set) var isEditing = false

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

        nameTextField.translatesAutoresizingMaskIntoConstraints = false
        nameTextField.isBordered = false
        nameTextField.drawsBackground = false
        nameTextField.isEditable = false  // Start non-editable
        nameTextField.isSelectable = false
        nameTextField.lineBreakMode = .byTruncatingTail
        nameTextField.cell?.truncatesLastVisibleLine = true
        nameTextField.maximumNumberOfLines = 1
        nameTextField.focusRingType = .exterior
        nameTextField.delegate = self
        addSubview(nameTextField)

        // Set as the textField for the cell view (important for NSTableView editing)
        self.textField = nameTextField

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

            nameTextField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameTextField.trailingAnchor.constraint(lessThanOrEqualTo: tagDotsStack.leadingAnchor, constant: -4),
            nameTextField.centerYAnchor.constraint(equalTo: centerYAnchor),

            tagDotsStack.leadingAnchor.constraint(greaterThanOrEqualTo: nameTextField.trailingAnchor, constant: 6),
            tagDotsStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagDotsStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])

        // Allow name label to compress but keep minimum
        nameTextField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tagDotsStack.setContentHuggingPriority(.required, for: .horizontal)
    }

    func configure(item: FileItem, thumbnail: NSImage?, appSettings: AppSettings) {
        currentItem = item
        iconView.image = thumbnail ?? item.icon

        let iconSize = appSettings.listIconSizeValue
        for constraint in iconView.constraints {
            if constraint.firstAttribute == .width || constraint.firstAttribute == .height {
                constraint.constant = iconSize
            }
        }

        // Only update text if not currently editing
        if !isEditing {
            nameTextField.stringValue = item.name
        }
        nameTextField.font = NSFont.systemFont(ofSize: appSettings.listFontSize)
        nameTextField.textColor = .labelColor

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

    // MARK: - Inline Editing

    func startEditing() {
        guard let item = currentItem, !isEditing else { return }

        isEditing = true

        // Set up for editing
        let nameWithoutExt = item.isDirectory ? item.name : item.url.deletingPathExtension().lastPathComponent
        nameTextField.stringValue = nameWithoutExt
        nameTextField.isEditable = true
        nameTextField.isSelectable = true
        nameTextField.isBordered = true
        nameTextField.drawsBackground = true
        nameTextField.backgroundColor = .textBackgroundColor

        // Find the parent table view and block it from stealing focus
        var tableView: NSTableView? = nil
        var view: NSView? = self.superview
        while view != nil {
            if let tv = view as? NSTableView {
                tableView = tv
                break
            }
            view = view?.superview
        }

        // Block table view from accepting first responder
        if let keyboardTableView = tableView as? KeyboardTableView {
            keyboardTableView.shouldRefuseFirstResponder = true
        }

        // Become first responder - use selectText which properly activates the field editor
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isEditing else { return }

            // First, end any existing editing in the window
            self.window?.endEditing(for: nil)

            // Now start editing our field
            self.nameTextField.selectText(nil)
        }
    }

    func cancelEditing() {
        guard isEditing else { return }

        endEditingMode()

        // Restore original name
        if let item = currentItem {
            nameTextField.stringValue = item.name
        }

        delegate?.fileNameCellViewDidCancelRename(self)
    }

    private func endEditingMode() {
        isEditing = false
        nameTextField.isEditable = false
        nameTextField.isSelectable = false
        nameTextField.isBordered = false
        nameTextField.drawsBackground = false

        // Restore table view's ability to accept first responder
        var view: NSView? = self.superview
        while view != nil {
            if let keyboardTableView = view as? KeyboardTableView {
                keyboardTableView.shouldRefuseFirstResponder = false
                break
            }
            view = view?.superview
        }
    }

    private func commitEditing() {
        guard isEditing, let item = currentItem else { return }

        let trimmedName = nameTextField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalNameWithoutExt = item.isDirectory ? item.name : item.url.deletingPathExtension().lastPathComponent

        endEditingMode()

        // Only rename if name actually changed and is not empty
        if !trimmedName.isEmpty && trimmedName != originalNameWithoutExt {
            // Reconstruct full name with extension
            let ext = item.url.pathExtension
            let newName = ext.isEmpty ? trimmedName : "\(trimmedName).\(ext)"
            delegate?.fileNameCellView(self, didRenameItem: item, to: newName)
        } else {
            // Restore original name
            nameTextField.stringValue = item.name
            delegate?.fileNameCellViewDidCancelRename(self)
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        // Only handle notifications from our text field
        guard obj.object as AnyObject === nameTextField else { return }
        guard isEditing else { return }

        commitEditing()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape key pressed
            cancelEditing()
            return true
        }
        return false
    }
}

// MARK: - Editable TextField that properly handles focus

final class EditableTextField: NSTextField {
    override var acceptsFirstResponder: Bool {
        return isEditable
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
