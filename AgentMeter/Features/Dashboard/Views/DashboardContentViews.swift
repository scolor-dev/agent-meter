import SwiftUI

struct MenuBarStatusLabel: View {
    let groups: [MenuBarGroup]
    var now = Date()

    var body: some View {
        if groups.isEmpty {
            UnconnectedMenuBarIndicator()
        } else {
            HStack(spacing: 8) {
                ForEach(groups) { group in
                    MenuBarAgentIndicator(group: group, now: now)
                }
            }
        }
    }
}

private struct UnconnectedMenuBarIndicator: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Circle()
                .fill(.secondary.opacity(0.45))
                .frame(width: 5, height: 5)
        }
        .accessibilityLabel("Agent Meter: nothing to show in the menu bar")
    }
}

private struct MenuBarAgentIndicator: View {
    let group: MenuBarGroup
    let now: Date

    var body: some View {
        HStack(spacing: 4) {
            group.agent.icon
                .resizable()
                .scaledToFit()
                .frame(width: 14, height: 14)

            ForEach(group.entries) { entry in
                MenuBarUsageBar(entry: entry, tint: group.agent.tint, now: now)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let parts = group.entries.compactMap { entry in
            entry.usage.map { "\(entry.item.period.displayName) \($0.usedPercentage)% used" }
        }

        guard !parts.isEmpty else {
            return "\(group.agent.name): no usage data"
        }

        return "\(group.agent.name) usage: \(parts.joined(separator: ", "))"
    }
}

private struct MenuBarUsageBar: View {
    let entry: MenuBarGroup.Entry
    let tint: Color
    let now: Date

    var body: some View {
        HStack(spacing: 3) {
            if entry.style.showsLabel {
                Text(entry.item.period.shortDisplayName)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if entry.style.showsBar {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(tint.opacity(0.18))

                    Capsule()
                        .fill(tint)
                        .frame(width: 38 * fillRatio)
                }
                .frame(width: 38, height: 6)
            }

            if let valueText = entry.style.value.text(for: entry.usage, now: now) {
                Text(valueText)
                    .font(.caption2.monospacedDigit())
            }
        }
    }

    private var fillRatio: Double {
        guard let usage = entry.usage else {
            return 0
        }

        return entry.style.value.showsRemaining ? 1 - usage.usedRatio : usage.usedRatio
    }
}
