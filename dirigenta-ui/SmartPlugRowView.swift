import OSLog
import SwiftUI

struct SmartPlugRowView: View {
    let plug: DirigeraDevice
    @Binding var expandedPlugId: String?
    @Binding var actionError: String?
    var showRoom: Bool = false

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mdns: MDNSResolver

    var body: some View {
        HStack(spacing: 4) {
            Button {
                Task { await togglePlug() }
            } label: {
                Label {
                    Text(plug.displayName)
                } icon: {
                    Image(
                        systemName: plug.isOn
                            ? "poweroutlet.type.f.fill" : "poweroutlet.type.f"
                    )
                    .foregroundStyle(
                        plug.isOn ? Color.orange : Color.primary
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if plug.isReachable == false {
                Text("offline").font(.caption2).foregroundStyle(.orange)
            }

            if showRoom, let roomName = plug.room?.name {
                Text(roomName).font(.caption2).foregroundStyle(.secondary)
            }

            Button {
                expandedPlugId = expandedPlugId == plug.id ? nil : plug.id
            } label: {
                Image(systemName: "gearshape").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                expandedPlugId == plug.id
                    ? Color.accentColor : Color.secondary
            )
            .help("Energy details")

            Button {
                if appState.pinnedDeviceId == plug.id {
                    appState.pinnedDeviceId = nil
                } else {
                    appState.pinnedDeviceId = plug.id
                    appState.pinnedDeviceIsOn = plug.isOn
                }
            } label: {
                Image(
                    systemName: appState.pinnedDeviceId == plug.id
                        ? "pin.fill" : "pin"
                )
                .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                appState.pinnedDeviceId == plug.id
                    ? Color.accentColor : Color.secondary
            )
            .help(
                appState.pinnedDeviceId == plug.id
                    ? "Unpin plug" : "Pin to menu bar"
            )
        }

        if plug.isOn,
            let power = plug.attributes.currentActivePower,
            let amps = plug.attributes.currentAmps
        {
            HStack(spacing: 4) {
                Text(String(format: "%.1f W", power))
                Text("·")
                Text("\(Int((amps * 1000).rounded())) mA")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        if expandedPlugId == plug.id {
            VStack(alignment: .leading, spacing: 2) {
                if let total = plug.attributes.totalEnergyConsumed {
                    LabeledContent(
                        "Total energy",
                        value: "\(Int(total.rounded())) Wh"
                    )
                }
                if let sinceReset = plug.attributes.energyConsumedAtLastReset {
                    LabeledContent(
                        "Since last reset",
                        value: "\(Int(sinceReset.rounded())) Wh"
                    )
                }
                if let raw = plug.attributes.timeOfLastEnergyReset,
                    let formatted = Self.formatResetTime(raw)
                {
                    LabeledContent("Last reset", value: formatted)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.leading, 22)
            .padding(.trailing, 4)
        }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func formatResetTime(_ raw: String) -> String? {
        let date = isoFractional.date(from: raw) ?? isoPlain.date(from: raw)
        return date?.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Actions

    private func togglePlug() async {
        guard let outletId = plug.attributes.outletId,
            let ip = appState.currentHubIP,
            let client = appState.makeClient(ip: ip)
        else { return }
        actionError = nil
        let newState = !plug.isOn
        if let i = appState.devices.firstIndex(where: { $0.id == plug.id }) {
            appState.devices[i].attributes.isOn = newState
        }
        appState.syncPinnedState()
        do {
            try await client.setOutlet(id: outletId, isOn: newState)
            await appState.fetchDevices(ip: ip)
        } catch {
            if let i = appState.devices.firstIndex(where: { $0.id == plug.id })
            {
                appState.devices[i].attributes.isOn = !newState
            }
            actionError = "Failed to toggle \(plug.displayName)"
            Logger.api.error(
                "Plug toggle error: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
