import SwiftUI

struct IconGridView: View {
    @ObservedObject var viewModel: FileBrowserViewModel
    let items: [FileItem]

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 120), spacing: 20)
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 24) {
                ForEach(items) { item in
                    IconGridItem(
                        item: item,
                        isSelected: viewModel.selectedItems.contains(item)
                    )
                    .onTapGesture(count: 2) {
                        viewModel.openItem(item)
                    }
                    .onTapGesture(count: 1) {
                        viewModel.selectItem(item, extend: NSEvent.modifierFlags.contains(.command))
                    }
                }
            }
            .padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct IconGridItem: View {
    let item: FileItem
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.2))
                        .frame(width: 90, height: 90)
                }

                Image(nsImage: item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)
            }

            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 100)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
                .foregroundColor(isSelected ? .white : .primary)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering && !isSelected ? Color.secondary.opacity(0.1) : Color.clear)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }
}
