import SwiftUI
import DoodleCore

struct NotchContentView: View {
    var boardManager: BoardManager
    @State private var displayItems: [DoodleItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            Divider().opacity(0.3)

            if displayItems.isEmpty {
                emptyState
            } else {
                sections
            }

            Divider().opacity(0.3)

            footer
        }
        .padding(12)
        .frame(width: 360)
        .onAppear {
            refresh()
        }
        .onHover { boardManager.onExpandedHover?($0) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "list.bullet.clipboard")
                .foregroundStyle(.secondary)
            Text("agent-doodle")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if boardManager.waitingCount > 0 {
                Label("\(boardManager.waitingCount) waiting", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
        }
    }

    private var emptyState: some View {
        Text("No active items. Agents will post with `doodle set`.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private var sections: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(boardManager.groupedItems(displayItems)) { group in
                    SectionHeader(title: group.title)
                    ForEach(group.items) { item in
                        ItemCard(item: item)
                    }
                }
            }
        }
        .frame(maxHeight: 280)
    }

    private var footer: some View {
        HStack {
            Text("Board: \(shortBoardPath())")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Refresh") {
                refresh()
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        displayItems = boardManager.loadForDisplay()
        boardManager.reload() // keep counts fresh
    }

    private func shortBoardPath() -> String {
        let p = BoardPath.resolved
        if let home = FileManager.default.homeDirectoryForCurrentUser.path as String?,
           p.hasPrefix(home) {
            return "~" + p.dropFirst(home.count)
        }
        return p
    }
}

// MARK: - Subviews

private struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

private struct ItemCard: View {
    let item: DoodleItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.display_name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                Text(item.source)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Text(DoodleDate.relative(from: item.updated_at))
                    .font(.system(size: 10))
                    .foregroundStyle(DoodleDate.isStale(item.updated_at) ? .orange.opacity(0.7) : .secondary)
            }

            if !item.summary.isEmpty {
                Text(item.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }

            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .padding(.top, 1)
            }

            // subtle type / status pill
            HStack(spacing: 4) {
                Text(item.type)
                    .font(.system(size: 9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.gray.opacity(0.15)))
                Text(item.status)
                    .font(.system(size: 9))
                    .foregroundStyle(statusColor(item.status))
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundForItem(item))
        )
        .opacity(DoodleDate.isStale(item.updated_at) ? 0.55 : 1.0)
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "waiting_on_user": return .red
        case "blocked": return .orange
        case "active": return .blue
        default: return .secondary
        }
    }

    private func backgroundForItem(_ item: DoodleItem) -> Color {
        if item.status == "waiting_on_user" {
            return Color.red.opacity(0.06)
        }
        if DoodleDate.isStale(item.updated_at) {
            return Color.gray.opacity(0.06)
        }
        return Color.gray.opacity(0.04)
    }
}
