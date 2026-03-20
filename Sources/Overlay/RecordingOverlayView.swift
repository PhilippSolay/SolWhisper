import SwiftUI

struct RecordingOverlayView: View {
    @ObservedObject var transcriptionController: TranscriptionController
    let onStop: () -> Void
    let onCancel: () -> Void

    @State private var wavePhase: Double = 0

    var body: some View {
        ZStack {
            // Background
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.96))
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 8)

            VStack(spacing: 0) {
                // Waveform / transcript area
                ZStack {
                    if transcriptionController.liveTranscript.isEmpty {
                        WaveformView(level: transcriptionController.audioLevel, phase: wavePhase)
                            .padding(.horizontal, 24)
                    } else {
                        Text(transcriptionController.liveTranscript)
                            .font(.system(size: 15, weight: .regular, design: .default))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(2)
                            .padding(.horizontal, 24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom bar
                HStack(spacing: 0) {
                    // Mic + device name
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.5))
                        Text("Default")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }

                    Spacer()

                    // Stop button
                    HStack(spacing: 4) {
                        Text("Stop")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        KeyBadge(keys: ["⌥", "⌘", "R"])
                    }
                    .onTapGesture { onStop() }
                    .padding(.trailing, 16)

                    // Cancel button
                    HStack(spacing: 4) {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        KeyBadge(keys: ["esc"])
                    }
                    .onTapGesture { onCancel() }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
                .padding(.top, 4)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                wavePhase = .pi * 2
            }
        }
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let level: Float
    let phase: Double

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                let amplitude: CGFloat = max(4, CGFloat(level) * 24)
                let midY = size.height / 2
                let width = size.width
                let frequency: Double = 3.0

                // Draw dotted wave line
                var path = Path()
                let segments = 80
                let segmentWidth = width / CGFloat(segments)

                for i in 0...segments {
                    let x = CGFloat(i) * segmentWidth
                    let progress = Double(i) / Double(segments)
                    let y = midY + amplitude * CGFloat(sin(progress * .pi * 2 * frequency + phase))

                    if i == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }

                context.stroke(
                    path,
                    with: .color(.white.opacity(0.35)),
                    style: StrokeStyle(
                        lineWidth: 1.5,
                        dash: [3, 5]
                    )
                )
            }
        }
        .frame(height: 40)
    }
}

// MARK: - Key Badge

struct KeyBadge: View {
    let keys: [String]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.white.opacity(0.12))
                    )
            }
        }
    }
}
