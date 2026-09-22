import IslandKit
import SwiftUI

struct IslandGenericCompact: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject var islandCenter = IslandCenter.shared
    let item: IslandItem

    var body: some View {
        Group {
            if item.activity.actions.isEmpty {
                row
            } else {
                Button {
                    if let action = item.activity.actions.first {
                        islandCenter.perform(action, on: item)
                    }
                } label: {
                    row
                }
                .buttonStyle(.plain)
            }
        }
        .onHover { hovering in
            if hovering {
                islandCenter.noteExpanded(item)
            }
        }
    }

    private var row: some View {
        HStack(spacing: 0) {
                HStack(spacing: 6) {
                    leadingIcon
                    Text(item.activity.compact.title)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.leading, 8)
                .frame(width: 160, alignment: .leading)

                Rectangle()
                    .fill(.black)
                    .frame(width: vm.closedNotchSize.width + 10)

                HStack(spacing: 6) {
                    if let progress = item.activity.compact.progress {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .frame(width: 36)
                    }
                    if let trailing = item.activity.compact.trailingText {
                        Text(trailing)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                .padding(.trailing, 8)
                .frame(width: 88, alignment: .trailing)
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let symbol = item.activity.compact.symbolName {
            Image(systemName: symbol)
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
        } else if let icon = islandCenter.icon(for: item.clientId) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 16, height: 16)
        }
    }
}

struct IslandInlineHUDHost: View {
    let item: IslandItem
    @Binding var hoverAnimation: Bool
    @Binding var gestureProgress: CGFloat
    @State private var type: SneakContentType = .volume
    @State private var value: CGFloat = 0
    @State private var icon: String = ""

    var body: some View {
        InlineHUD(
            type: $type,
            value: $value,
            icon: $icon,
            hoverAnimation: $hoverAnimation,
            gestureProgress: $gestureProgress
        )
        .onAppear(perform: sync)
        .onChange(of: item) { _, _ in sync() }
    }

    private func sync() {
        guard case .hud(let hudType, let hudValue, let hudIcon) = item.builtin else { return }
        type = hudType
        value = hudValue
        icon = hudIcon
    }
}

struct IslandStandardHUDHost: View {
    @EnvironmentObject var vm: BoringViewModel
    let item: IslandItem
    @State private var type: SneakContentType = .volume
    @State private var value: CGFloat = 0
    @State private var icon: String = ""

    var body: some View {
        SystemEventIndicatorModifier(
            eventType: $type,
            value: $value,
            icon: $icon,
            sendEventBack: { newValue in
                switch type {
                case .volume:
                    VolumeManager.shared.setAbsolute(Float32(newValue))
                case .brightness:
                    BrightnessManager.shared.setAbsolute(value: Float32(newValue))
                default:
                    break
                }
            }
        )
        .padding(.bottom, 10)
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .onAppear(perform: sync)
        .onChange(of: item) { _, _ in sync() }
    }

    private func sync() {
        guard case .hud(let hudType, let hudValue, let hudIcon) = item.builtin else { return }
        type = hudType
        value = hudValue
        icon = hudIcon
    }
}

struct IslandOpenHUDHost: View {
    let item: IslandItem
    @State private var type: SneakContentType = .volume
    @State private var value: CGFloat = 0
    @State private var icon: String = ""

    var body: some View {
        OpenNotchHUD(type: $type, value: $value, icon: $icon)
            .onAppear(perform: sync)
            .onChange(of: item) { _, _ in sync() }
    }

    private func sync() {
        guard case .hud(let hudType, let hudValue, let hudIcon) = item.builtin else { return }
        type = hudType
        value = hudValue
        icon = hudIcon
    }
}
