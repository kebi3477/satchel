//
//  ScanSoundPlayer.swift
//  glance
//
//  Synthesized feedback sounds for the face scan — no bundled audio files.
//    - tick(progress:): a short "pop" per recognized frame; pitch and loudness rise as the
//      best similarity approaches the match threshold, so it audibly "homes in".
//    - success(): a brighter, longer rising "pop~".
//    - failure(): two low descending pops.
//  Honors GlanceSettings.soundEnabled / soundVolume and follows the system output volume.
//

import AVFoundation

@MainActor
final class ScanSoundPlayer {
    static let shared = ScanSoundPlayer()

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var lastTickAt: Date = .distantPast

    /// Ticks closer together than this are dropped so a 30fps camera doesn't machine-gun.
    private let minimumTickInterval: TimeInterval = 0.17

    private init() {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    private var masterGain: Float {
        let settings = GlanceSettings.shared
        guard settings.soundEnabled else { return 0 }
        return Float(settings.soundVolume) / Float(GlanceSettings.soundVolumeRange.upperBound)
    }

    // MARK: - Public cues

    /// `progress` 0…1 — how close the current face is to unlocking.
    func tick(progress: Double) {
        let now = Date()
        guard now.timeIntervalSince(lastTickAt) >= minimumTickInterval else { return }
        lastTickAt = now
        let p = min(max(progress, 0), 1)
        play([
            Tone(start: 0, duration: 0.07,
                 fromHz: 520 + 600 * p, toHz: (520 + 600 * p) * 0.82,
                 gain: 0.18 + 0.62 * p),
        ])
    }

    func success() {
        play([
            Tone(start: 0, duration: 0.09, fromHz: 1100, toHz: 980, gain: 0.8),
            Tone(start: 0.1, duration: 0.32, fromHz: 1320, toHz: 1760, gain: 0.9),
        ])
    }

    func failure() {
        play([
            Tone(start: 0, duration: 0.1, fromHz: 330, toHz: 290, gain: 0.7),
            Tone(start: 0.14, duration: 0.14, fromHz: 260, toHz: 210, gain: 0.7),
        ])
    }

    // MARK: - Synthesis

    private struct Tone {
        let start: Double
        let duration: Double
        let fromHz: Double
        let toHz: Double
        let gain: Double
    }

    private func play(_ tones: [Tone]) {
        let master = masterGain
        guard master > 0, let buffer = render(tones, master: master) else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func render(_ tones: [Tone], master: Float) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let total = (tones.map { $0.start + $0.duration }.max() ?? 0) + 0.02
        let frameCount = AVAudioFrameCount(total * rate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount
        for i in 0..<Int(frameCount) { samples[i] = 0 }

        for tone in tones {
            let startFrame = Int(tone.start * rate)
            let length = Int(tone.duration * rate)
            var phase = 0.0
            for n in 0..<length {
                let t = Double(n) / Double(length)
                // Exponential pitch glide gives the bubbly "pop" character.
                let hz = tone.fromHz * pow(tone.toHz / tone.fromHz, t)
                phase += 2 * .pi * hz / rate
                // 4ms attack, then exponential decay.
                let attack = min(1, Double(n) / (0.004 * rate))
                let envelope = attack * exp(-4.5 * t)
                // A touch of 2nd harmonic so it sounds rounder than a pure sine.
                let wave = sin(phase) + 0.18 * sin(2 * phase)
                let index = startFrame + n
                guard index < Int(frameCount) else { break }
                samples[index] += Float(wave * envelope * tone.gain * 0.35) * master
            }
        }
        return buffer
    }
}
