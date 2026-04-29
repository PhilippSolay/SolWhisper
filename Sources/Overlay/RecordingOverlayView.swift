import SwiftUI

// MARK: - Phase State

@MainActor
final class OverlayPhaseState: ObservableObject {
    enum Phase: Equatable { case circle, pill, listening, paused, processing }
    @Published var phase: Phase = .circle
    var onAccept: (() -> Void)?
    var onCancel: (() -> Void)?
    var onResume: (() -> Void)?
}

// MARK: - Transcript Bubble (live transcript display)

struct TranscriptBubbleView: View {
    @ObservedObject var transcriptionController: TranscriptionController

    static let bubbleWidth:  CGFloat = 460
    static let minHeight:    CGFloat = 50
    static let maxHeight:    CGFloat = 200
    static let cornerRadius: CGFloat = 18

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(transcriptionController.liveTranscript)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(.white.opacity(0.95))
                    .lineSpacing(3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .id("end")
                    .onChange(of: transcriptionController.liveTranscript) { _ in
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("end", anchor: .bottom)
                        }
                    }
            }
        }
        .frame(width: Self.bubbleWidth)
        .frame(minHeight: Self.minHeight, maxHeight: Self.maxHeight)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .fill(Color(white: 0.10, opacity: 0.94))
        )
    }
}

// MARK: - Root overlay view

struct RecordingOverlayView: View {
    @ObservedObject var transcriptionController: TranscriptionController
    @ObservedObject var phaseState: OverlayPhaseState

    @State private var isHovering = false

    // Design sizes
    static let circleSize: CGFloat  = 56
    static let pillWidth:  CGFloat  = 120
    static let pillHeight: CGFloat  = 48
    static let hoverWidth: CGFloat  = 180

    var body: some View {
        ZStack {
            switch phaseState.phase {
            case .circle:
                circlePhase
            case .pill, .listening:
                listeningPhase
            case .paused:
                pausedPhase
            case .processing:
                processingPhase
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: phaseState.phase)
        .onHover { isHovering = $0 }
    }

    // MARK: - 1. Circle phase — mic icon

    private var circlePhase: some View {
        ZStack {
            Circle()
                .fill(Color(white: 0.16))
            Image(systemName: "mic.fill")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(Color(white: 0.65))
        }
        .frame(width: Self.circleSize, height: Self.circleSize)
    }

    // MARK: - 3. Listening phase — waveform + hover actions

    private var listeningPhase: some View {
        ZStack {
            // Dark pill background
            RoundedRectangle(cornerRadius: Self.pillHeight / 2)
                .fill(Color(white: 0.12, opacity: 0.94))

            if isHovering {
                // Hover state: X — waveform — ✓
                HStack(spacing: 0) {
                    // Cancel button (left)
                    Button {
                        phaseState.onCancel?()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 32, height: 32)
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(white: 0.55))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)

                    Spacer(minLength: 2)

                    // Waveform (center, compact)
                    SpectrumWaveformView(bins: transcriptionController.spectrumBins, barCount: 9)
                        .frame(width: 54, height: 26)

                    Spacer(minLength: 2)

                    // Accept button (right)
                    Button {
                        phaseState.onAccept?()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 32, height: 32)
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else {
                // Normal state: waveform only
                SpectrumWaveformView(bins: transcriptionController.spectrumBins, barCount: 13)
                    .frame(width: 80, height: 28)
                    .transition(.opacity)
            }
        }
        .frame(
            width: isHovering ? Self.hoverWidth : Self.pillWidth,
            height: Self.pillHeight
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isHovering)
    }

    // MARK: - 4. Paused phase — pause icon, hover: play + cancel

    private var pausedPhase: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.pillHeight / 2)
                .fill(Color(white: 0.12, opacity: 0.94))

            if isHovering {
                HStack(spacing: 0) {
                    // Cancel (left)
                    Button {
                        phaseState.onCancel?()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.08))
                                .frame(width: 32, height: 32)
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Color(white: 0.55))
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)

                    Spacer()

                    // Resume (right)
                    Button {
                        phaseState.onResume?()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.12))
                                .frame(width: 32, height: 32)
                            Image(systemName: "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            } else {
                // Pause icon
                Image(systemName: "pause.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Color(white: 0.55))
                    .transition(.opacity)
            }
        }
        .frame(
            width: isHovering ? Self.hoverWidth : Self.pillWidth,
            height: Self.pillHeight
        )
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: isHovering)
    }

    // MARK: - 5. Processing phase — animated dots

    private var processingPhase: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.pillHeight / 2)
                .fill(Color(white: 0.12, opacity: 0.94))
            ProcessingDotsView()
                .frame(width: 70, height: 20)
        }
        .frame(width: Self.pillWidth, height: Self.pillHeight)
    }
}

// MARK: - Spectrum Waveform View (real FFT data)

struct SpectrumWaveformView: View {
    let bins: [Float]   // real FFT magnitude bins from AudioEngine
    var barCount: Int = 13

    var body: some View {
        Canvas { ctx, size in
            let n = barCount
            let gap: CGFloat = 2.5
            let totalGap = CGFloat(n - 1) * gap
            let barW = max(2.5, (size.width - totalGap) / CGFloat(n))
            let maxH = size.height
            let binTotal = bins.count

            for i in 0..<n {
                // Map display bar to FFT bin range (center-weighted selection)
                let norm = Double(i) / Double(max(1, n - 1))
                // Pick bins from the lower half of spectrum (speech-relevant freqs)
                let binIdx = min(binTotal - 1, Int(norm * Double(min(binTotal, 20))))
                let mag = binTotal > 0 ? CGFloat(bins[binIdx]) : 0

                // Center-weighted envelope so edges are shorter
                let centerDist = abs(norm - 0.5) * 2.0
                let envelope = CGFloat(1.0 - centerDist * 0.4)

                let h = max(3, min(maxH, mag * envelope * maxH * 1.2 + 3))
                let x = CGFloat(i) * (barW + gap)
                let y = (size.height - h) / 2
                let rect = CGRect(x: x, y: y, width: barW, height: h)
                let path = Path(roundedRect: rect, cornerRadius: barW / 2)

                let opacity = 0.35 + Double(mag) * 0.55
                ctx.fill(path, with: .color(Color.white.opacity(opacity)))
            }
        }
    }
}

// MARK: - Processing Dots

struct ProcessingDotsView: View {
    @State private var phase: Double = 0
    private let dotCount = 6

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { tl in
            Canvas { ctx, size in
                let t = tl.date.timeIntervalSinceReferenceDate
                let dotR: CGFloat = 4
                let spacing = (size.width - CGFloat(dotCount) * dotR * 2) / CGFloat(dotCount - 1)

                for i in 0..<dotCount {
                    let x = CGFloat(i) * (dotR * 2 + spacing) + dotR
                    let y = size.height / 2

                    // Wave animation: each dot pulses with offset
                    let wave = sin(t * 3.5 - Double(i) * 0.7)
                    let opacity = 0.25 + max(0, wave) * 0.65
                    let scale = 0.7 + max(0, wave) * 0.3

                    let r = dotR * CGFloat(scale)
                    let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                    ctx.fill(Path(ellipseIn: rect),
                             with: .color(Color.white.opacity(opacity)))
                }
            }
        }
    }
}

// MARK: - Shared key code helper

func keyCodeToString(_ code: Int) -> String {
    let map: [Int: String] = [
        0:"A",  1:"S",  2:"D",  3:"F",  4:"H",  5:"G",  6:"Z",  7:"X",  8:"C",  9:"V",
        11:"B", 12:"Q", 13:"W", 14:"E", 15:"R", 16:"Y", 17:"T",
        18:"1", 19:"2", 20:"3", 21:"4", 22:"6", 23:"5", 24:"=", 25:"9",
        26:"7", 27:"-", 28:"8", 29:"0", 31:"O", 32:"U", 34:"I", 35:"P",
        37:"L", 38:"J", 40:"K", 45:"N", 46:"M",
        36:"↩", 48:"⇥", 49:"Space", 51:"⌫", 53:"⎋",
        123:"←", 124:"→", 125:"↓", 126:"↑"
    ]
    return map[code] ?? "(\(code))"
}
