import SwiftUI

struct RecordingOverlayView: View {
    @ObservedObject var transcriptionController: TranscriptionController
    let onStop: () -> Void
    let onCancel: () -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            // Glass background — frosted blur that adapts to system appearance
            Capsule()
                .fill(.ultraThinMaterial)
            Capsule()
                .fill(Color.black.opacity(0.25))
            Capsule()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)

            VStack(spacing: 0) {
                // Waveform / transcript area
                ZStack {
                    if transcriptionController.liveTranscript.isEmpty {
                        WaveformView(level: transcriptionController.audioLevel)
                            .padding(.horizontal, 32)
                    } else {
                        Text(transcriptionController.liveTranscript)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(2)
                            .padding(.horizontal, 32)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Bottom bar — hidden until hover
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.5))
                        Text("Default")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Text("Stop")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        KeyBadge(keys: hotkeyBadgeKeys)
                    }
                    .onTapGesture { onStop() }
                    .padding(.trailing, 14)

                    HStack(spacing: 4) {
                        Text("Cancel")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                        KeyBadge(keys: ["esc"])
                    }
                    .onTapGesture { onCancel() }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
                .padding(.top, 2)
                .opacity(isHovering ? 1 : 0)
                .animation(.easeInOut(duration: 0.18), value: isHovering)
            }
        }
        .onHover { hovering in
            isHovering = hovering
        }
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 8)
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

    @State private var phase1: Double = 0
    @State private var phase2: Double = 0
    @State private var phase3: Double = 0
    @State private var smoothedLevel: Double = 0

    var body: some View {
        Canvas { context, size in
            drawWave(context: context, size: size,
                     phase: phase1, frequency: 2.5,
                     amplitudeScale: 1.0, opacity: 0.5, lineWidth: 1.5)
            drawWave(context: context, size: size,
                     phase: phase2, frequency: 4.0,
                     amplitudeScale: 0.65, opacity: 0.3, lineWidth: 1.0)
            drawWave(context: context, size: size,
                     phase: phase3, frequency: 6.5,
                     amplitudeScale: 0.35, opacity: 0.2, lineWidth: 0.75)
        }
        .frame(height: 36)
        .onChange(of: level) { newLevel in
            withAnimation(.spring(response: 0.12, dampingFraction: 0.7)) {
                smoothedLevel = Double(newLevel)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) { phase1 = .pi * 2 }
            withAnimation(.linear(duration: 1.9).repeatForever(autoreverses: false)) { phase2 = .pi * 2 }
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase3 = .pi * 2 }
        }
    }

    private func drawWave(context: GraphicsContext, size: CGSize,
                          phase: Double, frequency: Double,
                          amplitudeScale: Double, opacity: Double, lineWidth: CGFloat) {
        let base = smoothedLevel < 0.02 ? 2.5 : CGFloat(smoothedLevel) * 20
        let amp  = base * CGFloat(amplitudeScale)
        let midY = size.height / 2
        var path = Path()
        let segs = 100
        for i in 0...segs {
            let x = size.width * CGFloat(i) / CGFloat(segs)
            let y = midY + amp * CGFloat(sin(Double(i) / Double(segs) * .pi * 2 * frequency + phase))
            i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        context.stroke(path, with: .color(.white.opacity(opacity)),
                       style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [3, 4]))
    }
}

// MARK: - Key Badge

struct KeyBadge: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
            }
        }
    }
}

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
