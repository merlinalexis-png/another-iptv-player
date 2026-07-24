import SwiftUI
import GRDB

// MARK: - Shared refresh status row

/// Refresh-now button, last-updated timestamp, and error footer — shared by the
/// M3U and Xtream EPG settings sections.
struct EPGRefreshStatusView: View {
    let playlist: Playlist
    var canRefresh: Bool = true
    @ObservedObject private var epgStore = EPGStore.shared

    init(playlist: Playlist, canRefresh: Bool = true) {
        self.playlist = playlist
        self.canRefresh = canRefresh
    }

    private var state: EPGRefreshState { epgStore.refreshState[playlist.id] ?? .idle }

    var body: some View {
        Button {
            Task { await epgStore.forceRefresh(playlist: playlist) }
        } label: {
            HStack {
                Label(L("epg.refresh"), systemImage: "arrow.clockwise")
                Spacer()
                if state.isRefreshing { ProgressView() }
            }
        }
        .disabled(!canRefresh || state.isRefreshing)

        if let last = epgStore.lastSuccess[playlist.id] {
            HStack {
                Text(L("epg.last_updated"))
                Spacer()
                Text(last, style: .relative).foregroundColor(.secondary)
            }
        } else {
            HStack {
                Text(L("epg.last_updated"))
                Spacer()
                Text(L("epg.never_updated")).foregroundColor(.secondary)
            }
        }

        if case .failed(let message) = state {
            Text(message)
                .font(.footnote)
                .foregroundColor(.red)
        }
    }
}

// MARK: - M3U section (editable XMLTV URL)

struct M3UEPGSettingsSection: View {
    let playlist: Playlist
    @State private var epgURLDraft: String
    @State private var saveError: String?

    init(playlist: Playlist) {
        self.playlist = playlist
        _epgURLDraft = State(initialValue: playlist.epgURLOverride ?? playlist.m3uEpgURL ?? "")
    }

    var body: some View {
        Section {
            TextField(L("epg.settings.url_placeholder"), text: $epgURLDraft, axis: .vertical)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .lineLimit(1...3)

            Button(L("epg.settings.save_url")) {
                Task { await saveURL() }
            }

            EPGRefreshStatusView(playlist: playlist, canRefresh: !effectiveURLEmpty)

            if let saveError {
                Text(saveError).font(.footnote).foregroundColor(.red)
            }
        } header: {
            Text(L("epg.settings.section_title"))
        } footer: {
            Text(L("epg.settings.url_footer"))
        }
    }

    private var effectiveURLEmpty: Bool {
        epgURLDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveURL() async {
        let trimmed = epgURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = playlist
        updated.epgURLOverride = trimmed.isEmpty ? nil : trimmed
        do {
            try await AppDatabase.shared.write { db in try updated.save(db) }
            saveError = nil
            if !trimmed.isEmpty {
                await EPGStore.shared.forceRefresh(playlist: updated)
            }
        } catch {
            saveError = L("misc.save_setting_error", error.localizedDescription)
        }
    }
}

// MARK: - Xtream section (enable toggle + refresh)

struct XtreamEPGSettingsSection: View {
    let playlist: Playlist
    @State private var epgEnabled: Bool
    @State private var matchedChannels: Int?

    init(playlist: Playlist) {
        self.playlist = playlist
        _epgEnabled = State(initialValue: playlist.epgEnabled)
    }

    var body: some View {
        Section {
            Toggle(L("epg.settings.enable"), isOn: $epgEnabled)
                .onChange(of: epgEnabled) { _, newValue in
                    Task { await saveEnabled(newValue) }
                }

            if epgEnabled {
                EPGRefreshStatusView(playlist: playlist)
                if let matched = matchedChannels {
                    HStack {
                        Text(L("epg.settings.matched_channels"))
                        Spacer()
                        Text(L("epg.settings.matched_channels_format", matched)).foregroundColor(.secondary)
                    }
                }
            }
        } header: {
            Text(L("epg.settings.section_title"))
        }
        .task {
            matchedChannels = try? await AppDatabase.shared.read { db in
                try DBEPGSource.fetchOne(db, key: playlist.id)?.channelCount
            } ?? nil
        }
    }

    private func saveEnabled(_ enabled: Bool) async {
        var updated = playlist
        updated.epgEnabled = enabled
        try? await AppDatabase.shared.write { db in try updated.save(db) }
        if enabled {
            await EPGStore.shared.refreshIfStale(playlist: updated)
        }
    }
}
