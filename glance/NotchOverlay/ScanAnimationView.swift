//
//  ScanAnimationView.swift
//  glance
//
//  Lock-screen scan animation. Formerly played bundled mp4s; now renders the vector
//  Face ID–style glyph (see FaceIDGlyphView), which plays once per state and holds
//  its resolved frame just like the videos did.
//

import SwiftUI

/// Which state the overlay is showing. `.idle` doubles as the "searching" state —
/// the overlay's breathing pulse is layered on top while scanning.
enum ScanMedia: Equatable {
    case idle
    case success
    case failure
}

struct ScanAnimationView: View {
    let media: ScanMedia

    var body: some View {
        FaceIDGlyphView(media: media, color: GlanceTheme.textPrimary)
    }
}
