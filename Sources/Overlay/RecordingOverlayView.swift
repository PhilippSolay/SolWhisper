import SwiftUI

// MARK: - Overlay root

struct RecordingOverlayView: View {
    @ObservedObject var transcriptionController: TranscriptionController
    let onStop:   () -> Void
    let onCancel: () -> Void

    @State private var isHovering = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            // ── Tahoe GlassEffectContainer (macOS 26+) ───────────────────
            if #available(macOS 26.0, *) {
                GlassEffectContainer {
                    glassContent
                }
            } else {
                // Fallback: rely on NSVisualEffectView behind us
                glassContent
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .onHover { isHovering = $0 }
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever()) { pulse.toggle() } }
    }

    // ── Content inside the glass ─────────────────────────────────────────
    private var glassContent: some View {
        HStack(spacing: 14) {

            // Recording dot
            Circle()
                .fill(Color.red.opacity(pulse ? 0.9 : 0.5))
                .frame(width: 8, height: 8)
                .animation(.easeInOut(duration: 1.1).repeatForever(), value: pulse)

            // Waveform or live transcript
            ZStack {
                if transcriptionController.liveTranscript.isEmpty {
                    WaveformView(level: transcriptionController.audioLevel)
                } else {
                    Text(transcriptionController.liveTranscript)
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.2), value: transcriptionController.liveTranscript.isEmpty)

            // Controls — fade in on hover
            HStack(spacing: 10) {
                ControlButton(label: "Stop", badge: hotkeyLabel, action: onStop)
                ControlButton(label: "Esc", badge: nil, action: onCancel)
            }
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    private var hotkeyLabel: String {
        let mask = UserDefaults.standard.integer(forKey: "hotkeyModifierMask")
        let code = UserDefaults.standard.integer(forKey: "hotkeyKeyCode")
        var s = ""
        if mask & 1 != 0 { s += "⌃" }
        if mask & 2 != 0 { s += "⌥" }
        if mask & 4 != 0 { s += "⇧" }
        if mask & 8 != 0 { s += "⌘" }
        s += keyCodeToString(code)
        return s.isEmpty ? "⌥⌘R" : s
    }
}

// MARK: - Control button

private struct ControlButton: View {
    let label: String
    let badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                if let badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
            }
            .foregroundStyle(.primary.opacity(0.8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Waveform

struct WaveformView: View {
    let level: Float

    @State private var phase1: Double = 0
    @State private var phase2: Double = 0
    @State private var phase3: Double = 0
    @State private var smoothed: Double = 0

    var body: some View {
        Canvas { ctx, size in
            draw(ctx, size, phase: phase1, freq: 2.4, ampScale: 1.00, opacity: 0.55, width: 1.5)
            draw(ctx, size, phase: phase2, freq: 3.8, ampScale: 0.60, opacity: 0.30, width: 1.0)
            draw(ctx, size, phase: phase3, freq: 6.2, ampScale: 0.30, opacity: 0.18, width: 0.7)
        }
        .onChange(of: level) { v in
            withAnimation(.spring(response: 0.1, dampingFraction: 0.65)) { smoothed = Double(v) }
        }
        .onAppear {
            withAnimation(.linear(duration: 2.8).repeatForever(autoreverses: false)) { phase1 = .pi*2 }
            withAnimation(.linear(duration: 1.9).repeatForever(autoreverses: false)) { phase2 = .pi*2 }
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) { phase3 = .pi*2 }
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize,
                      phase: Double, freq: Double,
                      ampScale: Double, opacity: Double, width: CGFloat) {
        let amp  = (smoothed < 0.02 ? 3.0 : smoothed * 18) * ampScale
        let midY = size.height / 2
        var path = Path()
        let n    = 120
        for i in 0...n {
            let x = size.width * Double(i) / Double(n)
            let y = midY + amp * sin(Double(i) / Double(n) * .pi * 2 * freq + phase)
            i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
        }
        ctx.stroke(path, with: .color(.primary.opacity(opacity)),
                   style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [2.5, 4]))
    }
}

// MARK: - Key Badge (used in Settings)

struct KeyBadge: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 5).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
            }
        }
    }
}

// MARK: - Shared key code helper

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
