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
        Button(action: onTap) {
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
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture().onEnded { _ in onLongPress() })
    }
}
