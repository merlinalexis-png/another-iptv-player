import SwiftUI

/// Full-page timeline TV guide: channels × time. All programme rows live inside
/// one horizontal ScrollView, so they can never drift to different time offsets.
/// The channel column is drawn above that scroller and remains pinned.
struct EPGGuideView: View {
    @StateObject private var model: EPGGuideViewModel
    @EnvironmentObject private var playerOverlay: PlayerOverlayController
    @ObservedObject private var epgStore = EPGStore.shared

    /// The only horizontal scrollers are the time axis and the complete programme
    /// body. The active one drives the other while preserving native momentum.
    @State private var positions: [String: ScrollPosition] = [:]
    @State private var reportedOffsets: [String: CGFloat] = [:]
    @State private var bodyOffsetX: CGFloat = 0
    @State private var lastSyncX: CGFloat = -1
    /// Which scroller the user is actively driving. Only that one may push the other,
    /// so a follower's geometry updates can never feed back and start a ping-pong loop
    /// that pins the main thread (the guide's hang).
    @State private var activeScroller: String?
    /// Initial/programmatic positioning causes stale zero-offset geometry events.
    /// Ignore those briefly so they cannot undo the jump to the selected time.
    @State private var programmaticTargetX: CGFloat?
    @State private var targetReleaseTask: Task<Void, Never>?
    @State private var selected: SelectedProgramme?
    @State private var selectionTask: Task<Void, Never>?
    @State private var detailChannel: EPGGuideRow?

    private static let axisID = "axis"
    private static let bodyID = "body"

    private let metrics = EPGGuideMetrics(compact: true)

    init(source: EPGGuideViewModel.Source) {
        _model = StateObject(wrappedValue: EPGGuideViewModel(source: source))
    }

    struct SelectedProgramme: Identifiable {
        let id: String
        let programme: EPGProgramme
        let row: EPGGuideRow
    }

    var body: some View {
        content
            .navigationTitle(L("epg.guide.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .tabBar)
            .toolbar { toolbarContent }
            .searchable(text: $model.searchQuery)
            .task { await model.load() }
            .onDisappear {
                selectionTask?.cancel()
                targetReleaseTask?.cancel()
                model.cancelLoading()
            }
            .navigationDestination(item: $detailChannel) { row in
                ChannelEPGDetailView(playlist: model.playlist, channelKey: row.channelKey,
                                     displayName: row.displayName, iconURL: row.iconURL, liveStream: row.liveStream)
            }
            .sheet(item: $selected) { sel in
                EPGProgrammeDetailSheet(playlist: model.playlist, programme: sel.programme,
                                        channelName: sel.row.displayName, channelIcon: sel.row.iconURL,
                                        liveStream: sel.row.liveStream)
                    .presentationDetents([.medium, .large])
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notConfigured:
            ContentUnavailableView {
                Label(L("epg.not_configured.title"), systemImage: "calendar.badge.exclamationmark")
            } description: {
                Text(model.playlist.kind == .m3u ? L("epg.not_configured.m3u_message") : L("epg.not_configured.xtream_message"))
            }
        case .empty:
            ContentUnavailableView {
                Label(L("epg.empty.title"), systemImage: "calendar")
            } description: {
                Text(L("epg.empty.message"))
            } actions: {
                Button(L("epg.refresh")) { Task { await epgStore.forceRefresh(playlist: model.playlist); await model.load() } }
            }
        case .ready:
            VStack(spacing: 0) {
                dayPicker
                grid
            }
        }
    }

    // MARK: - Day picker

    private var dayPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.availableDays, id: \.self) { day in
                    let isSelected = Calendar.current.isDate(day, inSameDayAs: model.selectedDay)
                    Button {
                        Task { await model.selectDay(day) }
                    } label: {
                        Text(dayChipLabel(day))
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(isSelected ? Color.accentColor : Color(.secondarySystemFill), in: Capsule())
                            .foregroundColor(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    // MARK: - Grid

    private var grid: some View {
        VStack(spacing: 0) {
            // Header: fixed corner + time axis. The axis shares `timePosition`, so it
            // tracks the rows' horizontal scroll.
            HStack(spacing: 0) {
                Color(.secondarySystemBackground)
                    .frame(width: metrics.channelColumnWidth, height: metrics.axisHeight)
                ScrollView(.horizontal) {
                    EPGTimeAxisView(dayStart: model.dayStart, metrics: metrics)
                        .frame(width: metrics.dayWidth, height: metrics.axisHeight)
                        .overlay(alignment: .topLeading) {
                            if let nowX = nowLineX {
                                Rectangle().fill(Color.red).frame(width: 1.5, height: metrics.axisHeight)
                                    .offset(x: nowX)
                            }
                        }
                }
                .scrollPosition(hBinding(Self.axisID))
                .scrollIndicators(.hidden)
                .onScrollPhaseChange { _, phase in
                    updateActiveScroller(Self.axisID, phase: phase)
                }
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, x in
                    propagate(from: Self.axisID, x: x)
                }
            }
            .frame(height: metrics.axisHeight)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }

            // A single two-axis ScrollView keeps every row on the same time offset.
            // LazyVStack is now a direct child of the vertical scroller, preserving
            // virtualization for playlists with thousands of channels.
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 1) {
                    ForEach(model.filteredRows) { row in
                        HStack(spacing: 0) {
                            EPGChannelColumnCell(row: row, metrics: metrics,
                                                 onTap: { playChannel(row) },
                                                 onLongPress: { detailChannel = row })
                                .frame(width: metrics.channelColumnWidth, height: metrics.rowHeight)
                                .offset(x: bodyOffsetX)
                                .zIndex(1)

                            ZStack(alignment: .topLeading) {
                                EPGChannelRowView(channelKey: row.channelKey,
                                                  layout: model.layout(for: row.channelKey),
                                                  metrics: metrics) { programme in
                                    showProgramme(programme, in: row)
                                }
                                .equatable()

                                if let nowX = nowLineX {
                                    Rectangle().fill(Color.red.opacity(0.85))
                                        .frame(width: 1.5, height: metrics.rowHeight)
                                        .offset(x: nowX)
                                        .allowsHitTesting(false)
                                }
                            }
                            .frame(width: metrics.dayWidth, height: metrics.rowHeight, alignment: .topLeading)
                        }
                        .frame(
                            width: metrics.channelColumnWidth + metrics.dayWidth,
                            height: metrics.rowHeight,
                            alignment: .leading
                        )
                    }
                }
            }
            .scrollPosition(hBinding(Self.bodyID))
            .scrollIndicators(.hidden)
            .onScrollPhaseChange { _, phase in
                updateActiveScroller(Self.bodyID, phase: phase)
            }
            .onScrollGeometryChange(for: CGFloat.self, of: { max(0, $0.contentOffset.x) }) { _, x in
                if bodyOffsetX != x { bodyOffsetX = x }
                propagate(from: Self.bodyID, x: x)
            }
        }
        // `grid` only exists after the async model load reaches `.ready`. Position
        // after its first layout pass, then verify once and retry if either binding
        // was not ready when the first command arrived.
        .task(id: model.selectedDay) {
            await focusSelectedTimeAfterLayout()
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                scrollToNow(forceToday: true)
            } label: { Image(systemName: "clock.arrow.circlepath") }
            .accessibilityLabel(L("epg.jump_to_now"))
        }
        ToolbarItem(placement: .topBarTrailing) {
            let refreshing = epgStore.refreshState[model.playlist.id]?.isRefreshing ?? false
            Button {
                Task { await epgStore.forceRefresh(playlist: model.playlist); await model.load() }
            } label: {
                if refreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
            }
            .disabled(refreshing)
        }
    }

    // MARK: - Helpers

    private var isToday: Bool { Calendar.current.isDateInToday(model.selectedDay) }

    private var nowLineX: CGFloat? {
        guard isToday else { return nil }
        return metrics.x(for: Date(), dayStart: model.dayStart)
    }

    private func hBinding(_ id: String) -> Binding<ScrollPosition> {
        Binding(
            get: { positions[id] ?? ScrollPosition(edge: .leading) },
            set: { positions[id] = $0 }
        )
    }

    /// Latches which scroller the user is physically driving. Only user-initiated
    /// phases claim the latch — the `.animating` phase emitted when we sync the
    /// follower programmatically must be ignored, otherwise the follower would seize
    /// the latch and block the real driver, leaving it behind (the now-line drift).
    private func updateActiveScroller(_ id: String, phase: ScrollPhase) {
        switch phase {
        case .tracking, .interacting, .decelerating:
            activeScroller = id
        case .idle:
            if activeScroller == id { activeScroller = nil }
        case .animating:
            break   // programmatic follower sync — never claims the latch
        @unknown default:
            break
        }
    }

    /// Pushes the active scroller's offset to the one follower. Programme rows are
    /// part of a single body scroller, so row-specific horizontal state is impossible.
    private func propagate(from sourceID: String, x: CGFloat) {
        reportedOffsets[sourceID] = x
        guard programmaticTargetX == nil else { return }
        // Only the scroller the user is actively driving may move the other. This
        // makes the sync one-directional at any instant, so the follower's resulting
        // geometry events can never bounce back and spin the main thread.
        guard activeScroller == nil || activeScroller == sourceID else { return }
        guard abs(x - lastSyncX) > 0.5 else { return }
        lastSyncX = x
        let followerID = sourceID == Self.axisID ? Self.bodyID : Self.axisID
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            var position = positions[followerID] ?? ScrollPosition(edge: .leading)
            position.scrollTo(x: x)
            positions[followerID] = position
        }
    }

    private func scrollToNow(forceToday: Bool = false) {
        if forceToday, !isToday {
            // Switching the day re-runs the grid task keyed by selectedDay.
            Task { await model.selectDay(Date()) }
            return
        }
        applyProgrammaticOffset(defaultTimeOffset)
    }

    private var defaultTimeOffset: CGFloat {
        if isToday {
            return max(0, metrics.x(for: Date(), dayStart: model.dayStart) - metrics.hourWidth / 2)
        }
        return 8 * metrics.hourWidth // 08:00
    }

    private func focusSelectedTimeAfterLayout() async {
        try? await Task.sleep(for: .milliseconds(50))
        guard !Task.isCancelled else { return }
        let targetX = defaultTimeOffset
        applyProgrammaticOffset(targetX)

        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        let axisReachedTarget = abs((reportedOffsets[Self.axisID] ?? -1) - targetX) < 1
        let bodyReachedTarget = abs((reportedOffsets[Self.bodyID] ?? -1) - targetX) < 1
        if !axisReachedTarget || !bodyReachedTarget {
            applyProgrammaticOffset(targetX)
        }
    }

    private func applyProgrammaticOffset(_ targetX: CGFloat) {
        targetReleaseTask?.cancel()
        programmaticTargetX = targetX
        lastSyncX = targetX
        bodyOffsetX = targetX

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            for id in [Self.axisID, Self.bodyID] {
                var position = positions[id] ?? ScrollPosition(edge: .leading)
                position.scrollTo(x: targetX)
                positions[id] = position
            }
        }

        // Scroll geometry may report the pre-jump zero offset for a few frames.
        // Release normal user-driven synchronization after both views have settled.
        targetReleaseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            programmaticTargetX = nil
        }
    }

    private func playChannel(_ row: EPGGuideRow) {
        guard let stream = row.liveStream else {
            detailChannel = row  // M3U: no single-view live shell here → open schedule
            return
        }
        // Hand the player the whole live catalog so prev/next channel and the channel
        // side panel work, not just the single tapped channel.
        let live = LiveChannelCategorySection.xtreamLiveQueue()
        playerOverlay.present(playlistId: model.playlist.id) {
            LivePlayerShell(playlist: model.playlist, queue: live.queue, sections: live.sections,
                            initialStream: stream, initialHistory: nil, subtitle: row.displayName)
        }
    }

    private func showProgramme(_ programme: EPGProgramme, in row: EPGGuideRow) {
        selectionTask?.cancel()
        selectionTask = Task {
            let detailed = try? await epgStore.programmeDetails(
                playlistId: model.playlist.id,
                channelKey: programme.channelKey,
                start: programme.start
            )
            guard !Task.isCancelled else { return }
            let value = detailed ?? programme
            selected = SelectedProgramme(id: value.id, programme: value, row: row)
        }
    }

    private func dayChipLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return L("epg.day.today") }
        if cal.isDateInTomorrow(day) { return L("epg.day.tomorrow") }
        if cal.isDateInYesterday(day) { return L("epg.day.yesterday") }
        return day.formatted(.dateTime.weekday(.abbreviated).day())
    }
}
