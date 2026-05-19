//
//  ContentView.swift
//  Sangeet3
//
//  Created by Yashvardhan on 29/12/24.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var playbackManager: PlaybackManager
    @EnvironmentObject var libraryManager: LibraryManager
    @ObservedObject var themeManager = ThemeManager.shared // Observe for instant color updates
    @State private var showFullScreenPlayer = false
    @State private var showQueueSidebar = false
    @State private var showGlobalSearch = false
    @State private var showingCreatePlaylistAlert = false
    @State private var newPlaylistName = ""
    @State private var trackToAddAfterCreation: Track?
    @State private var importSummaries: [PlaylistImportSummary] = []
    @State private var showImportResultAlert = false
    
    var body: some View {
        ZStack {
            // Use themeManager directly for instant updates
            themeManager.background.ignoresSafeArea()
            
            // Main Content Area
            VStack(spacing: 0) {
                TopTabBar(selectedTab: $appState.currentTab, showSearch: $showGlobalSearch)
                
                Group {
                    switch appState.currentTab {
                    case .home: HomeView()
                    case .library: LibraryView()
                    case .playlists: PlaylistsView()
                    case .online: OnlineView()
                    case .settings: SettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Scan progress banner removed - User requested silence.

            }
            .overlay(alignment: .bottom) {
                FloatingDock(showFullScreen: $showFullScreenPlayer, showQueue: $showQueueSidebar)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
            }
            // Add a padding to the bottom of the content to allow scrolling behind the dock is handled in individual views
            
            // Queue Sidebar Overlay with click-outside-to-close
            // Placed in ZStack to float over content instead of shifting it
            if showQueueSidebar {
                // Dimmed background to click to close
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showQueueSidebar = false
                        }
                    }
                    .zIndex(45)
                
                HStack {
                    Spacer()
                    QueueSidebar(isVisible: $showQueueSidebar)
                        .transition(.move(edge: .trailing))
                }
                .zIndex(50)
            }
            
            // Full Screen Player
            if showFullScreenPlayer {
                FullScreenPlayerView(isPresented: $showFullScreenPlayer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(100)
            }
            

            
            // Global Search Overlay
            if showGlobalSearch {
                GlobalSearchOverlay(isVisible: $showGlobalSearch)
                    .transition(.opacity)
                    .zIndex(200)
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: showQueueSidebar)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showFullScreenPlayer)
        .animation(.easeOut(duration: 0.2), value: showGlobalSearch)
        .enableSwipeToBack {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                appState.navigateBack()
            }
        }
        // Playlist Creation Handler
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("createPlaylistRequested"))) { notification in
            if let track = notification.object as? Track {
                self.trackToAddAfterCreation = track
            } else {
                self.trackToAddAfterCreation = nil
            }
            self.showingCreatePlaylistAlert = true
        }
        .alert("Create New Playlist", isPresented: $showingCreatePlaylistAlert) {
            TextField("Playlist Name", text: $newPlaylistName)
            Button("Cancel", role: .cancel) {
                newPlaylistName = ""
                trackToAddAfterCreation = nil
            }
            Button("Create") {
                if !newPlaylistName.isEmpty {
                    libraryManager.createPlaylist(name: newPlaylistName)
                    
                    // If we wanted to add a track, do it now (need ID of newly created playlist?
                    // LibraryManager.createPlaylist is async and doesn't return ID easily here.
                    // But we can assume it's the latest or find it by name.
                    // For now, let's just wait a split second or notify User.
                    if let track = trackToAddAfterCreation {
                         // We need to wait for playlist to be created.
                         // Improve LibraryManager to return the created playlist or handle this.
                         // For now, simple implementation:
                         Task {
                             try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
                             if let playlist = self.libraryManager.playlists.first(where: { $0.name == self.newPlaylistName }) {
                                 self.libraryManager.addTrackToPlaylist(track, playlist: playlist)
                             }
                             await MainActor.run {
                                 self.newPlaylistName = ""
                                 self.trackToAddAfterCreation = nil
                             }
                         }
                    } else {
                        newPlaylistName = ""
                    }
                }
            }
        }
        // Playlist Import Result Handler (covers both the Playlists button
        // and the File ▸ Import Playlist… menu command)
        .onReceive(NotificationCenter.default.publisher(for: .playlistImported)) { note in
            if let summaries = note.object as? [PlaylistImportSummary], !summaries.isEmpty {
                self.importSummaries = summaries
                self.showImportResultAlert = true
            }
        }
        .alert("Playlist Import", isPresented: $showImportResultAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(importResultMessage(for: importSummaries))
        }
        .onAppear {
            setupArrowKeyMonitor()
        }
    }

    private func importResultMessage(for summaries: [PlaylistImportSummary]) -> String {
        if summaries.count == 1, let s = summaries.first {
            return singleSummaryMessage(s)
        }
        let created   = summaries.filter { $0.outcome == .created   && !$0.parseFailed }.count
        let updated   = summaries.filter { $0.outcome == .updated   && !$0.parseFailed }.count
        let unchanged = summaries.filter { $0.outcome == .unchanged && !$0.parseFailed }.count
        let failed    = summaries.filter { $0.parseFailed }.count

        var head: [String] = []
        if created   > 0 { head.append("\(created) created") }
        if updated   > 0 { head.append("\(updated) updated") }
        if unchanged > 0 { head.append("\(unchanged) unchanged") }
        if failed    > 0 { head.append("\(failed) failed") }

        var lines: [String] = [head.joined(separator: ", ")]
        for s in summaries {
            if s.parseFailed {
                lines.append("• \"\(s.playlistName)\": could not be read")
                continue
            }
            switch s.outcome {
            case .created:
                lines.append("• \"\(s.playlistName)\": created, \(s.addedCount)/\(s.totalEntries) tracks\(s.missing > 0 ? ", \(s.missing) missing" : "")")
            case .updated:
                lines.append("• \"\(s.playlistName)\": updated (+\(s.tracksAdded) / -\(s.tracksRemoved))\(s.missing > 0 ? ", \(s.missing) missing" : "")")
            case .unchanged:
                lines.append("• \"\(s.playlistName)\": unchanged")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func singleSummaryMessage(_ s: PlaylistImportSummary) -> String {
        if s.parseFailed {
            return "Could not read any tracks from this file. Make sure it is a valid .m3u or .m3u8 playlist."
        }
        var lines: [String] = []
        switch s.outcome {
        case .created:
            lines.append("\"\(s.playlistName)\" created with \(s.addedCount) of \(s.totalEntries) tracks.")
        case .updated:
            lines.append("\"\(s.playlistName)\" synced (+\(s.tracksAdded) added, -\(s.tracksRemoved) removed).")
        case .unchanged:
            lines.append("\"\(s.playlistName)\" already up to date — no changes.")
        }
        if s.matched > 0 { lines.append("• \(s.matched) matched from your library") }
        if s.importedFromDisk > 0 { lines.append("• \(s.importedFromDisk) imported from disk") }
        if s.remote > 0 { lines.append("• \(s.remote) streaming") }
        if s.missing > 0 {
            lines.append("• \(s.missing) not found")
            let preview = s.missingNames.prefix(5).joined(separator: ", ")
            if !preview.isEmpty {
                lines.append("Missing: \(preview)\(s.missing > 5 ? "…" : "")")
            }
        }
        return lines.joined(separator: "\n")
    }
    
    // MARK: - Smart Arrow Key Handling
    
    private func setupArrowKeyMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Check if a text field is focused
            if let firstResponder = NSApp.keyWindow?.firstResponder,
               firstResponder is NSTextView || firstResponder is NSTextField {
                // Let text field handle the event normally
                return event
            }
            
            // No modifier keys (except for allowing with no modifiers)
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                return event
            }
            
            switch event.keyCode {
            case 123: // Left Arrow
                playbackManager.seek(to: playbackManager.currentTime - 5)
                return nil // Event consumed
            case 124: // Right Arrow
                playbackManager.seek(to: playbackManager.currentTime + 5)
                return nil // Event consumed
            default:
                return event
            }
        }
    }
}
