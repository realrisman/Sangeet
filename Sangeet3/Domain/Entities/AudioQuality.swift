//
//  AudioQuality.swift
//  Sangeet3
//
//  Audio fidelity classification (Hi-Res / Lossless / Lossy) for audiophile badges.
//
//  Sample rate, bit depth and bitrate come from the BASS decode stream
//  (see MetadataExtractor). Codec / lossless is derived from the file
//  extension: there is no FLAC plugin dylib and BASS decodes most formats
//  through CoreAudio, so BASS_CHANNELINFO.ctype is not a reliable codec
//  signal on macOS. The `m4a` container is ambiguous (ALAC vs AAC) and is
//  resolved with a bit-depth / bitrate heuristic.
//

import Foundation

/// Fidelity tier used to colour and label the quality badge.
enum QualityTier {
    case hiRes      // lossless AND (sampleRate > 48 kHz OR bitDepth > 16)
    case lossless   // lossless at CD quality (16-bit, <= 48 kHz)
    case lossy      // compressed (MP3, AAC, OGG, Opus...)
    case unknown    // no signal yet (not extracted / unreadable)
}

/// Pure, I/O-free fidelity logic shared by local files and Tidal streams.
enum AudioQuality {

    /// Extensions that are always lossless.
    static let losslessExtensions: Set<String> = [
        "flac", "wav", "aif", "aiff", "alac", "ape", "wv", "tak", "dsf", "dff"
    ]

    /// Extensions that are always lossy.
    static let lossyExtensions: Set<String> = [
        "mp3", "aac", "ogg", "oga", "opus", "wma"
    ]

    /// Normalised, human-facing codec label from a file extension.
    static func codec(forExtension ext: String) -> String? {
        let e = ext.lowercased()
        guard !e.isEmpty else { return nil }
        switch e {
        case "m4a", "mp4": return "AAC"   // refined to ALAC by `isLossless` heuristic
        case "aif", "aiff": return "AIFF"
        case "oga", "ogg": return "OGG"
        default: return e.uppercased()
        }
    }

    /// Whether a track is lossless. Returns nil when unknown.
    /// `m4a`/`mp4` is ambiguous: treated as lossless (ALAC) only when it
    /// carries a real bit depth and a bitrate too high to be AAC.
    static func isLossless(ext: String, bitDepth: Int?, bitrate: Int?) -> Bool? {
        let e = ext.lowercased()
        if losslessExtensions.contains(e) { return true }
        if lossyExtensions.contains(e) { return false }
        if e == "m4a" || e == "mp4" {
            guard let depth = bitDepth, depth >= 16 else { return false }
            return bitrate == nil || bitrate! > 400
        }
        return nil
    }

    /// Classify a track into a fidelity tier.
    static func tier(ext: String, sampleRate: Int?, bitDepth: Int?, bitrate: Int?) -> QualityTier {
        guard let lossless = isLossless(ext: ext, bitDepth: bitDepth, bitrate: bitrate) else {
            return .unknown
        }
        if lossless {
            let hiResRate = (sampleRate ?? 0) > 48_000
            let hiResDepth = (bitDepth ?? 0) > 16
            return (hiResRate || hiResDepth) ? .hiRes : .lossless
        }
        return .lossy
    }

    /// Audio characteristics implied by a Tidal stream quality tier.
    /// The app requests `.LOSSLESS` by default; values mirror Tidal's spec.
    static func info(forTidalQuality raw: String?) -> (codec: String, sampleRate: Int?, bitDepth: Int?, bitrate: Int?) {
        switch (raw ?? "LOSSLESS").uppercased() {
        case "HI_RES", "HI_RES_LOSSLESS", "HIRES_LOSSLESS":
            return ("FLAC", 96_000, 24, nil)
        case "LOSSLESS":
            return ("FLAC", 44_100, 16, nil)
        case "HIGH":
            return ("AAC", 44_100, nil, 320)
        case "LOW":
            return ("AAC", 44_100, nil, 96)
        default:
            return ("FLAC", 44_100, 16, nil)
        }
    }
}
