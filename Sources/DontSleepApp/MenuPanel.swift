import SwiftUI
import DontSleepCore

struct MenuPanel: View {
    let presentation: MenuPresentation
    var setupError: String?
    var onToggle: (Bool) -> Void = { _ in }
    var onSelect: (Mode) -> Void = { _ in }
    var onQuit: () -> Void = {}
    var onSetup: () -> Void = {}
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 11) {
                EyeMark(bolt: presentation.bolt).accessibilityHidden(true)
                Text(presentation.title)
                    .font(.system(size: 14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if presentation.showsSwitch {
                    Toggle("Режим Don’t Sleep", isOn: Binding(get: { presentation.switchOn }, set: onToggle))
                        .toggleStyle(.switch).labelsHidden().controlSize(.regular)
                        .disabled(presentation.operationPending || (!presentation.switchOn && !presentation.allowsModes))
                        .accessibilityValue(presentation.switchOn ? "Включено" : "Выключено")
                        .help(presentation.switchOn ? "Выключить режим и восстановить сон" : "Включить выбранный режим")
                } else {
                    Image(systemName: presentation.badge == .warning ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(presentation.badge == .warning ? Color.orange : Color.red)
                        .accessibilityLabel(presentation.title)
                }
            }.frame(minHeight: 30)
            HStack(spacing: 5) {
                if presentation.onAC {
                    Image(systemName: "bolt.fill").font(.system(size: 11)).accessibilityLabel("Питание от сети")
                }
                Text(presentation.charge).lineLimit(1)
                Spacer(minLength: 8)
                if let remaining = presentation.remaining {
                    Text(remaining).monospacedDigit().lineLimit(1)
                        .accessibilityLabel(remaining)
                }
            }.font(.system(size: 13)).foregroundStyle(.secondary)
            if let banner = presentation.banner { bannerView(banner) }
            if presentation.setupActionAvailable || presentation.setupRequired || presentation.snapshot?.state == .setupRequired {
                Button("Настроить…", action: onSetup)
                    .disabled(presentation.setupBusy)
                    .controlSize(.regular)
                    .help("Установить служебный компонент с системным запросом прав администратора")
                if presentation.setupRequired { Text("Закрытый работающий MacBook оставляйте на открытой поверхности. Не переносите его в сумке.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true) }
            }
            if let setupError {
                Text(setupError).font(.system(size: 13)).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("Режим").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Mode.allCases, id: \.rawValue) { mode in
                    Button { onSelect(mode) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .opacity(presentation.switchOn && presentation.snapshot?.selectedMode == mode ? 1 : 0)
                                .frame(width: 14)
                            Text(mode.title).font(.system(size: 13))
                                .foregroundStyle(presentation.allowsModes ? Color.primary : Color(nsColor: .disabledControlTextColor))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 4).frame(minHeight: 30).contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(!presentation.allowsModes)
                    .accessibilityLabel(mode.title)
                    .accessibilityValue(presentation.switchOn && presentation.snapshot?.selectedMode == mode ? "Выбрано" : "")
                    .help("Включить режим: \(mode.title.lowercased())")
                }
            }
            Divider()
            Button(action: onQuit) {
                HStack {
                    Text(presentation.quitTitle).foregroundStyle(.primary)
                    Spacer()
                    Text("⌘Q").foregroundStyle(.secondary).accessibilityHidden(true)
                }.font(.system(size: 13)).frame(minHeight: 28).contentShape(Rectangle())
            }
            .buttonStyle(.borderless).keyboardShortcut("q", modifiers: .command)
            .accessibilityLabel(presentation.quitTitle)
            .help("Завершить после подтверждённого восстановления сна")
        }
        .padding(16).frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: "ru_RU"))
    }
    private func bannerView(_ banner: StatusBanner) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: banner.severity == .warning ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(banner.severity == .warning ? Color.orange : Color.red)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(banner.title).font(.system(size: 13, weight: .semibold))
                Text(banner.detail).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }.foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background((banner.severity == .warning ? Color.orange : Color.red).opacity(contrast == .increased ? 0.14 : 0.08))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke((banner.severity == .warning ? Color.orange : Color.red).opacity(0.45), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}
