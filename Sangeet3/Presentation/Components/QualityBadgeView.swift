//
//  QualityBadgeView.swift
//  Sangeet3
//
//  Audiophile fidelity badge: gold "Hi-Res", accent "Lossless",
//  muted bitrate for lossy, with an optional spec line ("FLAC 24/96").
//
//  - full (default): pill stacked above the spec line (lists, big player)
//  - compact: pill + spec on a single row (mini dock)
//

import SwiftUI

struct QualityBadgeView: View {
    let track: Track
    var compact: Bool = false

    private var tier: QualityTier { track.qualityTier }

    private var foreground: Color {
        switch tier {
        case .hiRes:    return SangeetTheme.hiResGold
        case .lossless: return SangeetTheme.primary
        case .lossy:    return SangeetTheme.textSecondary
        case .unknown:  return SangeetTheme.textSecondary
        }
    }

    private var background: Color {
        switch tier {
        case .hiRes:    return SangeetTheme.hiResGold.opacity(0.16)
        case .lossless: return SangeetTheme.primary.opacity(0.16)
        case .lossy:    return SangeetTheme.surfaceElevated
        case .unknown:  return SangeetTheme.surfaceElevated
        }
    }

    private var pill: some View {
        HStack(spacing: 3) {
            if tier == .hiRes {
                Image(systemName: "sparkles")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(track.qualityBadgeLabel)
                .font(.caption.bold())
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var detail: some View {
        if let detail = track.qualityDetailLabel {
            Text(detail)
                .font(.caption2)
                .foregroundStyle(SangeetTheme.textMuted)
                .lineLimit(1)
        }
    }

    var body: some View {
        if track.qualityBadgeLabel.isEmpty {
            EmptyView()
        } else if compact {
            HStack(spacing: 6) {
                pill
                detail
            }
        } else {
            VStack(spacing: 2) {
                pill
                detail
            }
        }
    }
}
