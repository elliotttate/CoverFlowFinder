import AppKit
import SwiftUI

// MARK: - File Name Cell View

@MainActor
protocol FileNameCellViewDelegate: AnyObject {
    func fileNameCellView(_ cell: FileNameCellView, didRenameItem item: FileItem, to newName: String)
    func fileNameCellViewDidCancelRename(_ cell: FileNameCellView)
    func fileNameCellView(_ cell: FileNameCellView, commitRenameAndMoveNext item: FileItem, newName: String)
    func fileNameCellView(_ cell: FileNameCellView, commitRenameAndMovePrevious item: FileItem, newName: String)
    /// Editing was abandoned because the cell was recycled (e.g. scrolled away). Sent asynchronously.
    func fileNameCellView(_ cell: FileNameCellView, didAbortEditingOf item: FileItem)
}

final class FileNameCellView: NSTableCellView, NSTextFieldDelegate {
    private let iconView = NSImageView()
    private let nameTextField = EditableTextField()
    private let tagDotsStack = NSStackView()
    private var iconWidthConstraint: NSLayoutConstraint?
    private var iconHeightConstraint: NSLayoutConstraint?

    weak var delegate: FileNameCellViewDelegate?
    private var currentItem: FileItem?
    /// Rename intent: set when editing starts; cleared when it ends, is cancelled or the cell is reused.
    private(set) var isEditing = false
    private var editingStartedAt = Date.distantPast
    /// How long editing may stay "starting" (field editor not attached yet) before it counts as abandoned.
    private static let editingStartGracePeriod: TimeInterval = 1.0

    /// URL of the item this cell currently shows.
    var representedURL: URL? { currentItem?.url }

    /// True while the name is really being edited: the field editor is attached, or editing was
    /// just started and the field editor is about to attach. Derived from the field editor so it
    /// can't stay true after the field editor has gone away.
    var isEditingActive: Bool {
        guard isEditing, window != nil else { return false }
        if nameTextField.currentEditor() != nil { return true }
        return Date().timeIntervalSince(editingStartedAt) < Self.editingStartGracePeriod
    }

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

        let iconWidth = iconView.widthAnchor.constraint(equalToConstant: 16)
        let iconHeight = iconView.heightAnchor.constraint(equalToConstant: 16)
        iconWidthConstraint = iconWidth
        iconHeightConstraint = iconHeight

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth,
            iconHeight,

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

    /// - Parameter tags: The item's tags, or nil while they're still loading (no dots shown).
    func configure(item: FileItem, thumbnail: NSImage?, tags: [String]?, appSettings: AppSettings) {
        currentItem = item
        iconView.image = thumbnail ?? item.icon

        let iconSize = appSettings.listIconSizeValue
        if iconWidthConstraint?.constant != iconSize {
            iconWidthConstraint?.constant = iconSize
            iconHeightConstraint?.constant = iconSize
        }

        // Only update text if not currently editing
        if !isEditing {
            nameTextField.stringValue = Self.displayText(for: item, showFileExtensions: appSettings.showFileExtensions)
        }
        nameTextField.font = NSFont.systemFont(ofSize: appSettings.listFontSize)
        nameTextField.textColor = .labelColor
        updateHiddenItemDimming()

        setTags(tags ?? [], showTags: appSettings.showItemTags)
    }

    /// The table dims cut items' whole cells (0.5): a hidden item's icon and name are then not
    /// dimmed again.
    override var alphaValue: CGFloat {
        didSet { updateHiddenItemDimming() }
    }

    /// Set by the row view: emphasized while the row is selected in a focused table.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateHiddenItemDimming() }
    }

    /// Hidden items' icon and name at half opacity, like Finder; the name of a selected row, or
    /// one being renamed, stays readable.
    private func updateHiddenItemDimming() {
        let isCut = alphaValue < 1
        let isSelected = backgroundStyle == .emphasized || isEditing
        let iconAlpha = CGFloat(currentItem?.iconOpacity(isCut: isCut) ?? 1)
        let nameAlpha = CGFloat(currentItem?.nameOpacity(isCut: isCut, isSelected: isSelected) ?? 1)
        if iconView.alphaValue != iconAlpha {
            iconView.alphaValue = iconAlpha
        }
        if nameTextField.alphaValue != nameAlpha {
            nameTextField.alphaValue = nameAlpha
        }
    }

    func setIcon(_ image: NSImage) {
        iconView.image = image
    }

    /// Shows up to three tag dots.
    func setTags(_ tags: [String], showTags: Bool) {
        tagDotsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if showTags {
            for tagName in tags.prefix(3) {
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

    override func prepareForReuse() {
        super.prepareForReuse()
        // A recycled cell must never stay in editing mode: it's about to show another item.
        guard isEditing else { return }
        let abandonedItem = currentItem
        if nameTextField.currentEditor() != nil {
            nameTextField.abortEditing()
        }
        resetEditingState()
        if let abandonedItem {
            // Async: reuse happens inside table updates, where the delegate must not publish changes.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.fileNameCellView(self, didAbortEditingOf: abandonedItem)
            }
        }
    }

    // MARK: - Names

    /// The name as listed: Finder shows ":" on disk as "/".
    static func displayText(for item: FileItem, showFileExtensions: Bool) -> String {
        item.displayName(showFileExtensions: showFileExtensions).replacingOccurrences(of: ":", with: "/")
    }

    /// The part of the rename field's text to select when editing starts: the base name when the
    /// field shows a file's (or package's) extension, as Finder does, else everything. UTF-16 range.
    static func initialSelection(forEditingText text: String, of item: FileItem) -> NSRange {
        let all = NSRange(location: 0, length: (text as NSString).length)
        guard !item.isDirectory || item.isPackage else { return all }
        let ext = item.url.pathExtension
        guard !ext.isEmpty, text.count > ext.count + 1,
              text.lowercased().hasSuffix("." + ext.lowercased()) else { return all }
        return NSRange(location: 0, length: all.length - (ext as NSString).length - 1)
    }

    /// The field text, or nil when it's blank or unchanged (nothing to rename). Not trimmed:
    /// leading and trailing spaces are part of the name, as in Finder.
    private func editedTextIfChanged(for item: FileItem) -> String? {
        let text = nameTextField.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text != item.editingName else { return nil }
        return text
    }

    // MARK: - Inline Editing

    func startEditing() {
        guard let item = currentItem, !isEditing else { return }

        isEditing = true
        editingStartedAt = Date()
        updateHiddenItemDimming()

        // Set up for editing (the same naming rule as every other rename field)
        let text = item.editingName
        nameTextField.stringValue = text
        nameTextField.isEditable = true
        nameTextField.isSelectable = true
        nameTextField.isBordered = true
        nameTextField.drawsBackground = true
        nameTextField.backgroundColor = .textBackgroundColor

        // Become first responder - use selectText which properly activates the field editor
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isEditing, self.currentItem?.url == item.url else { return }

            // First, end any existing editing in the window
            self.window?.endEditing(for: nil)

            // Now start editing our field, with the base name selected
            self.nameTextField.selectText(nil)
            if let editor = self.nameTextField.currentEditor(), editor.string == text {
                editor.selectedRange = Self.initialSelection(forEditingText: text, of: item)
            }
        }
    }

    func cancelEditing() {
        guard isEditing else { return }

        endEditingMode(refocusTable: true)

        // Restore original name
        if let item = currentItem {
            nameTextField.stringValue = displayedName(for: item)
        }

        delegate?.fileNameCellViewDidCancelRename(self)
    }

    /// Commits the rename because the user clicked elsewhere in the table (Finder). Focus is left
    /// to the click.
    func commitEditingFromOutsideClick() {
        commitEditing(refocusTable: false)
    }

    /// Ends an edit whose field editor has gone away, without moving focus.
    func abandonEditing() {
        guard isEditing else { return }
        endEditingMode(refocusTable: false)
        if let item = currentItem {
            nameTextField.stringValue = displayedName(for: item)
        }
        delegate?.fileNameCellViewDidCancelRename(self)
    }

    private func displayedName(for item: FileItem) -> String {
        Self.displayText(for: item, showFileExtensions: AppSettings.shared.showFileExtensions)
    }

    private func resetEditingState() {
        isEditing = false
        nameTextField.isEditable = false
        nameTextField.isSelectable = false
        nameTextField.isBordered = false
        nameTextField.drawsBackground = false
        updateHiddenItemDimming()
    }

    /// - Parameter refocusTable: true when editing ended from the keyboard (Return, Tab, Escape);
    ///   false when focus moved elsewhere (e.g. the user clicked the search field), so it isn't stolen back.
    private func endEditingMode(refocusTable: Bool) {
        // Still attached (Escape/Tab): detach only our field editor, never another control's.
        // Callers have already read the edited value.
        if nameTextField.currentEditor() != nil {
            nameTextField.abortEditing()
        }
        resetEditingState()

        // Make table view first responder so keyboard navigation works
        if refocusTable, let tableView = enclosingTableView() {
            DispatchQueue.main.async {
                tableView.window?.makeFirstResponder(tableView)
            }
        }
    }

    private func enclosingTableView() -> NSTableView? {
        var view: NSView? = superview
        while let current = view {
            if let tableView = current as? NSTableView {
                return tableView
            }
            view = current.superview
        }
        return nil
    }

    private func commitEditing(refocusTable: Bool) {
        guard isEditing, let item = currentItem else { return }

        let editedText = editedTextIfChanged(for: item)

        endEditingMode(refocusTable: refocusTable)

        // Only rename if the name actually changes (`FileItem.newName(forEditedText:)` is the rule
        // every rename field uses)
        if let editedText, let newName = item.newName(forEditedText: editedText) {
            delegate?.fileNameCellView(self, didRenameItem: item, to: newName)
        } else {
            // Restore original name
            nameTextField.stringValue = displayedName(for: item)
            delegate?.fileNameCellViewDidCancelRename(self)
        }
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidEndEditing(_ obj: Notification) {
        // Only handle notifications from our text field
        guard obj.object as AnyObject === nameTextField else { return }
        guard isEditing else { return }

        // Return/Tab keep keyboard focus in the list. Any other end (the user clicked another
        // control, e.g. the search field) means focus moved elsewhere and must stay there.
        let movement = (obj.userInfo?["NSTextMovement"] as? Int).flatMap(NSTextMovement.init(rawValue:)) ?? .other
        let endedFromKeyboard = movement == .return || movement == .tab || movement == .backtab || movement == .cancel
        commitEditing(refocusTable: endedFromKeyboard)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape key pressed
            cancelEditing()
            return true
        } else if commandSelector == #selector(NSResponder.insertTab(_:)) {
            // Tab key pressed - commit and move to next item
            commitRenameAndMoveNext()
            return true
        } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            // Shift+Tab pressed - commit and move to previous item
            commitRenameAndMovePrevious()
            return true
        }
        return false
    }

    /// The text to hand to the view model's rename-and-advance ("" = don't rename): the text as typed.
    /// The view model applies the same naming rule as Return (`FileItem.newName(forEditedText:)`), so
    /// a typed extension, or a change to its case ("Foo.TXT"), is kept.
    private func renameAndAdvanceText(for item: FileItem) -> String {
        editedTextIfChanged(for: item) ?? ""
    }

    private func commitRenameAndMoveNext() {
        guard isEditing, let item = currentItem else { return }

        let newName = renameAndAdvanceText(for: item)
        endEditingMode(refocusTable: true)
        delegate?.fileNameCellView(self, commitRenameAndMoveNext: item, newName: newName)
    }

    private func commitRenameAndMovePrevious() {
        guard isEditing, let item = currentItem else { return }

        let newName = renameAndAdvanceText(for: item)
        endEditingMode(refocusTable: true)
        delegate?.fileNameCellView(self, commitRenameAndMovePrevious: item, newName: newName)
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

    /// - Parameter tags: The item's tags, or nil while they're still loading (shown empty).
    func configure(tags: [String]?, appSettings: AppSettings) {
        // Clear existing tags
        tagsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        guard appSettings.showItemTags, let tags else {
            tagsStack.isHidden = true
            return
        }

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

// MARK: - Cloud Status Badge View (AppKit)

/// AppKit cloud status badge for table view cells
final class CloudStatusBadgeNSView: NSView {
    private let imageView = NSImageView()

    var status: CloudSyncStatus? {
        didSet { updateDisplay() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        translatesAutoresizingMaskIntoConstraints = false

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 14),
            imageView.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    private func updateDisplay() {
        guard let status = status, status.shouldShowBadge else {
            imageView.image = nil
            isHidden = true
            return
        }

        isHidden = false
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        imageView.image = NSImage(systemSymbolName: status.systemImage, accessibilityDescription: status.description)?
            .withSymbolConfiguration(config)
        imageView.contentTintColor = status.color
        toolTip = status.description
    }
}

// MARK: - Cloud Status Cell View (for dedicated column)

/// Table cell view that displays only the cloud status badge
final class CloudStatusCellView: NSTableCellView {
    private let badgeView = CloudStatusBadgeNSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupViews()
    }

    private func setupViews() {
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(badgeView)

        NSLayoutConstraint.activate([
            badgeView.centerXAnchor.constraint(equalTo: centerXAnchor),
            badgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
            badgeView.widthAnchor.constraint(equalToConstant: 20),
            badgeView.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    func configure(item: FileItem) {
        badgeView.status = item.cloudStatus
    }
}
