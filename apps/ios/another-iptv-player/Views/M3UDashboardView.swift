import SwiftUI

/// M3U türündeki playlist için TabView. Canlı/Film/Dizi ayrımı yok — tek "Kanallar" listesi.
struct M3UDashboardView: View {
    let playlist: Playlist
    let onDismiss: () -> Void

    @ObservedObject private var store = M3UContentStore.shared
    @ObservedObject private var favorites = M3UFavoriteStore.shared
    @ObservedObject private var epgStore = EPGStore.shared
    @StateObject private var playerOverlay = PlayerOverlayController()

    /// Son seçilen tab kaydedilmez — dashboard her açılışta "Kanallar"dan başlar.
    @State private var selectedTab: Int = 0
    // Keep poster sizing tied to the display, not to this view's transient layout.
    // Keyboard/status-bar/player transitions can temporarily shrink GeometryReader.
    private let posterMetrics = PosterMetrics(windowSize: UIScreen.main.bounds.size)

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                Tab(L("dashboard.channels"), systemImage: "tv", value: 0) {
                    NavigationStack {
                        M3UChannelsView(playlist: playlist)
                            .navigationTitle(L("dashboard.channels"))
                            .navigationBarTitleDisplayMode(.large)
                            .toolbar(.visible, for: .navigationBar)
                            .toolbarBackground(.visible, for: .navigationBar)
                    }
                }

                Tab(L("dashboard.settings"), systemImage: "gear", value: 1) {
                    NavigationStack {
                        M3UPlaylistSettingsView(playlist: playlist, onDismiss: onDismiss)
                            .navigationTitle(L("dashboard.settings"))
                            .navigationBarTitleDisplayMode(.large)
                    }
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .environment(\.posterMetrics, posterMetrics)

            ZStack {
                if let item = playerOverlay.presentation {
                    item.root
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .environment(\.playerOverlayDismiss) {
                            playerOverlay.dismiss(animated: true)
                        }
                        .environment(\.playerOverlayMode, playerOverlay.mode)
                        .environment(\.playerOverlayPresentationID, item.id)
                        .environment(\.playerOverlayMinimize) { playerOverlay.minimize() }
                        .environment(\.playerOverlayExpand) { playerOverlay.expand() }
                        // Keep UIKit-backed video surfaces at a fixed geometry while they attach.
                        // Moving the whole AVPlayer/KSPlayer subtree produced a launch flash.
                        .transition(.opacity)
                }
            }
            // Animate only insertion/removal, never in-place source revisions.
            .animation(.easeOut(duration: 0.14), value: playerOverlay.presentation != nil)
            .zIndex(10_000)
        }
        .environmentObject(playerOverlay)
        .environment(\.epgSnapshot, epgStore.snapshot)
        .task(id: playlist.id) {
            favorites.track(playlistId: playlist.id)
            await store.loadPlaylist(playlist)
            epgStore.setActivePlaylist(playlist)
            await epgStore.refreshIfStale(playlist: playlist)
        }
        .alert(L("loading.error.title"), isPresented: Binding(
            get: {
                store.loadError != nil
                    && store.activePlaylistId == playlist.id
                    && !store.isLoading
            },
            set: { if !$0 { store.loadError = nil } }
        )) {
            Button(L("common.ok")) {
                store.loadError = nil
            }
            Button(L("common.try_again")) {
                store.loadError = nil
                Task { await store.loadPlaylist(playlist) }
            }
        } message: {
            Text(store.loadError ?? "")
        }
    }
}
