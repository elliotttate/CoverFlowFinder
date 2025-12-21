import SwiftUI

// MARK: - Drop Target Overlay Modifier
// Reusable overlay for drop target indication

struct DropTargetOverlay: ViewModifier {
    let isTargeted: Bool
    let cornerRadius: CGFloat
    let lineWidth: CGFloat
    let padding: CGFloat

    init(
        isTargeted: Bool,
        cornerRadius: CGFloat = UI.CornerRadius.large,
        lineWidth: CGFloat = UI.LineWidth.thick,
        padding: CGFloat = UI.Spacing.small
    ) {
        self.isTargeted = isTargeted
        self.cornerRadius = cornerRadius
        self.lineWidth = lineWidth
        self.padding = padding
    }

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(isTargeted ? Color.accentColor : Color.clear, lineWidth: lineWidth)
                .padding(padding)
        )
    }
}

extension View {
    func dropTargetOverlay(
        isTargeted: Bool,
        cornerRadius: CGFloat = UI.CornerRadius.large,
        lineWidth: CGFloat = UI.LineWidth.thick,
        padding: CGFloat = UI.Spacing.small
    ) -> some View {
        modifier(DropTargetOverlay(
            isTargeted: isTargeted,
            cornerRadius: cornerRadius,
            lineWidth: lineWidth,
            padding: padding
        ))
    }
}

// MARK: - Selection Background Modifier
// Reusable background for selected/drop-targeted items

struct SelectionBackground: ViewModifier {
    let isSelected: Bool
    let isDropTarget: Bool
    let cornerRadius: CGFloat

    init(
        isSelected: Bool,
        isDropTarget: Bool = false,
        cornerRadius: CGFloat = UI.CornerRadius.large
    ) {
        self.isSelected = isSelected
        self.isDropTarget = isDropTarget
        self.cornerRadius = cornerRadius
    }

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(backgroundColor)
        )
    }

    private var backgroundColor: Color {
        if isDropTarget {
            return Color.accentColor.opacity(UI.Opacity.dropTarget)
        } else if isSelected {
            return Color.accentColor.opacity(UI.Opacity.selectedItem)
        } else {
            return Color.clear
        }
    }
}

extension View {
    func selectionBackground(
        isSelected: Bool,
        isDropTarget: Bool = false,
        cornerRadius: CGFloat = UI.CornerRadius.large
    ) -> some View {
        modifier(SelectionBackground(
            isSelected: isSelected,
            isDropTarget: isDropTarget,
            cornerRadius: cornerRadius
        ))
    }
}

// MARK: - Item Drop Target Overlay
// Combined selection background and drop stroke for list/grid items

struct ItemDropTargetStyle: ViewModifier {
    let isSelected: Bool
    let isDropTarget: Bool
    let cornerRadius: CGFloat
    let strokeWidth: CGFloat

    init(
        isSelected: Bool,
        isDropTarget: Bool,
        cornerRadius: CGFloat = UI.CornerRadius.large,
        strokeWidth: CGFloat = UI.LineWidth.standard
    ) {
        self.isSelected = isSelected
        self.isDropTarget = isDropTarget
        self.cornerRadius = cornerRadius
        self.strokeWidth = strokeWidth
    }

    func body(content: Content) -> some View {
        content
            .background(
                isDropTarget
                    ? Color.accentColor.opacity(UI.Opacity.dropTarget)
                    : (isSelected ? Color.accentColor.opacity(UI.Opacity.selectedItemStrong) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(Color.accentColor, lineWidth: strokeWidth)
                    .opacity(isDropTarget ? 1 : 0)
            )
    }
}

extension View {
    func itemDropTargetStyle(
        isSelected: Bool,
        isDropTarget: Bool,
        cornerRadius: CGFloat = UI.CornerRadius.large,
        strokeWidth: CGFloat = UI.LineWidth.standard
    ) -> some View {
        modifier(ItemDropTargetStyle(
            isSelected: isSelected,
            isDropTarget: isDropTarget,
            cornerRadius: cornerRadius,
            strokeWidth: strokeWidth
        ))
    }
}

// MARK: - Active Pane Border
// Highlights the active pane in multi-pane views

struct ActivePaneBorder: ViewModifier {
    let isActive: Bool
    let lineWidth: CGFloat

    init(isActive: Bool, lineWidth: CGFloat = UI.LineWidth.standard) {
        self.isActive = isActive
        self.lineWidth = lineWidth
    }

    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: lineWidth)
        )
    }
}

extension View {
    func activePaneBorder(isActive: Bool, lineWidth: CGFloat = UI.LineWidth.standard) -> some View {
        modifier(ActivePaneBorder(isActive: isActive, lineWidth: lineWidth))
    }
}

// MARK: - Cut Item Opacity
// Applies reduced opacity to items that are cut

extension View {
    func cutItemOpacity(isCut: Bool) -> some View {
        opacity(isCut ? UI.Opacity.cutItem : 1.0)
    }
}
