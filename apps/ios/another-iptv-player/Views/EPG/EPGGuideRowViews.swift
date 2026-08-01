import SwiftUI

/// One channel's programme strip. `Equatable` on (channelKey, layout version) so
/// cells never re-render during scroll — only the four synced overlays in the
/// parent move.
struct EPGChannelRowView: View, Equatable {
    let channelKey: String
    let layout: EPGRowLayout
    let metrics: EPGGuideMetrics
    let onTap: (EPGProgramme) -> Void

    static func == (lhs: EPGChannelRowView, rhs: EPGChannelRowView) -> Bool {
        lhs.channelKey == rhs.channelKey
            && lhs.layout.version == rhs.layout.version
            && lhs.metrics == rhs.metrics
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.cells) { cell in
                EPGProgrammeCell(cell: cell, height: metrics.rowHeight)
                    .frame(width: cell.width, height: metrics.rowHeight)
                    .offset(x: cell.x)
                    .onTapGesture {
                        if let programme = cell.programme { onTap(programme) }
                    }
            }
        }
        .frame(width: metrics.dayWidth, height: metrics.rowHeight, alignment: .topLeading)
    }
}

struct EPGProgrammeCell: View {
    let cell: EPGCellLayout
    let height: CGFloat

    var body: some View {
        Group {
            if let programme = cell.programme {
                VStack(alignment: .leading, spacing: 2) {
                    Text(programme.title)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    if cell.width >= 64 {
                        Text(EPGTimeFormat.time(programme.start))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(Color(.secondarySystemFill))
            } else {
                Text(L("epg.no_data.programme_cell"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(Color(.tertiarySystemFill).opacity(0.4))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.06), lineWidth: 0.5))
        .padding(.horizontal, 1)
    }
}

/// Hour ticks + labels across the selected day.
struct EPGTimeAxisView: View {
    let dayStart: Date
    let metrics: EPGGuideMetrics

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<24, id: \.self) { hour in
                let date = dayStart.addingTimeInterval(Double(hour) * 3600)
                Text(EPGTimeFormat.time(date))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: metrics.hourWidth, alignment: .leading)
                    .padding(.leading, 4)
                    .offset(x: CGFloat(hour) * metrics.hourWidth)
            }
        }
        .frame(width: metrics.dayWidth, height: metrics.axisHeight, alignment: .leading)
    }
}

/// Collapsible category header spanning the guide's visible width. Tapping toggles
/// the category's channels. `width` is the current viewport width so the header
/// stays pinned to the left edge while the body scrolls horizontally.
struct EPGCategoryHeader: View {
    let title: String
    let channelCount: Int
    let collapsed: Bool
    let width: CGFloat
    let height: CGFloat
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(channelCount)")
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: height, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .overlay(alignment: .bottom) { Divider() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(collapsed ? L("epg.categories.collapsed_a11y") : L("epg.categories.expanded_a11y"))
        .accessibilityAddTraits(.isHeader)
    }
}

/// Channel column cell (sticky leading, per row). `Equatable` (on row + metrics,
/// ignoring closures) so the sticky `.offset(x:)` can update during scroll without
/// rebuilding the cell — critical for large playlists.
struct EPGChannelColumnCell: View, Equatable {
    let row: EPGGuideRow
    let metrics: EPGGuideMetrics
    let onTap: () -> Void
    let onLongPress: () -> Void

    static func == (lhs: EPGChannelColumnCell, rhs: EPGChannelColumnCell) -> Bool {
        lhs.row == rhs.row && lhs.metrics == rhs.metrics
    }

    var body: some View {
        HStack(spacing: 8) {
            // `.grid` profile: the request survives cell recycling (the default
            // `.standard` cancels on disappear, which starves logos as rows and
            // sticky labels churn during scroll/virtualization).
            CachedImage(url: row.iconURL, width: 32, height: 32, cornerRadius: 6, iconName: "tv", loadProfile: .grid)
            Text(row.displayName)
                .font(.caption)
                .lineLimit(2)
                .foregroundColor(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: metrics.channelColumnWidth, height: metrics.rowHeight, alignment: .leading)
        .background(.regularMaterial)
        .contentShape(Rectangle())
        .gesture(
            LongPressGesture(minimumDuration: 0.5).exclusively(before: TapGesture())
                .onEnded { result in
                    switch result {
                    case .first:
                        onLongPress()
                    case .second:
                        onTap()
                    }
                }
        )
    }
}
