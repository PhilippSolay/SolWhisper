import SwiftUI

struct RecordingOverlayView: View {
    @ObservedObject var transcriptionController: TranscriptionController
    let onStop: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.14).opacity(0.96))
                .shadow(color: .black.opacity(0.5), radius: 20, x: 0, y: 8)

            VStack(spacing: 0) {
                // Waveform / transcript area
                ZStack {
                    if transcriptionController.liveTranscript.isEmpty {
                        WaveformView(level: transcriptionController.audioLevel)
                            .padding(.horizontal, 24)
                    } else {
                        Text(transcriptionController.liveTranscript)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(2)
                            .padding(.horizontal, 24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom bar
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.5))
                        Text("Default")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Text("Stop")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        KeyBadge(keys: hotkeyBadgeKeys)
                    }
                    .onTapGesture { onStop() }
                    .padding(.trailing, 16)

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
    }

    private var hotkeyBadgeKeys: [String] {
        let mask = UserDefaults.standard.integer(forKey: "hotkeyModifierMask")
        let code = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        var keys: [String] = []
        if mask & 1 != 0 { keys.append("⌃") }
        if mask & 2 != 0 { keys.append("⌥") }
        if mask & 4 != 0 { keys.append("⇧") }
        if mask & 8 != 0 { keys.append("⌘") }
        keys.append(keyCodeToString(code))
        return keys.isEmpty ? ["⌥", "⌘", "R"] : keys
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let level: Float

    // Three independent phase states for organic layered look
    @State private var phase1: Double = 0
    @State private var phase2: Double = 0
    @State private var phase3: Double = 0
    @State private var smoothedLevel: Double = 0

    var body: some View {
        Canvas { context, size in
            drawWave(context: context, size: size,
                     phase: phase1, frequency: 2.5,
                     amplitudeScale: 1.0, opacity: 0.45, lineWidth: 1.5)
            drawWave(context: context, size: size,
                     phase: phase2, frequency: 4.0,
                     amplitudeScale: 0.65, opacity: 0.28, lineWidth: 1.0)
            drawWave(context: context, size: size,
                     phase: phase3, frequency: 6.5,
                     amplitudeScale: 0.35, opacity: 0.18, lineWidth: 0.75)
        }
        .frame(height: 44)
        .onChange(of: level) { newLevel in
            withAnimation(.spring(response: 0.12, dampingFraction: 0.7)) {
                smoothedLevel = Double(newLevel)
            }
        }
        .onAppear {
            // Each wave scrolls at a different speed
            withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) {
                phase1 = .pi * 2
            }
            withAnimation(.linear(duration: 1.9).repeatForever(autoreverses: false)) {
                phase2 = .pi * 2
            }
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                phase3 = .pi * 2
            }
        }
    }

    private func drawWave(
        context: GraphicsContext, size: CGSize,
        phase: Double, frequency: Double,
        amplitudeScale: Double, opacity: Double, lineWidth: CGFloat
    ) {
        let baseAmplitude: CGFloat = smoothedLevel < 0.02 ? 2.5 : CGFloat(smoothedLevel) * 22
        let amplitude = baseAmplitude * CGFloat(amplitudeScale)
        let midY = size.height / 2
        let segments = 100

        var path = Path()
        for i in 0...segments {
            let x = size.width * CGFloat(i) / CGFloat(segments)
            let progress = Double(i) / Double(segments)
            let y = midY + amplitude * CGFloat(sin(progress * .pi * 2 * frequency + phase))
            i == 0 ? path.move(to: CGPoint(x: x, y: y))
                   : path.addLine(to: CGPoint(x: x, y: y))
        }

        context.stroke(
            path,
            with: .color(.white.opacity(opacity)),
            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [3, 4])
        )
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
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
            }
        }
    }
}

// shared helper (also used in SettingsView)
func keyCodeToString(_ code: Int) -> String {
    let map: [Int: String] = [
        0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",
        11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",
        18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",
        26:"7",27:"-",28:"8",29:"0",31:"O",32:"U",34:"I",35:"P",
        37:"L",38:"J",40:"K",45:"N",46:"M",
        36:"↩",48:"⇥",49:"Space",51:"⌫",53:"⎋",
        123:"←",124:"→",125:"↓",126:"↑"
    ]
    return map[code] ?? "(\(code))"
}
