//
//  LibraryManager.swift
//  Sangeet3
//
//  Created by Yashvardhan on 29/12/24.
//
//  Library management with GRDB persistence
//

import Foundation
import Combine
import AppKit
import GRDB
import UniformTypeIdentifiers

/// Manages music library with GRDB persistence
@MainActor
final class LibraryManager: ObservableObject {
    
    // MARK: - Published State
    @Published var tracks: [Track] = []
    @Published var albums: [String: [Track]] = [:]
    @Published var artists: [String: [Track]] = [:]
    @Published var folders: [URL] = []
    @Published var isScanning = false
    @Published var scanProgress: String = ""
    
    // Derived collections
    @Published var recentlyAddedSongs: [Track] = []
    @Published var mostListenedSongs: [Track] = []
    @Published var recentlyPlayedSongs: [Track] = []
    
    // MARK: - Supported Formats
    private let supportedExtensions: Set<String> = [
        "mp3", "m4a", "aac", "flac", "wav", "aiff", "aif", "caf", "ogg", "opus"
    ]
    
    // MARK: - Singleton
    static let shared = LibraryManager()
    
    private init() {
        Task { await setupLibrary() }
        
        // Listen for new downloads to instantly update UI
        NotificationCenter.default.addObserver(
            forName: .init("DownloadDidFinish"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            // Quickly re-scan or add to tracks manually if we have full metadata
            // For now, rely on scanAllFolders which is triggered by DownloadManager, 
            // but we can also force a UI refresh of 'recentlyAdded' here if needed.
            // The isScanning flag will handle some UI state.
            
            // Just ensure we notify observers
            self.objectWillChange.send()
        }
    }
    
    // MARK: - Database Loading
    
    private func setupLibrary() async {
        // Load initial folders and tracks
        // Load folders from DB
        let folderRecords = try? DatabaseManager.shared.read { db in
            try FolderRecord.fetchAll(db)
        }
        
        var resolvedFolders: [URL] = []
        for record in folderRecords ?? [] {
            if let bookmark = record.bookmark {
                var isStale = false
                if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale), !isStale {
                    resolvedFolders.append(url)
                    // Start monitoring
                    startMonitoring(folder: url)
                }
            } else {
                let url = record.toURL()
                resolvedFolders.append(url)
                startMonitoring(folder: url)
            }
        }
        
        await MainActor.run {
            self.folders = resolvedFolders
        }
        
        // Load tracks from database
        let trackRecords = try? DatabaseManager.shared.read { db in
            try TrackRecord.fetchAll(db: db)
        }
        
        await MainActor.run {
            self.tracks = trackRecords?.map { $0.toTrack() } ?? []
            // One-time repair for libraries that already accumulated duplicates.
            self.deduplicateLoadedLibrary()
            self.rebuildIndexes()
            // Fill in audio-quality for tracks imported before this existed.
            self.backfillAudioQuality()
        }
        
        // Always scan folders to detect new files
        if !folders.isEmpty {
            // Run in detached task to avoid blocking main thread initialization
            Task.detached(priority: .utility) { [weak self] in
                await self?.scanAllFolders()
            }
        }
        
        await loadPlaylists() // Ensure playlists are loaded
        
        await MainActor.run {
            self.loadInitialTrendingCache()
        }
    }
    

    
    // MARK: - Helper Methods
    
    /// Check if a track exists in library with fuzzy matching
    func hasTrack(title: String, artist: String) -> Bool {
        // 1. Try exact match (fast)
        let exactMatch = tracks.contains {
            $0.title.caseInsensitiveCompare(title) == .orderedSame &&
            $0.artist.caseInsensitiveCompare(artist) == .orderedSame &&
            !$0.isRemote
        }
        if exactMatch { return true }
        
        // 2. Fuzzy match
        // Often Tidal titles have "(feat. X)" or "Remastered" that local files might miss or have differently
        // Or "The Beatles" vs "Beatles"
        
        let targetTitle = sanitizeString(title)
        let targetArtist = sanitizeString(artist)
        
        return tracks.contains { local in
            if local.isRemote { return false }
            
            let localTitle = sanitizeString(local.title)
            let localArtist = sanitizeString(local.artist)
            
            // Check if one contains the other (e.g. "Orbit" inside "Orbit (Remix)")
            let titleMatch = localTitle.contains(targetTitle) || targetTitle.contains(localTitle)
            let artistMatch = localArtist.contains(targetArtist) || targetArtist.contains(localArtist)
            
            return titleMatch && artistMatch
        }
    }
    
    private func sanitizeString(_ str: String) -> String {
        var s = str.lowercased()
        
        // Remove parens and brackets: "Song (From X)" -> "Song "
        s = s.replacingOccurrences(of: "\\(.*?\\)", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
        
        // Remove common suffixes often found in titles
        // "Song feat. X", "Song from X", "Song Remix", "Song Version"
        // Note: We use a loop or multiple replacements to catch them all.
        // The regex ` (feat\\.|from|track|remix|version).*` is good but might miss edge cases.
        s = s.replacingOccurrences(of: " feat\\..*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: " from .*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: " remix.*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: " version.*", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "the ", with: "")
        
        // Remove non-alphanumeric (keep spaces for splitting?) No, simple filter is better.
        // "Aayi Nai" -> "aayinai"
        let alphanum = s.filter { $0.isLetter || $0.isNumber }
        
        return alphanum.isEmpty ? s : alphanum
    }
    
    func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "Select music folder(s) to import"
        panel.prompt = "Add Folder"
        
        if panel.runModal() == .OK {
            Task {
                for url in panel.urls {
                    if !folders.contains(url) {
                        await addFolderToDatabase(url)
                        folders.append(url)
                        startMonitoring(folder: url) // Watch for changes
                        await scanFolder(url)
                    }
                }
            }
        }
    }
    
    // Create default ~/Music/Sangeet folder
    func createDefaultFolder() async -> URL? {
        // 1. Get Music Directory
        guard let musicDir = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first else { return nil }
        
        let target = musicDir.appendingPathComponent("Sangeet")
        
        // 2. Create if needed
        if !FileManager.default.fileExists(atPath: target.path) {
            do {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            } catch {
                print("[LibraryManager] Failed to create default folder: \(error)")
                return nil
            }
        }
        
        // 3. Register
        if !folders.contains(target) {
            await addFolder(url: target)
        }
        
        return target
    }
    
    // Expose programmatic add folder
    func addFolder(url: URL) async {
        if !folders.contains(url) {
            await addFolderToDatabase(url)
            
            await MainActor.run {
                if !self.folders.contains(url) {
                     self.folders.append(url)
                }
            }
            
            startMonitoring(folder: url)
            await scanFolder(url)
        }
    }
    
    private func addFolderToDatabase(_ url: URL) async {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            
            let record = FolderRecord(url: url, bookmark: bookmarkData)
            _ = try DatabaseManager.shared.write { db in
                try record.insert(db)
            }
        } catch {
            print("[LibraryManager] Add folder error: \(error)")
        }
    }
    
    func removeFolder(_ url: URL) {
        folders.removeAll { $0 == url }
        tracks.removeAll { $0.fileURL.path.hasPrefix(url.path) }
        rebuildIndexes()
        
        stopMonitoring(folder: url) // Stop watching
        
        
        // Remove from database
        do {
            try DatabaseManager.shared.write { db in
                try FolderRecord.delete(path: url.path, db: db)
                try TrackRecord.deleteByFolder(url.path, db: db)
            }
        } catch {
            print("[LibraryManager] Remove folder error: \(error)")
        }
    }
    
    // MARK: - Folder Monitoring
    
    private var folderMonitors: [URL: FolderMonitor] = [:]

    /// Serializes folder scans. The launch `scanAllFolders()` and
    /// folder-monitor-triggered scans must never run concurrently, otherwise
    /// they read stale state and both append the same tracks.
    private var scanChain: Task<Void, Never>?
    
    private func startMonitoring(folder: URL) {
        // Stop existing if any
        stopMonitoring(folder: folder)
        
        let monitor = FolderMonitor(url: folder)
        monitor.onDidChange = { [weak self] in
            // Debounce scan: Wait 2 seconds
            // In a real app, use a Debouncer. For now, we'll just trigger task.
            // DispatchSource already coalesces events somewhat.
            Task {
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
                await self?.scanFolder(folder)
            }
        }
        monitor.start()
        folderMonitors[folder] = monitor
    }
    
    private func stopMonitoring(folder: URL) {
        folderMonitors[folder]?.stop()
        folderMonitors[folder] = nil
    }

    // MARK: - Scanning
    
    func scanAllFolders() async {
        await MainActor.run {
            self.isScanning = true
            self.scanProgress = "Syncing library..."
        }
        
        for folder in folders {
            await scanFolder(folder)
        }
        
        await MainActor.run {
            self.isScanning = false
            self.scanProgress = ""
        }
    }
    
    /// Public entry point. Chains onto any in-flight scan so scans never run
    /// concurrently, then awaits its own turn so callers still block until
    /// their scan completes (preserving previous behaviour).
    private func scanFolder(_ url: URL) async {
        let previous = scanChain
        let task = Task { [weak self] in
            await previous?.value
            await self?.performScanFolder(url)
        }
        scanChain = task
        await task.value
    }

    private func performScanFolder(_ url: URL) async {
        self.isScanning = true
        defer { self.isScanning = false }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        // 1. Enumerate the filesystem (recursive — includes Artist/Album subdirs).
        let fileManager = FileManager.default
        print("[LibraryManager] enumerating: \(url.path)")

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("[LibraryManager] Failed to create enumerator for \(url.path)")
            return
        }

        var diskURLs: [URL] = []
        for case let fileURL as URL in enumerator
            where supportedExtensions.contains(fileURL.pathExtension.lowercased()) {
            diskURLs.append(fileURL)
        }
        print("[LibraryManager] Scanning \(url.path): Found \(diskURLs.count) audio files")

        // Identity keys for everything currently on disk under this folder.
        let foundKeys = Set(diskURLs.map { canonicalKey($0) })

        // 2. New files = on disk but not already represented in memory.
        //    Memory mirrors the DB (loaded + deduplicated at launch), so this
        //    is the single source of truth — no folderPath-filtered DB query,
        //    which was wrong for files in subdirectories.
        let existingKeys = Set(
            tracks.lazy.filter { !$0.isRemote }.map { self.canonicalKey($0.fileURL) }
        )
        let newTracks = diskURLs
            .filter { !existingKeys.contains(canonicalKey($0)) }
            .map { createTrackFast(from: $0) }

        // 3. Pruning: local tracks under this folder whose file is gone.
        let root = url.path.hasSuffix("/") ? url.path : url.path + "/"
        let removed = tracks.filter { t in
            guard !t.isRemote else { return false }
            let p = t.fileURL.path
            guard p == url.path || p.hasPrefix(root) else { return false }
            return !foundKeys.contains(canonicalKey(t.fileURL))
        }
        if !removed.isEmpty {
            let removedIds = Set(removed.map { $0.id })
            let removedPaths = Set(removed.map { $0.fileURL.path })
            self.tracks.removeAll { removedIds.contains($0.id) }
            do {
                _ = try DatabaseManager.shared.write { db in
                    try TrackRecord
                        .filter(removedPaths.contains(Column("filePath")))
                        .deleteAll(db)
                }
            } catch {
                print("[LibraryManager] prune DB error: \(error)")
            }
            print("[LibraryManager] Pruned \(removed.count) deleted songs from \(url.lastPathComponent)")
        }

        // 4. Additions — idempotent in memory, guarded in the DB.
        if !newTracks.isEmpty {
            let added = appendTracksDeduplicated(newTracks)
            self.tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

            if !added.isEmpty {
                do {
                    try DatabaseManager.shared.write { db in
                        for track in added {
                            let exists = try TrackRecord
                                .filter(Column("filePath") == track.fileURL.path)
                                .fetchCount(db) > 0
                            if !exists {
                                try TrackRecord(from: track).insert(db)
                            }
                        }
                    }
                } catch {
                    print("[LibraryManager] add DB error: \(error)")
                }
                print("[LibraryManager] Added \(added.count) new songs from \(url.lastPathComponent)")

                Task.detached(priority: .background) { [weak self] in
                    await self?.extractMetadataInBackground(for: added)
                }
            }
        }

        if !removed.isEmpty || !newTracks.isEmpty {
            self.rebuildIndexes()
        }
    }
    
    private func createTrackFast(from url: URL) -> Track {
        let filename = url.deletingPathExtension().lastPathComponent
        let parts = filename.components(separatedBy: " - ")
        
        let title: String
        let artist: String
        
        if parts.count >= 2 {
            artist = parts[0].trimmingCharacters(in: .whitespaces)
            title = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
        } else {
            title = filename
            artist = "Unknown Artist"
        }
        
        let album = url.deletingLastPathComponent().lastPathComponent
        
        // Get Creation Date for correct "Recently Added" sorting
        var dateAdded = Date()
        if let resources = try? url.resourceValues(forKeys: [.creationDateKey]),
           let creationDate = resources.creationDate {
            dateAdded = creationDate
        }
        
        return Track(
            title: title,
            artist: artist,
            album: album,
            duration: 0,
            fileURL: url,
            dateAdded: dateAdded // Use actual file creation date
        )
    }

    // MARK: - Deduplication

    /// Stable identity key for a local file: symlink-resolved, standardized,
    /// lowercased path. Two URLs that point at the same file produce the same
    /// key even if their textual form differs.
    private func canonicalKey(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }

    /// Identity key for any track (local file path or remote URL).
    private func trackKey(_ track: Track) -> String {
        track.isRemote ? track.fileURL.absoluteString : canonicalKey(track.fileURL)
    }

    /// Append tracks to the in-memory library, skipping any whose identity key
    /// is already present (or duplicated within `incoming`). Returns only the
    /// tracks that were actually added so callers can scope DB writes and
    /// metadata extraction to genuine additions.
    @discardableResult
    private func appendTracksDeduplicated(_ incoming: [Track]) -> [Track] {
        var seen = Set(tracks.map { trackKey($0) })
        var added: [Track] = []
        for t in incoming {
            let key = trackKey(t)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            tracks.append(t)
            added.append(t)
        }
        return added
    }

    /// One-time repair run at launch: collapse any in-memory duplicate tracks
    /// (same underlying file / remote URL) that earlier buggy scans or imports
    /// may have produced, and re-point playlist rows that referenced a dropped
    /// duplicate id at the surviving track.
    private func deduplicateLoadedLibrary() {
        var survivorByKey: [String: String] = [:]   // key -> surviving id
        var idRemap: [String: String] = [:]          // dropped id -> survivor id
        var deduped: [Track] = []
        deduped.reserveCapacity(tracks.count)

        for t in tracks {
            let key = trackKey(t)
            if let survivorId = survivorByKey[key] {
                if survivorId != t.id.uuidString {
                    idRemap[t.id.uuidString] = survivorId
                }
            } else {
                survivorByKey[key] = t.id.uuidString
                deduped.append(t)
            }
        }

        guard deduped.count != tracks.count else { return }
        let removedCount = tracks.count - deduped.count
        tracks = deduped
        print("[LibraryManager] Cleanup: removed \(removedCount) duplicate track(s) from library")

        guard !idRemap.isEmpty else { return }
        Task.detached(priority: .utility) {
            do {
                try DatabaseManager.shared.write { db in
                    for (oldId, newId) in idRemap {
                        // Drop playlist rows that would collide with an
                        // existing (playlistId, survivor) pair, re-point the
                        // rest, then delete the orphaned duplicate track row.
                        try db.execute(sql: """
                            DELETE FROM playlistTrack
                            WHERE trackId = ?
                              AND EXISTS (
                                SELECT 1 FROM playlistTrack p2
                                WHERE p2.playlistId = playlistTrack.playlistId
                                  AND p2.trackId = ?
                              )
                            """, arguments: [oldId, newId])
                        try db.execute(
                            sql: "UPDATE playlistTrack SET trackId = ? WHERE trackId = ?",
                            arguments: [newId, oldId])
                        try db.execute(
                            sql: "DELETE FROM track WHERE id = ?",
                            arguments: [oldId])
                    }
                }
            } catch {
                print("[LibraryManager] cleanup remap error: \(error)")
            }
        }
    }

    // MARK: - Metadata Extraction
    
    private func extractMetadataInBackground(for newTracks: [Track]) async {
        for track in newTracks {
            let accessing = track.fileURL.startAccessingSecurityScopedResource()
            defer { if accessing { track.fileURL.stopAccessingSecurityScopedResource() } }
            
            let metadata = await MetadataExtractor.shared.extractMetadata(from: track.fileURL)
            
            // Update in memory
            await MainActor.run {
                if let index = self.tracks.firstIndex(where: { $0.id == track.id }) {
                    self.tracks[index].duration = metadata.duration
                    if let title = metadata.title, !title.isEmpty, title != "Unknown" {
                        self.tracks[index].title = title
                    }
                    if let artist = metadata.artist, !artist.isEmpty, artist != "Unknown Artist" {
                        self.tracks[index].artist = artist
                    }
                    if let album = metadata.album, !album.isEmpty, album != "Unknown Album" {
                        self.tracks[index].album = album
                    }
                    if let artworkData = metadata.artworkData {
                        self.tracks[index].artworkData = artworkData
                    }
                    if metadata.sampleRate > 0 {
                        self.tracks[index].sampleRate = Int(metadata.sampleRate)
                    }
                    if let bitDepth = metadata.bitDepth {
                        self.tracks[index].bitDepth = bitDepth
                    }
                    if let bitrate = metadata.bitrate {
                        self.tracks[index].bitrate = bitrate
                    }
                    if let codec = metadata.codec {
                        self.tracks[index].codec = codec
                    }

                    // Update in database
                    let updatedTrack = self.tracks[index]
                    DatabaseManager.shared.writeAsync { db in
                        let record = TrackRecord(from: updatedTrack)
                        try record.update(db)
                    }
                }
            }
        }
        
        // Rebuild indexes after metadata update
        await MainActor.run {
            self.rebuildIndexes()
        }
    }
    
    /// Incremental, best-effort pass that fills in audio-quality fields
    /// (sample rate / bit depth / bitrate / codec) for local tracks that
    /// don't have them yet — i.e. libraries imported before the quality
    /// badge existed. Detached + utility QoS so it never blocks the UI;
    /// unreadable files stay unfixed and are retried next launch.
    func backfillAudioQuality() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            let pending = await MainActor.run {
                self.tracks.filter { !$0.isRemote && $0.sampleRate == nil }
            }
            guard !pending.isEmpty else { return }

            for track in pending {
                let accessing = track.fileURL.startAccessingSecurityScopedResource()
                let info = MetadataExtractor.shared.extractAudioInfo(from: track.fileURL)
                if accessing { track.fileURL.stopAccessingSecurityScopedResource() }

                // Nothing readable -> leave unfixed, retried next launch.
                guard info.sampleRate != nil || info.bitDepth != nil || info.bitrate != nil else { continue }

                await MainActor.run {
                    guard let idx = self.tracks.firstIndex(where: { $0.id == track.id }) else { return }
                    self.tracks[idx].sampleRate = info.sampleRate
                    self.tracks[idx].bitDepth = info.bitDepth
                    self.tracks[idx].bitrate = info.bitrate
                    if let codec = info.codec { self.tracks[idx].codec = codec }

                    let updated = self.tracks[idx]
                    DatabaseManager.shared.writeAsync { db in
                        let record = TrackRecord(from: updated)
                        try record.update(db)
                    }
                }
            }

            await MainActor.run { self.rebuildIndexes() }
        }
    }

    func updateTrackMetadata(track: Track) {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[index] = track
            rebuildIndexes()
            
            DatabaseManager.shared.writeAsync { db in
                let record = TrackRecord(from: track)
                try record.update(db)
            }
        }
    }

    /// Clears the metadata "fixed" flag for every track so the next
    /// auto-tagging run reprocesses the whole library from scratch.
    /// Single in-memory pass + one bulk SQL write (the flag is in no
    /// index or derived collection, so no rebuildIndexes needed).
    func resetAllMetadataFixed() {
        for i in tracks.indices where tracks[i].metadataFixed {
            tracks[i].metadataFixed = false
        }
        DatabaseManager.shared.writeAsync { db in
            try db.execute(sql: "UPDATE track SET metadataFixed = 0")
        }
    }

    // MARK: - Track Operations
    
    func toggleFavorite(_ track: Track) {
        // 1. Check if track is already in library (by ID)
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            // Track Exists
            tracks[index].isFavorite.toggle()
            let newValue = tracks[index].isFavorite
            
            // Smart Download: If marking as Favorite AND it's a Remote track -> Download it
            if newValue && tracks[index].isRemote {
                print("[LibraryManager] Smart Favorite: Auto-downloading '\(track.title)'")
                triggerDownload(for: tracks[index])
            }
            
            // Interaction & DB Update
            if newValue {
                RecommendationEngine.shared.recordInteraction(for: track, type: .liked)
            } else {
                RecommendationEngine.shared.recordInteraction(for: track, type: .unliked)
            }
            
            DatabaseManager.shared.writeAsync { db in
                let record = TrackRecord(from: self.tracks[index])
                try record.update(db)
            }
        } else {
            // 2. Track NOT in library (e.g. from Search/Trending)
            // Add to library, Mark Favorite, and Download
            print("[LibraryManager] Smart Favorite: Adding & Downloading new track '\(track.title)'")
            
            var newTrack = track
            newTrack.isFavorite = true
            newTrack.dateAdded = Date()
            
            // Add to memory
            tracks.append(newTrack)
            rebuildIndexes()
            
            // Add to DB
            DatabaseManager.shared.writeAsync { db in
                try TrackRecord(from: newTrack).insert(db)
            }
            
            // Trigger Download if Remote
            if newTrack.isRemote {
                triggerDownload(for: newTrack)
            }
            
            RecommendationEngine.shared.recordInteraction(for: newTrack, type: .liked)
        }
    }
    
    private func triggerDownload(for track: Track) {
        guard let url = track.fileURL.absoluteString.removingPercentEncoding,
              url.starts(with: "tidal://"),
              let idStr = track.fileURL.host,
              let id = Int(idStr) else { return }
        
        // Construct Proxy TidalTrack
        // We assume valid metadata is present in the Track object
        let artistObj = TidalArtist(id: 0, name: track.artist)
        let albumObj = TidalAlbum(id: 0, title: track.album, cover: nil) // We don't need cover ID for download if we have cover URL?
        // Actually DownloadManager uses `track.coverURL` which is computed from `track.album.cover`.
        // The `Track` object stores `artworkData` or we might fetch it?
        // Wait, `DownloadManager` expects `TidalTrack`. `TidalTrack` computes coverURL from `album.cover` path.
        // `Track` doesn't store the specific Tidal cover ID.
        
        // Let's create a partial TidalTrack.
        // DownloadManager uses: id, title, artist.name, album.title, coverURL (optional).
        
        // If we don't have the cover path, we might miss the cover art in the download unless we fetch full metadata.
        // For "Smart Favorites", speed is key. We can download audio first.
        // OR: We can construct `TidalTrack` better if the original `Track` came from `TidalTrack` conversion.
        // But `Track` struct loses the specific Tidal cover ID.
        
        let tidalTrack = TidalTrack(
            id: id,
            title: track.title,
            duration: Int(track.duration),
            artist: artistObj,
            artists: [artistObj],
            album: albumObj,
            releaseDate: nil,
            popularity: nil
        )
        
        DownloadManager.shared.download(track: tidalTrack)
    }
    

    
    func incrementPlayCount(_ track: Track) {
        if let index = tracks.firstIndex(where: { $0.id == track.id }) {
            tracks[index].playCount += 1
            tracks[index].lastPlayed = Date()
            
            // Update in database
            DatabaseManager.shared.writeAsync { db in
                let record = TrackRecord(from: self.tracks[index])
                try record.update(db)
            }
            
            // Trigger UI update
            rebuildIndexes()
        }
    }
    
    /// Delete a track from disk, database, and memory
    func deleteTrack(_ track: Track) {
        // 1. Remove from memory immediately for instant UI feedback
        tracks.removeAll { $0.id == track.id }
        rebuildIndexes()
        
        // 2. Delete from database
        DatabaseManager.shared.writeAsync { db in
            try TrackRecord
                .filter(Column("id") == track.id.uuidString)
                .deleteAll(db)
            
            // Also remove from any playlists
            try PlaylistTrackRecord
                .filter(Column("trackId") == track.id.uuidString)
                .deleteAll(db)
        }
        
        // 3. Delete file from disk (only for local files)
        if !track.isRemote {
            let fileURL = track.fileURL
            let accessing = fileURL.startAccessingSecurityScopedResource()
            defer { if accessing { fileURL.stopAccessingSecurityScopedResource() } }
            
            do {
                try FileManager.default.removeItem(at: fileURL)
                print("[LibraryManager] Deleted file: \(fileURL.lastPathComponent)")
                
                // Also delete any sidecar files (artwork, metadata)
                let basePath = fileURL.deletingPathExtension()
                let sidecarExtensions = ["jpg", "png", "json"]
                for ext in sidecarExtensions {
                    let sidecarURL = basePath.appendingPathExtension(ext)
                    try? FileManager.default.removeItem(at: sidecarURL)
                }
            } catch {
                print("[LibraryManager] Delete file error: \(error)")
            }
        }
        
        // 4. Notify UI
        objectWillChange.send()
    }
    
    // MARK: - Favorites
    
    var favorites: [Track] {
        tracks.filter { $0.isFavorite }
    }
    

    
    // MARK: - Playlist Management
    
    @Published var playlists: [PlaylistRecord] = []
    
    func createPlaylist(name: String) {
        let playlist = PlaylistRecord(name: name, isSystem: false)
        Task {
            do {
                _ = try DatabaseManager.shared.write { db in
                    try playlist.insert(db)
                }
                print("[LibraryManager] Created playlist: '\(name)'")
                await loadPlaylists()
            } catch {
                print("[LibraryManager] Create playlist error: \(error)")
            }
        }
    }
    
    func deletePlaylist(_ playlist: PlaylistRecord) {
        guard !playlist.isSystem else { return }
        Task {
            do {
                _ = try DatabaseManager.shared.write { db in
                    try playlist.delete(db)
                }
                await loadPlaylists()
            } catch {
                print("[LibraryManager] Delete playlist error: \(error)")
            }
        }
    }
    
    func addTrackToPlaylist(_ track: Track, playlist: PlaylistRecord) {
        Task {
            do {
                _ = try DatabaseManager.shared.write { db in
                    // 1. Ensure Track exists in DB (especially for Remote tracks)
                    // If it's a Tidal track, it might not be in our DB yet.
                    let trackRecord = TrackRecord(from: track)
                    // Use upsert mechanism (insert or replace)
                    if try TrackRecord.filter(Column("id") == track.id.uuidString).fetchCount(db) == 0 {
                        try trackRecord.insert(db)
                    }
                    
                    // 2. Check if track already exists in playlist
                    let existing = try PlaylistTrackRecord
                        .filter(Column("playlistId") == playlist.id)
                        .filter(Column("trackId") == track.id.uuidString)
                        .fetchCount(db)
                    
                    guard existing == 0 else {
                        print("[LibraryManager] Track already in playlist: \(playlist.name)")
                        return
                    }
                    
                    // 3. Get max position
                    let count = try PlaylistTrackRecord
                        .filter(Column("playlistId") == playlist.id)
                        .fetchCount(db)
                    
                    let record = PlaylistTrackRecord(
                        playlistId: playlist.id,
                        trackId: track.id.uuidString,
                        position: count,
                        dateAdded: Date()
                    )
                    try record.insert(db)
                    print("[LibraryManager] Added '\(track.title)' to playlist '\(playlist.name)'")
                }
                
                // Notify UI to refresh
                await MainActor.run {
                    NotificationCenter.default.post(name: .playlistUpdated, object: playlist.id)
                    // We must also refresh the main tracks list if we added a new remote track?
                    // No, generally we only show local tracks in "Library", but playlists can have remote.
                    // But we likely need to reload the specific playlist view.
                    self.objectWillChange.send()
                }
            } catch {
                print("[LibraryManager] Add to playlist error: \(error)")
            }
        }
    }
    
    func removeTrackFromPlaylist(_ track: Track, playlist: PlaylistRecord) {
        Task {
            do {
                _ = try DatabaseManager.shared.write { db in
                    try PlaylistTrackRecord
                        .filter(Column("playlistId") == playlist.id)
                        .filter(Column("trackId") == track.id.uuidString)
                        .deleteAll(db)
                }
                print("[LibraryManager] Removed '\(track.title)' from playlist '\(playlist.name)'")
                
                // Notify UI to refresh
                await MainActor.run {
                    NotificationCenter.default.post(name: .playlistUpdated, object: playlist.id)
                    self.objectWillChange.send() // Force UI update for track counts
                }
            } catch {
                print("[LibraryManager] Remove from playlist error: \(error)")
            }
        }
    }
    
    // MARK: - Smart Queue Recommendations
    
    /// Fast: Returns top tracks for the seed artist immediately
    /// excludeTracks: List of tracks to strictly exclude (e.g. current queue + detailed history)
    func getFastRecommendations(for seedTrack: Track, exclude: [Track] = []) async -> [Track] {
        print("[LibraryManager] Smart Queue (Fast): Fetching Top Tracks for '\(seedTrack.artist)'")
        do {
            let query = seedTrack.artist
            let results = try await TidalDLService.shared.search(query: query)
            
            // Build exclusion set (Titles lowercased)
            let excludedTitles = Set(exclude.map { sanitizeString($0.title) })
            let seedTitle = sanitizeString(seedTrack.title)
            
            let filtered = results.filter { candidate in
                let candTitle = sanitizeString(candidate.title)
                
                // 1. Strict Self Exclusion
                if candTitle == seedTitle { return false }
                if candTitle.contains(seedTitle) || seedTitle.contains(candTitle) { return false }
                
                // 2. Queue Exclusion
                if excludedTitles.contains(candTitle) { return false }
                
                return true
            }
            
            // Increased to 5
            return resolveTracks(Array(filtered.prefix(5)))
        } catch {
            print("[LibraryManager] Smart Queue (Fast) Error: \(error)")
            return []
        }
    }
    
    /// Deep: Returns a mix of Track Radio (Mood/Genre) OR Similar Artists
    func getDeepRecommendations(for seedTrack: Track, exclude: [Track] = []) async -> [Track] {
        print("[LibraryManager] Smart Queue (Deep): Generating mix for '\(seedTrack.title)'")
        
        let excludedTitles = Set(exclude.map { sanitizeString($0.title) })
        let seedTitle = sanitizeString(seedTrack.title)
        
        // Helper to filter and deduplicate
        let filterCandidates: ([TidalTrack]) -> [TidalTrack] = { candidates in
            var seen = Set<String>()
            return candidates.filter { candidate in
                let candTitle = self.sanitizeString(candidate.title)
                
                // 1. Check against Seed and Excludes
                if candTitle == seedTitle { return false }
                if candTitle.contains(seedTitle) || seedTitle.contains(candTitle) { return false }
                if excludedTitles.contains(candTitle) { return false }
                
                // 2. Check internal duplicates (e.g. "Song" vs "Song (OST)")
                if seen.contains(candTitle) { return false }
                seen.insert(candTitle)
                
                return true
            }
        }
        
        var rawCandidates: [Track] = []
        
        // 1. Try Track Radio
        if seedTrack.isRemote, let seedID = Int(seedTrack.fileURL.host ?? "") {
             do {
                 let radioTracks = try await TidalDLService.shared.getTrackRadio(trackID: seedID)
                 
                 // VARIETY CHECK:
                 // If Track Radio is dominated by the same artist, we MUST mix in Similar Artists.
                 let uniqueRadio = filterCandidates(radioTracks)
                 let seedArtistNorm = sanitizeString(seedTrack.artist)
                 
                 let sameArtistCount = uniqueRadio.filter { sanitizeString($0.artistName) == seedArtistNorm }.count
                 let varietyRatio = Double(sameArtistCount) / Double(max(1, uniqueRadio.count))
                 
                 if !radioTracks.isEmpty && varietyRatio < 0.4 {
                     // Good Variety: Use Radio directly
                     print("[LibraryManager] Smart Queue (Deep): Using Track Radio (Values: \(radioTracks.count), Variety: \(1.0 - varietyRatio))")
                     rawCandidates = resolveTracks(Array(uniqueRadio.prefix(25)))
                 } else {
                     // Low Variety or Empty: We need to mix in Similar Artists
                     print("[LibraryManager] Smart Queue (Deep): Track Radio too homogenous (\(Int(varietyRatio * 100))% same artist). Mixing in Similar Artists.")
                     
                     // Keep some radio tracks (Max 3 from seed artist)
                     // Low Variety or Empty: We need to mix in Similar Artists
                     print("[LibraryManager] Smart Queue (Deep): Track Radio too homogenous (\(Int(varietyRatio * 100))% same artist). Mixing in Similar Artists.")
                     
                     // Keep more radio tracks as backup (Max 10 from seed artist)
                     let radioFiltered = uniqueRadio.filter { sanitizeString($0.artistName) != seedArtistNorm }
                     let radioSame = uniqueRadio.filter { sanitizeString($0.artistName) == seedArtistNorm }.prefix(10)
                     
                     rawCandidates = resolveTracks(Array(radioFiltered + radioSame))
                 }
             } catch {
                 print("[LibraryManager] Smart Queue (Deep): Track Radio unavailable.")
             }
        }
        
        let radioBackup = rawCandidates // Store what we found from Radio for fallback
        
        // 2. Similar Artists Injection (If needed)
        // If we have < 10 candidates after Radio, or if we ignored Radio due to low variety
        if rawCandidates.count < 15 {
            do {
                // Get Artist ID
                var artistID: Int?
                if seedTrack.isRemote, let t = try? await TidalDLService.shared.search(query: "\(seedTrack.title) \(seedTrack.artist)").first {
                     artistID = t.artist?.id ?? t.artists?.first?.id
                } else if let t = try? await TidalDLService.shared.search(query: seedTrack.artist).first {
                    artistID = t.artist?.id ?? t.artists?.first?.id
                }
                
                if let id = artistID {
                    let similarArtists = try await TidalDLService.shared.getSimilarArtists(id: id)
                    
                    var similarCandidates: [TidalTrack] = []
                    
                    await withTaskGroup(of: [TidalTrack].self) { group in
                        for artist in similarArtists.prefix(7) { 
                             group.addTask {
                                do {
                                    // Fetch top tracks for this similar artist
                                    let tracks = try await TidalDLService.shared.search(query: artist.name)
                                    return Array(tracks.prefix(3))
                                } catch { return [] }
                            }
                        }
                        
                        for await tracks in group {
                            similarCandidates.append(contentsOf: tracks)
                        }
                    }
                    
                    if !similarCandidates.isEmpty {
                         let uniqueSimilar = filterCandidates(similarCandidates)
                         let resolvedSimilar = resolveTracks(uniqueSimilar)
                         
                         // Merge
                         if rawCandidates.isEmpty {
                             rawCandidates = resolvedSimilar
                         } else {
                             // Interleave / Append
                             rawCandidates.append(contentsOf: resolvedSimilar)
                         }
                    } else {
                        // Similar Artists returned empty (Maybe API issue)
                        // If we aggressively filtered Radio earlier, RESTORE IT!
                        if rawCandidates.count < 5, let radioTracks = try? await TidalDLService.shared.getTrackRadio(trackID: Int(seedTrack.fileURL.host ?? "") ?? 0) {
                            print("[LibraryManager] Similar Artists failed. Restoring original Track Radio.")
                            let unique = filterCandidates(radioTracks)
                            rawCandidates = resolveTracks(Array(unique.prefix(25)))
                        }
                    }
                }
            } catch {
                 print("[LibraryManager] Similar Artists fallback failed: \(error)")
                 // Restore Backup if needed
                 if rawCandidates.count < 5 && radioBackup.count > rawCandidates.count {
                      rawCandidates = radioBackup
                 }
            }
        }
        
        // 3. Final Shuffle & Recommendations
        if !rawCandidates.isEmpty {
            // Shuffle to mix Radio vs Similar
            rawCandidates.shuffle()
            
            // Apply Recommendation Engine Ranking
            print("[LibraryManager] Ranking \(rawCandidates.count) candidates with Recommendation Engine...")
            // We request rank, but engine might prioritize "Liked" artists.
            let ranked = await RecommendationEngine.shared.rank(candidates: rawCandidates)
            
            // 4. Final Variety Enforcer (Post-Ranking)
            // Ensure no more than 3 songs from Seed Artist appear in total.
            let seedArtistNorm = sanitizeString(seedTrack.artist)
            
            // Soft Limit: Try to limit to 4. If total < 5, allow more.
            var seedCount = 0
            var filtered: [Track] = []
            
            // First pass: Add non-seed songs and up to 4 seed songs
            for t in ranked {
                if sanitizeString(t.artist) == seedArtistNorm {
                    seedCount += 1
                    if seedCount > 4 { continue }
                }
                filtered.append(t)
            }
            
            // Emergency Check: If we filtered too much and have < 5 songs, put them back!
            if filtered.count < 5 {
                let currentIDs = Set(filtered.map { $0.id })
                for t in ranked {
                    if !currentIDs.contains(t.id) {
                        filtered.append(t)
                        if filtered.count >= 10 { break }
                    }
                }
            }
            
            return filtered
        }
        
        return []
    }
    
    // Deterministic UUID generation
    private func resolveTracks(_ tidalTracks: [TidalTrack]) -> [Track] {
        var references: [Track] = []
        for tidalTrack in tidalTracks {
            if let localTrack = findLocalTrack(title: tidalTrack.title, artist: tidalTrack.artistName) {
                references.append(localTrack)
            } else {
                // Generate Deterministic UUID based on Tidal ID
                // UUID from string hash is reliable for duplicates
                let uuidString = UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", tidalTrack.id))") ?? UUID()

                // Tidal is streamed at LOSSLESS by default (see getStreamURL).
                let q = AudioQuality.info(forTidalQuality: "LOSSLESS")
                references.append(Track(
                    id: uuidString,
                    title: tidalTrack.title,
                    artist: tidalTrack.artistName,
                    album: tidalTrack.albumName,
                    duration: TimeInterval(tidalTrack.duration),
                    fileURL: URL(string: "tidal://\(tidalTrack.id)")!,
                    artworkURL: tidalTrack.coverURL,
                    externalID: String(tidalTrack.id),
                    sampleRate: q.sampleRate,
                    bitDepth: q.bitDepth,
                    bitrate: q.bitrate,
                    codec: q.codec
                ))
            }
        }
        return references
    }
    
    /// Helper to find local track fuzzy
    private func findLocalTrack(title: String, artist: String) -> Track? {
        return tracks.first { track in
             !track.isRemote &&
             sanitizeString(track.title) == sanitizeString(title) &&
             sanitizeString(track.artist) == sanitizeString(artist)
        }
    }
    
    func loadPlaylists() async {
        do {
            let records = try DatabaseManager.shared.read { db in
                try PlaylistRecord.order(Column("name")).fetchAll(db)
            }
            await MainActor.run {
                self.playlists = records
                print("[LibraryManager] Loaded \(records.count) playlists: \(records.map { $0.name })")
            }
        } catch {
            print("[LibraryManager] Load playlists error: \(error)")
        }
    }
    
    func getTracks(for playlist: PlaylistRecord) async -> [Track] {
        do {
            let trackIds = try DatabaseManager.shared.read { db in
                try PlaylistTrackRecord
                    .filter(Column("playlistId") == playlist.id)
                    .order(Column("position"))
                    .fetchAll(db)
                    .map { $0.trackId }
            }
            
            // Map IDs to in-memory tracks to preserve object identity/state
            return await MainActor.run {
                trackIds.compactMap { id in
                    self.tracks.first(where: { $0.id.uuidString == id })
                }
            }
        } catch {
            print("[LibraryManager] Get playlist tracks error: \(error)")
            return []
        }
    }
    
    func getTrackCount(for playlist: PlaylistRecord) -> Int {
        do {
            return try DatabaseManager.shared.read { db in
                try PlaylistTrackRecord
                    .filter(Column("playlistId") == playlist.id)
                    .fetchCount(db)
            }
        } catch {
            return 0
        }
    }
    
    /// Check which playlists a track belongs to
    func getPlaylistIds(for track: Track) -> Set<String> {
        do {
            let ids = try DatabaseManager.shared.read { db in
                try PlaylistTrackRecord
                    .filter(Column("trackId") == track.id.uuidString)
                    .fetchAll(db)
                    .map { $0.playlistId }
            }
            return Set(ids)
        } catch {
            print("[LibraryManager] Failed to get playlist IDs for track: \(error)")
            return []
        }
    }
    
    // MARK: - Trending / Top Songs
    
    @Published var topSongs: [TidalTrack] = []
    @Published var isLoadingTopSongs = false
    
    // Explicitly for India
    @Published var trendingIndiaSongs: [TidalTrack] = []
    
    private var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }
    
    private var topSongsCacheURL: URL {
        cacheDirectory.appendingPathComponent("top_songs_world.json")
    }
    
    private var trendingIndiaCacheURL: URL {
        cacheDirectory.appendingPathComponent("trending_india.json")
    }
    
    func loadInitialTrendingCache() {
        // Load cached data immediately on app launch
        if let cachedWorld = loadTrendingCache(url: topSongsCacheURL) {
            self.topSongs = cachedWorld
        }
        
        if let cachedIndia = loadTrendingCache(url: trendingIndiaCacheURL) {
            self.trendingIndiaSongs = cachedIndia
        }
        
        // Trigger background refresh
        Task {
            await fetchTopSongs()
            await fetchTrendingIndia()
        }
    }
    
    func fetchTopSongs() async {
        if topSongs.isEmpty { isLoadingTopSongs = true }
        
        // 1. Fetch High-Quality curated list from iTunes RSS
        let countryCode = Locale.current.region?.identifier ?? "us"
        let iTunesSongs = await fetchITunesTrends(country: countryCode)
        
        // 2. Resolve to Tidal Tracks in parallel
        let resolvedTracks = await resolveToTidal(iTunesSongs)
        
        await MainActor.run {
            if !resolvedTracks.isEmpty {
                self.topSongs = resolvedTracks
            }
            self.isLoadingTopSongs = false
        }
    }
    
    func fetchTrendingIndia() async {
        // 1. Fetch India Trends
        let iTunesSongs = await fetchITunesTrends(country: "in")
        
        // 2. Resolve to Tidal
        let resolvedTracks = await resolveToTidal(iTunesSongs)
        
        await MainActor.run {
            if !resolvedTracks.isEmpty {
                self.trendingIndiaSongs = resolvedTracks
            }
        }
    }
    
    // MARK: - Hybrid Resolution Logic
    
    private func fetchITunesTrends(country: String) async -> [ITunesSimpleSong] {
        let urlString = "https://itunes.apple.com/\(country)/rss/topsongs/limit=15/json" // Fetch top 15
        guard let url = URL(string: urlString) else { return [] }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let feed = try JSONDecoder().decode(ITunesFeedRoot.self, from: data)
            return feed.feed.entry.map {
                ITunesSimpleSong(title: $0.title.label, artist: $0.artist.label)
            }
        } catch {
            print("[LibraryManager] iTunes RSS Error: \(error)")
            return []
        }
    }
    
    private func resolveToTidal(_ songs: [ITunesSimpleSong]) async -> [TidalTrack] {
        await withTaskGroup(of: TidalTrack?.self) { group in
            for song in songs {
                group.addTask {
                    let query = "\(song.title) \(song.artist)"
                    do {
                        let results = try await TidalDLService.shared.search(query: query)
                        // Heuristic: Try to find exact match
                        return results.first
                    } catch {
                        return nil
                    }
                }
            }
            
            var resolved: [TidalTrack] = []
            for await track in group {
                if let track = track {
                    resolved.append(track)
                }
            }
            // Sort by relevance? Hard since async returns largely random order. 
            // Ideally we'd map indices but for "Trending" a bit of shuffle is fine.
            return resolved
        }
    }
    
    // Removed legacy iTunes fetch methods
    
    // MARK: - Caching Helpers
    
    // MARK: - Caching Helpers
    
    // Updated to cache TidalTrack instead of ITunesSong
    private func saveTrendingCache(_ songs: [TidalTrack], url: URL) {
        Task.detached(priority: .background) {
            do {
                let data = try JSONEncoder().encode(songs)
                try data.write(to: url)
            } catch {
                print("[LibraryManager] Cache save error: \(error)")
            }
        }
    }
    
    private func loadTrendingCache(url: URL) -> [TidalTrack]? {
        do {
            let data = try Data(contentsOf: url)
            let songs = try JSONDecoder().decode([TidalTrack].self, from: data)
            return songs
        } catch {
            return nil
        }
    }
    
    // MARK: - Indexes
    
    private func rebuildIndexes() {
        albums.removeAll()
        artists.removeAll()
        
        for track in tracks {
            albums[track.album, default: []].append(track)
            artists[track.artist, default: []].append(track)
        }
        
        // Update derived collections
        recentlyAddedSongs = Array(tracks.sorted { $0.dateAdded > $1.dateAdded }.prefix(25))
        
        // Most Listened - Played songs first, then fill with others to reach 20
        let played = tracks.filter { $0.playCount > 0 }
            .sorted { $0.playCount > $1.playCount }
        
        // If we have fewer than 20 played songs, fill with unplayed ones (A-Z)
        if played.count < 20 {
            let needed = 20 - played.count
            let unplayed = tracks.filter { $0.playCount == 0 }
                .sorted { $0.title < $1.title }
                .prefix(needed)
            mostListenedSongs = played + Array(unplayed)
        } else {
            mostListenedSongs = Array(played.prefix(20))
        }
        
        // Recently Played
        recentlyPlayedSongs = Array(tracks.filter { $0.lastPlayed != nil }
            .sorted { $0.lastPlayed! > $1.lastPlayed! }
            .prefix(25))
    }

    // MARK: - M3U Playlist Import

    /// Creates a playlist and returns the created record.
    /// (`PlaylistRecord` generates its own id at init, so no re-fetch is needed.)
    @discardableResult
    func createPlaylistReturning(name: String) async -> PlaylistRecord? {
        let playlist = PlaylistRecord(name: name, isSystem: false)
        do {
            _ = try DatabaseManager.shared.write { db in
                try playlist.insert(db)
            }
            await loadPlaylists()
            print("[LibraryManager] Created playlist (returning): '\(name)'")
            return playlist
        } catch {
            print("[LibraryManager] createPlaylistReturning error: \(error)")
            return nil
        }
    }

    /// Presents an open panel to choose an `.m3u`/`.m3u8` file, imports it,
    /// and broadcasts the result via `.playlistImported`.
    @discardableResult
    func presentImportPlaylistPanel() async -> [PlaylistImportSummary] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Select one or more .m3u or .m3u8 playlists to import"
        panel.prompt = "Import"

        var types: [UTType] = [.plainText, .text]
        if let t = UTType(filenameExtension: "m3u") { types.append(t) }
        if let t = UTType(filenameExtension: "m3u8") { types.append(t) }
        if let t = UTType("public.m3u-playlist") { types.append(t) }
        panel.allowedContentTypes = types
        panel.allowsOtherFileTypes = true

        guard panel.runModal() == .OK else { return [] }
        let urls = panel.urls
        guard !urls.isEmpty else { return [] }

        var summaries: [PlaylistImportSummary] = []
        for url in urls {
            // Sequential: importPlaylist -> createPlaylistReturning -> loadPlaylists()
            // refreshes the in-memory `playlists` list, so a second same-named
            // file in the batch sees the first's playlist and takes the sync
            // path. Do NOT parallelize.
            summaries.append(await importPlaylist(from: url))
        }
        NotificationCenter.default.post(name: .playlistImported, object: summaries)
        return summaries
    }

    /// Ordered tracks resolved from an `.m3u`/`.m3u8` file plus the
    /// newly-created in-memory `Track`s that must enter the library.
    private struct ResolvedImport {
        var resolved: [Track] = []          // ordered, deduped by Track.id
        var newDiskTracks: [Track] = []
        var newRemoteTracks: [Track] = []
    }

    /// Resolves parsed `M3UEntry`s to library `Track`s. Matches existing
    /// local tracks by canonical path, then by sanitized title+artist, then
    /// falls back to reading the file off disk; remote URLs pass through.
    private func resolveEntries(_ entries: [M3UEntry],
                                into summary: inout PlaylistImportSummary) -> ResolvedImport {
        // Same canonical key as the rest of the library so in-memory and DB
        // matching stay consistent.
        func normalize(_ u: URL) -> String { self.canonicalKey(u) }
        var existingByPath: [String: Track] = [:]
        for t in tracks where !t.isRemote {
            existingByPath[normalize(t.fileURL)] = t
        }

        var out = ResolvedImport()
        var seenIds = Set<String>()

        for entry in entries {
            var track: Track?
            switch entry.kind {
            case .remoteURL(let remote):
                let t = Track(
                    title: entry.title ?? remote.lastPathComponent,
                    artist: entry.artist ?? "Unknown Artist",
                    duration: entry.duration ?? 0,
                    fileURL: remote
                )
                out.newRemoteTracks.append(t)
                summary.remote += 1
                track = t
            case .localPath(let path):
                let fileURL = URL(fileURLWithPath: path)
                let key = normalize(fileURL)
                if let match = existingByPath[key] {
                    track = match
                    summary.matched += 1
                } else if let title = entry.title,
                          let found = findLocalTrack(title: title, artist: entry.artist ?? "") {
                    track = found
                    summary.matched += 1
                } else if FileManager.default.fileExists(atPath: fileURL.path) {
                    var t = createTrackFast(from: fileURL)
                    if let title = entry.title, !title.isEmpty { t.title = title }
                    if let artist = entry.artist, !artist.isEmpty { t.artist = artist }
                    if let dur = entry.duration, dur > 0 { t.duration = dur }
                    out.newDiskTracks.append(t)
                    summary.importedFromDisk += 1
                    track = t
                } else {
                    summary.missing += 1
                    if summary.missingNames.count < 25 {
                        summary.missingNames.append(entry.title ?? fileURL.lastPathComponent)
                    }
                }
            }

            if let t = track, !seenIds.contains(t.id.uuidString) {
                seenIds.insert(t.id.uuidString)
                out.resolved.append(t)
            }
        }
        return out
    }

    /// Ensures a `TrackRecord` row exists for `t` and returns the row id to
    /// use in `playlistTrack`. Honors the `filePath` UNIQUE constraint by
    /// reusing an existing row that already owns the same path.
    private func ensureTrackRecord(_ t: Track, _ db: Database) throws -> String {
        var trackId = t.id.uuidString
        let idExists = try TrackRecord
            .filter(Column("id") == trackId).fetchCount(db) > 0
        if !idExists {
            let filePath = t.fileURL.path
            if let existing = try TrackRecord
                .filter(Column("filePath") == filePath).fetchOne(db) {
                trackId = existing.id
            } else {
                try TrackRecord(from: t).insert(db)
            }
        }
        return trackId
    }

    /// Post-write in-memory side effects shared by every import outcome:
    /// resolution may have introduced new disk/remote `Track`s that
    /// `getTracks(for:)` must be able to resolve against `self.tracks`.
    private func finishImport(playlistId: String,
                              newDiskTracks: [Track],
                              newRemoteTracks: [Track]) {
        let addedDisk = appendTracksDeduplicated(newDiskTracks)
        appendTracksDeduplicated(newRemoteTracks)
        rebuildIndexes()

        if !addedDisk.isEmpty {
            Task.detached(priority: .background) { [weak self] in
                await self?.extractMetadataInBackground(for: addedDisk)
            }
        }

        NotificationCenter.default.post(name: .playlistUpdated, object: playlistId)
        objectWillChange.send()
    }

    /// Parses an `.m3u`/`.m3u8` file and imports it. If a non-system playlist
    /// with the same name already exists, its track list is synced to the
    /// file (add/remove/reorder) instead of creating a duplicate.
    func importPlaylist(from url: URL) async -> PlaylistImportSummary {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let baseName = url.deletingPathExtension().lastPathComponent
        let entries = M3UParser.parse(fileURL: url)

        var summary = PlaylistImportSummary(playlistName: baseName)
        summary.totalEntries = entries.count

        // Nothing parsed — do not create an empty playlist.
        guard !entries.isEmpty else { return summary }

        let desiredName = baseName.isEmpty ? "Imported Playlist" : baseName
        let existing = playlists.first { $0.name == desiredName }

        let resolvedImport: ResolvedImport
        let targetPlaylistId: String

        if let existing, !existing.isSystem {
            // ---- UPDATE / SYNC PATH ----
            summary.playlistName = existing.name
            targetPlaylistId = existing.id
            resolvedImport = resolveEntries(entries, into: &summary)

            // A re-imported file whose entries ALL went missing yields an
            // empty resolved list. Never wipe an existing playlist to empty —
            // leave it as-is and report unchanged.
            guard !resolvedImport.resolved.isEmpty else {
                summary.outcome = .unchanged
                print("[LibraryManager] Sync '\(existing.name)': resolved empty — leaving playlist unchanged")
                return summary
            }

            do {
                summary = try DatabaseManager.shared.write { db -> PlaylistImportSummary in
                    var s = summary
                    // Desired ordered ids (dedupe by canonical track id).
                    var desiredIds: [String] = []
                    var seen = Set<String>()
                    for t in resolvedImport.resolved {
                        let tid = try self.ensureTrackRecord(t, db)
                        if seen.insert(tid).inserted { desiredIds.append(tid) }
                    }
                    // Current ordered ids.
                    let currentIds = try PlaylistTrackRecord
                        .filter(Column("playlistId") == existing.id)
                        .order(Column("position"))
                        .fetchAll(db)
                        .map { $0.trackId }

                    if currentIds == desiredIds {
                        s.outcome = .unchanged          // no DB mutation
                    } else {
                        try PlaylistTrackRecord
                            .filter(Column("playlistId") == existing.id)
                            .deleteAll(db)
                        let now = Date()
                        for (i, tid) in desiredIds.enumerated() {
                            try PlaylistTrackRecord(
                                playlistId: existing.id, trackId: tid,
                                position: i, dateAdded: now
                            ).insert(db)
                        }
                        var pl = existing
                        pl.dateModified = now
                        try pl.update(db)

                        let oldSet = Set(currentIds), newSet = Set(desiredIds)
                        s.outcome = .updated
                        s.tracksAdded = desiredIds.filter { !oldSet.contains($0) }.count
                        s.tracksRemoved = currentIds.filter { !newSet.contains($0) }.count
                    }
                    return s
                }
            } catch {
                print("[LibraryManager] importPlaylist sync DB write error: \(error)")
            }
        } else {
            // ---- CREATE PATH ---- (no match, or match is a system playlist)
            var finalName = desiredName
            if existing != nil {  // collided with a system playlist — number it
                let existingNames = Set(playlists.map { $0.name })
                var n = 2
                while existingNames.contains("\(finalName) \(n)") { n += 1 }
                finalName = "\(finalName) \(n)"
            }
            summary.playlistName = finalName
            summary.outcome = .created

            guard let created = await createPlaylistReturning(name: finalName) else {
                return summary
            }
            targetPlaylistId = created.id
            resolvedImport = resolveEntries(entries, into: &summary)

            // Single transaction: insert tracks (if needed) + ordered junction
            // rows. One transaction keeps `position` contiguous and race-free.
            do {
                _ = try DatabaseManager.shared.write { db in
                    var position = 0
                    for t in resolvedImport.resolved {
                        let trackId = try self.ensureTrackRecord(t, db)
                        // `playlistTrack` PK is (playlistId, trackId) — skip dupes.
                        let pairExists = try PlaylistTrackRecord
                            .filter(Column("playlistId") == created.id)
                            .filter(Column("trackId") == trackId)
                            .fetchCount(db) > 0
                        if pairExists { continue }
                        try PlaylistTrackRecord(
                            playlistId: created.id,
                            trackId: trackId,
                            position: position,
                            dateAdded: Date()
                        ).insert(db)
                        position += 1
                    }
                }
            } catch {
                print("[LibraryManager] importPlaylist DB write error: \(error)")
            }
        }

        finishImport(playlistId: targetPlaylistId,
                     newDiskTracks: resolvedImport.newDiskTracks,
                     newRemoteTracks: resolvedImport.newRemoteTracks)

        print("[LibraryManager] Import '\(summary.playlistName)' outcome=\(summary.outcome) matched=\(summary.matched) disk=\(summary.importedFromDisk) remote=\(summary.remote) missing=\(summary.missing) +\(summary.tracksAdded)/-\(summary.tracksRemoved)")
        return summary
    }
}

// MARK: - M3U Playlist Import Models

struct PlaylistImportSummary {
    /// Whether the import created a new playlist, synced an existing one,
    /// or found the existing playlist already identical to the file.
    enum Outcome { case created, updated, unchanged }

    var playlistName: String
    var outcome: Outcome = .created
    var totalEntries: Int = 0
    var matched: Int = 0
    var importedFromDisk: Int = 0
    var remote: Int = 0
    var missing: Int = 0
    var missingNames: [String] = []

    /// Populated only on the sync (`.updated`) path.
    var tracksAdded: Int = 0
    var tracksRemoved: Int = 0

    /// Number of tracks resolved into the playlist (added or already present).
    var addedCount: Int { matched + importedFromDisk + remote }
    /// True when the file could not be parsed into any entries.
    var parseFailed: Bool { totalEntries == 0 }
}

struct M3UEntry {
    enum Kind {
        case localPath(String)
        case remoteURL(URL)
    }
    var kind: Kind
    var title: String?
    var artist: String?
    var duration: TimeInterval?
}

/// Minimal `.m3u`/`.m3u8` parser. Handles `#EXTM3U`, `#EXTINF`,
/// CRLF line endings, BOM, Windows backslash paths, relative/absolute
/// local paths, `file://` and `http(s)`/`tidal` URLs.
enum M3UParser {
    static func parse(fileURL: URL) -> [M3UEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let latin1 = String(data: data, encoding: .isoLatin1) {
            text = latin1
        } else {
            return []
        }
        return parse(text: text, baseDirectory: fileURL.deletingLastPathComponent())
    }

    static func parse(text: String, baseDirectory: URL) -> [M3UEntry] {
        var entries: [M3UEntry] = []
        var pendingTitle: String?
        var pendingArtist: String?
        var pendingDuration: TimeInterval?

        var content = text
        if content.hasPrefix("\u{FEFF}") { content.removeFirst() }

        for rawLine in content.components(separatedBy: "\n") {
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                if line.uppercased().hasPrefix("#EXTINF:") {
                    let payload = String(line.dropFirst("#EXTINF:".count))
                    if let commaIdx = payload.firstIndex(of: ",") {
                        let durStr = payload[payload.startIndex..<commaIdx]
                            .trimmingCharacters(in: .whitespaces)
                        if let d = TimeInterval(durStr), d > 0 { pendingDuration = d }
                        let titlePart = String(payload[payload.index(after: commaIdx)...])
                            .trimmingCharacters(in: .whitespaces)
                        if !titlePart.isEmpty {
                            let parts = titlePart.components(separatedBy: " - ")
                            if parts.count >= 2 {
                                pendingArtist = parts[0].trimmingCharacters(in: .whitespaces)
                                pendingTitle = parts.dropFirst().joined(separator: " - ")
                                    .trimmingCharacters(in: .whitespaces)
                            } else {
                                pendingTitle = titlePart
                            }
                        }
                    }
                }
                // Ignore #EXTM3U and any other directive.
                continue
            }

            let kind: M3UEntry.Kind
            let lower = line.lowercased()
            if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("tidal:") {
                guard let u = URL(string: line) else {
                    pendingTitle = nil; pendingArtist = nil; pendingDuration = nil
                    continue
                }
                kind = .remoteURL(u)
            } else if lower.hasPrefix("file://") {
                let path = URL(string: line)?.path ?? line
                kind = .localPath(path)
            } else {
                var path = line.replacingOccurrences(of: "\\", with: "/")
                if !path.hasPrefix("/") {
                    path = baseDirectory.appendingPathComponent(path)
                        .standardizedFileURL.path
                }
                kind = .localPath(path)
            }

            entries.append(M3UEntry(
                kind: kind,
                title: pendingTitle,
                artist: pendingArtist,
                duration: pendingDuration
            ))
            pendingTitle = nil
            pendingArtist = nil
            pendingDuration = nil
        }

        return entries
    }
}

// MARK: - Private Helper Structs for Hybrid Fetching

struct ITunesSimpleSong {
    let title: String
    let artist: String
}

private struct ITunesFeedRoot: Codable {
    let feed: ITunesFeed
}

private struct ITunesFeed: Codable {
    let entry: [ITunesEntry]
}

private struct ITunesEntry: Codable {
    let title: ITunesLabel
    let artist: ITunesLabel
    
    enum CodingKeys: String, CodingKey {
        case title = "im:name"
        case artist = "im:artist"
    }
}

private struct ITunesLabel: Codable {
    let label: String
}



// MARK: - Recommendation Engine

enum UserInteractionType {
    case liked
    case unliked
    case playedFully
    case skippedImmediate // < 10s
    case skippedEarly     // < 30s
}

/// A local "Lightweight" ML Engine that ranks tracks based on User Affinity.
class RecommendationEngine {
    static let shared = RecommendationEngine()
    
    struct TasteProfile: Codable {
        /// Artist Name -> Affinity Score (Higher is better)
        var artistScores: [String: Double] = [:]
    }
    
    private var profile: TasteProfile
    private let queue = DispatchQueue(label: "com.sangeet.recommendation", qos: .background)
    
    private init() {
        if let data = UserDefaults.standard.data(forKey: "userTasteProfile"),
           let decoded = try? JSONDecoder().decode(TasteProfile.self, from: data) {
            self.profile = decoded
        } else {
            self.profile = TasteProfile()
        }
    }
    
    func recordInteraction(for track: Track, type: UserInteractionType) {
        queue.async {
            self.updateScore(for: track.artist, type: type)
            self.saveProfile()
        }
    }
    
    func rank(candidates: [Track]) async -> [Track] {
        let currentProfile = self.profile
        return candidates.sorted { trackA, trackB in
            let scoreA = self.calculateScore(for: trackA, profile: currentProfile)
            let scoreB = self.calculateScore(for: trackB, profile: currentProfile)
            return scoreA > scoreB
        }
    }
    
    private func updateScore(for artist: String, type: UserInteractionType) {
        let key = artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var current = profile.artistScores[key] ?? 0.0
        
        switch type {
        case .liked: current += 5.0
        case .unliked: current -= 5.0
        case .playedFully: current += 1.0
        case .skippedImmediate: current -= 3.0
        case .skippedEarly: current -= 1.0
        }
        
        current = max(-20.0, min(50.0, current))
        profile.artistScores[key] = current
        print("[RecommendationEngine] Updated score for '\(artist)': \(current)")
    }
    
    private func calculateScore(for track: Track, profile: TasteProfile) -> Double {
        let key = track.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let affinity = profile.artistScores[key] ?? 0.0
        let noise = Double.random(in: 0...0.1)
        return affinity + noise
    }
    
    private func saveProfile() {
        if let encoded = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(encoded, forKey: "userTasteProfile")
        }
    }
}
