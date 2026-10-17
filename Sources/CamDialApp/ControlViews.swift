import CamDialKit
import SwiftUI

/// Groups controls the way people think about a webcam rather than by UVC unit.
/// Exposure and white-balance modes are drawn by their own pickers, so they have no section.
enum ControlSection: String, CaseIterable, Identifiable {
    case exposure = "Exposure"
    case whiteBalance = "White balance"
    case focus = "Focus"
    case image = "Image"
    case framing = "Framing"
    case other = "Other"

    var id: String { rawValue }

    static func of(_ id: String) -> ControlSection? {
        switch id {
        case "exposure_mode", "white_balance_auto": nil
        case "exposure_time", "gain", "exposure_priority", "backlight_compensation", "iris", "power_line_frequency": .exposure
        case "focus_auto", "focus": .focus
        case "white_balance": .whiteBalance
        case "brightness", "contrast", "contrast_auto", "saturation", "sharpness", "gamma", "hue", "hue_auto": .image
        case "zoom", "pan", "tilt", "roll": .framing
        default: .other
        }
    }
}

struct ControlRow: View {
    let state: ControlState
    var editable: Bool
    /// Shown instead of the value's own "Auto" hint, e.g. "Smart".
    var ownerLabel: String?
    let onChange: (Int) -> Void
    @State private var draft: Double?

    private var definition: ControlDefinition { state.control.definition }

    var body: some View {
        switch definition.kind {
        case .toggle:
            toggle
        case .choice:
            Picker(definition.name, selection: Binding(get: { state.current }, set: { onChange($0) })) {
                ForEach(state.choices, id: \.value) { Text($0.label).tag($0.value) }
            }
            .disabled(!editable)
        case .range:
            // Some cameras expose on/off features (HDR on the StreamCam) as a 0...1 range.
            if state.minimum == 0, state.maximum == 1 { toggle } else { rangeRow }
        }
    }

    private var toggle: some View {
        Toggle(definition.name, isOn: Binding(get: { state.current != 0 }, set: { onChange($0 ? 1 : 0) }))
            .disabled(!editable)
    }

    /// Shutter speeds span three orders of magnitude, so that slider moves in stops.
    private var logarithmic: Bool { definition.id == "exposure_time" }

    private func position(_ value: Int) -> Double { logarithmic ? log2(Double(max(value, 1))) : Double(value) }
    private func value(at position: Double) -> Int { Int((logarithmic ? pow(2, position) : position).rounded()) }

    @ViewBuilder private var rangeRow: some View {
        if let lo = state.minimum, let hi = state.maximum, hi > lo {
            let step = logarithmic ? 1.0 / 6 : Double(max(state.resolution ?? 1, 1))
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(definition.name)
                    if let hint = ownerLabel ?? (state.lockedByAutomaticMode ? "Auto" : nil) {
                        Text(hint).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ControlCatalog.format(definition.id, draft.map { value(at: $0) } ?? state.current))
                        .monospacedDigit().foregroundStyle(.secondary)
                    if let def = state.defaultValue, def != state.current, editable {
                        Button { onChange(def) } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.borderless).help("Reset to \(ControlCatalog.format(definition.id, def))")
                    }
                }
                Slider(value: Binding(get: { draft ?? position(state.current) }, set: { position in
                    draft = position
                    onChange(min(max(value(at: position), lo), hi))
                }), in: position(lo)...position(hi), step: step) { editing in
                    if !editing { draft = nil }
                }
                .disabled(!editable)
            }
        } else {
            LabeledContent(definition.name, value: ControlCatalog.format(definition.id, state.current))
        }
    }
}

/// A labelled slider for a Smart Auto preference.
struct PreferenceSlider: View {
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let onChange: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: onChange), in: range, step: step)
        }
    }
}
