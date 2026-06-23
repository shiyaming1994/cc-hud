import SwiftUI
import CCHudCore

struct StatusDotView: View {
    let status: SessionStatus
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Theme.statusColor(status))
            .frame(width: 7, height: 7)
            .opacity(status == .dead ? 0.55 : 1)
            .overlay {
                if status == .permission {
                    Circle()
                        .stroke(Theme.permission.opacity(0.55), lineWidth: 2)
                        .scaleEffect(pulse ? 2.1 : 1.0)
                        .opacity(pulse ? 0 : 0.8)
                        .animation(.easeOut(duration: 1.1).repeatForever(autoreverses: false), value: pulse)
                }
            }
            .onAppear { pulse = status == .permission }
            .onChange(of: status) { _, new in pulse = (new == .permission) }
    }
}
