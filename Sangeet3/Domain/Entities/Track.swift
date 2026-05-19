//
//  Track.swift
//  Sangeet3
//
//  Created by Yashvardhan on 29/12/24.
//

import Foundation

struct Track: Identifiable, Hashable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var fileURL: URL
    var artworkData: Data?
    var artworkURL: URL? // For remote or lazy loading
    var isFavorite: Bool
    var playCount: Int
    var lastPlayed: Date?
    var dateAdded: Date
    var metadataFixed: Bool = false

    // Audio fidelity (from BASS for local files, Tidal tier for streams).
    // nil = not yet extracted; see AudioQuality.swift.
    var sampleRate: Int?   // Hz, e.g. 44100, 96000
    var bitDepth: Int?     // bits, e.g. 16, 24
    var bitrate: Int?      // kbps (mainly lossy)
    var codec: String?     // "FLAC", "MP3", "AAC"... (explicit for remote tracks)

    var formattedDuration: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    /// Returns true if this track is from a remote streaming URL (not a local file)
    var isRemote: Bool {
        let scheme = fileURL.scheme?.lowercased() ?? ""
        return scheme == "http" || scheme == "https" || scheme == "tidal"
    }
    
    var externalID: String? // For reliable identification (e.g. Tidal ID)

    init(id: UUID = UUID(), title: String, artist: String = "Unknown Artist", album: String = "Unknown Album", duration: TimeInterval = 0, fileURL: URL, artworkData: Data? = nil, artworkURL: URL? = nil, isFavorite: Bool = false, playCount: Int = 0, lastPlayed: Date? = nil, dateAdded: Date = Date(), externalID: String? = nil, metadataFixed: Bool = false, sampleRate: Int? = nil, bitDepth: Int? = nil, bitrate: Int? = nil, codec: String? = nil) {
        self.id = id; self.title = title; self.artist = artist; self.album = album; self.duration = duration; self.fileURL = fileURL; self.artworkData = artworkData; self.artworkURL = artworkURL; self.isFavorite = isFavorite; self.playCount = playCount; self.lastPlayed = lastPlayed; self.dateAdded = dateAdded; self.externalID = externalID; self.metadataFixed = metadataFixed; self.sampleRate = sampleRate; self.bitDepth = bitDepth; self.bitrate = bitrate; self.codec = codec
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        // We generally hash ID for set/dict performance, but == determines view updates
    }
    
    static func == (lhs: Track, rhs: Track) -> Bool {
        return lhs.id == rhs.id &&
               lhs.artworkURL == rhs.artworkURL &&
               lhs.artworkData == rhs.artworkData &&
               lhs.title == rhs.title &&
               lhs.artist == rhs.artist &&
               lhs.album == rhs.album &&
               lhs.sampleRate == rhs.sampleRate &&
               lhs.bitDepth == rhs.bitDepth &&
               lhs.bitrate == rhs.bitrate &&
               lhs.codec == rhs.codec
    }

    // MARK: - Audio Quality Badge

    /// Pseudo-extension used to classify fidelity. Local files use the real
    /// extension; remote/Tidal tracks fall back to the stored codec.
    private var qualityExtension: String {
        if isRemote, let codec = codec, !codec.isEmpty {
            return codec.lowercased()
        }
        return fileURL.pathExtension
    }

    var qualityTier: QualityTier {
        AudioQuality.tier(ext: qualityExtension, sampleRate: sampleRate, bitDepth: bitDepth, bitrate: bitrate)
    }

    /// Sample rate in kHz, trimmed (44100 -> "44.1", 96000 -> "96").
    private var sampleRateKHz: String? {
        guard let sr = sampleRate, sr > 0 else { return nil }
        let khz = Double(sr) / 1000.0
        return khz == khz.rounded()
            ? String(Int(khz))
            : String(format: "%.1f", khz)
    }

    /// Short label shown inside the coloured pill.
    var qualityBadgeLabel: String {
        switch qualityTier {
        case .hiRes: return "Hi-Res"
        case .lossless: return "Lossless"
        case .lossy:
            if let br = bitrate, br > 0 { return "\(br)" }
            return codec ?? fileURL.pathExtension.uppercased()
        case .unknown:
            return codec ?? fileURL.pathExtension.uppercased()
        }
    }

    /// Small spec line under the pill (e.g. "FLAC 24/96", "MP3"). nil when unknown.
    var qualityDetailLabel: String? {
        let name = codec ?? AudioQuality.codec(forExtension: fileURL.pathExtension)
        switch qualityTier {
        case .hiRes, .lossless:
            guard let name = name else { return nil }
            if let depth = bitDepth, let khz = sampleRateKHz {
                return "\(name) \(depth)/\(khz)"
            }
            if let khz = sampleRateKHz { return "\(name) \(khz)" }
            return name
        case .lossy:
            return name
        case .unknown:
            return nil
        }
    }
}
