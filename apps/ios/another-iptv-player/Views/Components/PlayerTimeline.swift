import SwiftUI

/// Premium, özel yapım video timeline (scrubber).
/// SwiftUI Slider yerine kullanılarak v2 projesindeki o zarif görünümü sağlar.
struct PlayerTimeline: View {
    @Binding var value: Double
    var isSeekable: Bool = true
    var onEditingChanged: (Bool) -> Void
    var onDragValue: ((Double) -> Void)? = nil

    @State private var localValue: Double = 0
    @State private var isDragging: Bool = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let currentDisplayValue = isDragging ? localValue : value
            let barHeight: CGFloat = isDragging ? 6 : 4
            let thumbSize: CGFloat = isDragging ? 20 : 13

            ZStack(alignment: .leading) {
                // 1. Arka plan hattı — iOS native ince + açık ton.
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(height: barHeight)

                // 2. İlerleme fill.
                Capsule()
                    .fill(Color.white.opacity(0.96))
                    .frame(width: max(0, width * CGFloat(currentDisplayValue)), height: barHeight)

                // 3. Thumb — sürüklerken büyür.
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 1.5)
                    .offset(x: (width * CGFloat(currentDisplayValue)) - thumbSize / 2)
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isDragging)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isSeekable else { return }
                        if !isDragging {
                            isDragging = true
                            onEditingChanged(true)
                        }
                        let clampedX = max(0, min(gesture.location.x, width))
                        localValue = Double(clampedX / width)
                        onDragValue?(localValue)
                    }
                    .onEnded { gesture in
                        guard isSeekable else { return }
                        let clampedX = max(0, min(gesture.location.x, width))
                        let finalVal = Double(clampedX / width)
                        value = finalVal
                        isDragging = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 44) // HIG minimum dokunma hedefi; görsel bar ince kalır.
        // Light tick when the scrub grab begins/releases, like the native scrubber.
        .sensoryFeedback(.selection, trigger: isDragging)
    }
}

#Preview {
    ZStack {
        Color.black
        PlayerTimeline(value: .constant(0.42), onEditingChanged: { _ in })
            .padding()
    }
}
