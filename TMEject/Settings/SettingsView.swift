import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, advanced, about

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:  return "General"
        case .advanced: return "Advanced"
        case .about:    return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general:  return "gearshape"
        case .advanced: return "wrench.and.screwdriver"
        case .about:    return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var tab: SettingsTab

    init(coordinator: AppCoordinator, initialTab: SettingsTab = .general) {
        self.coordinator = coordinator
        self._tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { t in
                    TabButton(tab: t, selected: tab == t) {
                        UIActionLogger.tabSelected(t.label)
                        tab = t
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            Divider()
            Group {
                switch tab {
                case .general:  GeneralTab(coordinator: coordinator)
                case .advanced: AdvancedTab(coordinator: coordinator)
                case .about:    AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 520, height: 400)
    }
}

private struct TabButton: View {
    let tab: SettingsTab
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 18))
                Text(tab.label)
                    .font(.caption)
            }
            .frame(width: 72, height: 52)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
    }
}
