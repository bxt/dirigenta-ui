import SwiftUI
import AppKit

struct LightColorControls: View {
    let light: DirigeraDevice
    let onSetColorTemperature: (Int) -> Void
    let onSetColor: (Double, Double) -> Void   // hue (0–360), saturation (0–1)

    @State private var colorTempValue: Double
    @State private var selectedColor: Color

    init(
        light: DirigeraDevice,
        onSetColorTemperature: @escaping (Int) -> Void,
        onSetColor: @escaping (Double, Double) -> Void
    ) {
        self.light = light
        self.onSetColorTemperature = onSetColorTemperature
        self.onSetColor = onSetColor

        let attrs = light.attributes
        // colorTemperature/Min/Max are in Kelvin. Default to 2700 K (warm white) if unset.
        _colorTempValue = State(initialValue: Double(attrs.colorTemperature ?? 2700))
        _selectedColor = State(initialValue: Color(
            hue:        (attrs.colorHue ?? 30) / 360.0,
            saturation: attrs.colorSaturation ?? 1.0,
            brightness: 1.0
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if light.isColorTemperatureLight {
                colorTemperatureRow
            }
            if light.isColorLight {
                colorRow
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 4)
    }

    // MARK: - Sub-views

    private var colorTemperatureRow: some View {
        // colorTemperatureMin/Max are in Kelvin. The API names them from a Mired
        // perspective (min Mired = max Kelvin = coolest), so numerically min > max.
        // Sort them so the Slider range is always valid.
        let a = Double(light.attributes.colorTemperatureMin ?? 1801)
        let b = Double(light.attributes.colorTemperatureMax ?? 6535)
        let warmK = min(a, b)   // lower Kelvin = warmer
        let coolK = max(a, b)   // higher Kelvin = cooler
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Temperature")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(kelvinLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                // Left = lower Kelvin = warmer
                Image(systemName: "sun.max.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                Slider(value: $colorTempValue, in: warmK...coolK) { editing in
                    if !editing { onSetColorTemperature(Int(colorTempValue)) }
                }
                // Right = higher Kelvin = cooler
                Image(systemName: "snowflake")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
        }
    }

    private var colorRow: some View {
        HStack {
            Text("Color")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            ColorPicker("", selection: $selectedColor, supportsOpacity: false)
                .labelsHidden()
                .onChange(of: selectedColor) { _, _ in applyColor() }
        }
    }

    // MARK: - Helpers

    private var kelvinLabel: String { "\(Int(colorTempValue)) K" }

    private func applyColor() {
        // Extract hue and saturation from the SwiftUI Color via NSColor.
        guard let ns = NSColor(selectedColor).usingColorSpace(.deviceRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        onSetColor(Double(h) * 360.0, Double(s))
    }
}
