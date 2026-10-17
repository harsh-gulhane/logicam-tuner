import CamDialKit
import SwiftUI

/// Groups controls the way people think about a webcam rather than by UVC unit.
enum ControlSection: String, CaseIterable, Identifiable {
    case exposure = "Exposure"
    case focus = "Focus"
    case whiteBalance = "White balance"
    case image = "Image"
    case framing = "Framing"
    case other = "Other"

    var id: String { rawValue }

    static func of(_ id: String) -> ControlSection {
        switch id {
        case "exposure_mode", "exposure_time", "gain", "exposure_priority", "backlight_compensation", "iris": .exposure
        case "focus_auto", "focus": .focus
        case "white_balance_auto", "white_balance": .whiteBalance
        case "brightness", "contrast", "contrast_auto", "saturation", "sharpness", "gamma", "hue", "hue_auto": .image
        case "zoom", "pan", "tilt", "roll": .framing
        default: .other
        }
    }
}

struct ControlRow: View {
    let state: ControlState
    let onChange: (Int) -> Void
    @State private var draft: Double?

    private var definition: ControlDefinition { state.control.definition }

    var body: some View {
        switch definition.kind {
        case .toggle:
            Toggle(definition.name, isOn: Binding(get: { state.current != 0 }, set: { onChange($0 ? 1 : 0) }))
                .disabled(!state.isWritable)
        case .choice:
            Picker(definition.name, selection: Binding(get: { state.current }, set: { onChange($0) })) {
                ForEach(state.choices, id: \.value) { Text($0.label).tag($0.value) }
            }
            .disabled(!state.isWritable)
        case .range:
            rangeRow
        }
    }

    @ViewBuilder private var rangeRow: some View {
        if let lo = state.minimum, let hi = state.maximum, hi > lo {
            let step = Double(max(state.resolution ?? 1, 1))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(definition.name)
                    if state.lockedByAutomaticMode { Text("Auto").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Text(display(Int(draft ?? Double(state.current)))).monospacedDigit().foregroundStyle(.secondary)
                    if let def = state.defaultValue, def != state.current, state.isWritable {
                        Button { onChange(def) } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.borderless).help("Reset to \(display(def))")
                    }
                }
                Slider(value: Binding(get: { draft ?? Double(state.current) }, set: { value in
                    draft = value
                    onChange(Int(value.rounded()))
                }), in: Double(lo)...Double(hi), step: step) { editing in
                    if !editing { draft = nil }
                }
                .disabled(!state.isWritable)
            }
        } else {
            LabeledContent(definition.name, value: display(state.current))
        }
    }

    /// Pan/tilt are arc-seconds and zoom is a percentage-like magnification on most cameras.
    private func display(_ value: Int) -> String {
        switch definition.id {
        case "pan", "tilt": String(format: "%.0f°", Double(value) / 3600)
        case "white_balance": "\(value) K"
        case "zoom": String(format: "%.1f×", Double(value) / 100)
        default: "\(value)"
        }
    }
}
