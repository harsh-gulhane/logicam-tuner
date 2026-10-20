import SwiftUI

/// Recent periods of camera use by other apps, to compare how each app configures the camera.
struct SessionsView: View {
    @ObservedObject var monitor: LiveMonitor

    var body: some View {
        GroupBox("Recent camera use") {
            VStack(alignment: .leading, spacing: 6) {
                if let live = monitor.live, let names = live.appNames {
                    Label("Now: \(names)\(live.appsAreGuess ? "?" : "") · \(live.camera.name) · \(live.resolution) · \(Int(live.configuredFrameRate.rounded())) fps",
                          systemImage: "record.circle").foregroundStyle(.green)
                }
                if monitor.sessions.isEmpty {
                    Text("Each time an app such as Meet, WhatsApp or FaceTime uses the camera, its resolution and frame rate are listed here.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(monitor.sessions.prefix(10)) { session in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(session.app + (session.appIsGuess && session.app != "Unknown app" ? "?" : "")).fontWeight(.medium)
                            Spacer()
                            Text(session.startedAt, format: .dateTime.day().month().hour().minute())
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(summary(session)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                if !monitor.sessions.isEmpty {
                    Button("Clear") { monitor.clearSessions() }.buttonStyle(.link).font(.caption)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summary(_ s: CameraSession) -> String {
        var parts = [s.camera, "\(s.resolution) · \(Int(s.configuredFrameRate.rounded())) fps"].compactMap { $0 }
        if let measured = s.averageMeasuredFrameRate { parts.append(String(format: "%.1f measured", measured)) }
        parts.append(s.pixelFormat)
        if let previous = s.upgradedFrom { parts.append("fixed from \(previous)") }
        let minutes = Int(s.duration / 60)
        parts.append(minutes > 0 ? "\(minutes) min" : "\(Int(s.duration)) s")
        return parts.joined(separator: " · ")
    }
}
