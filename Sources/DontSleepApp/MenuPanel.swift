import SwiftUI
import DontSleepCore

/// The launch window uses standard macOS controls; the status menu is owned by AppKit.
struct MenuPanel: View {
    let presentation: MenuPresentation
    var setupError: String?
    var onToggle: (Bool) -> Void = { _ in }
    var onSelect: (Mode) -> Void = { _ in }
    var onQuit: () -> Void = {}
    var onSetup: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusBlock

            if let banner = presentation.banner {
                GroupBox {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: banner.severity == .warning ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(banner.severity == .warning ? Color.orange : Color.red)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(banner.title).fontWeight(.semibold)
                            Text(banner.detail).font(.callout)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.padding(4)
                }.accessibilityElement(children: .combine)
            }
            if presentation.setupActionAvailable || presentation.setupRequired || presentation.snapshot?.state == .setupRequired {
                Button("Настроить…", action: onSetup)
                    .disabled(presentation.setupBusy)
                    .help("Установить служебный компонент с системным запросом прав администратора")
                if presentation.setupRequired {
                    Text("Закрытый работающий MacBook оставляйте на открытой поверхности. Не переносите его в сумке.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let setupError {
                Text(setupError).fixedSize(horizontal: false, vertical: true)
            }

            GroupBox("Режим") {
                Picker("Режим", selection: Binding(get: { presentation.selectedMode }, set: onSelect)) {
                    ForEach(Mode.allCases, id: \.rawValue) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(!presentation.allowsModes)
                .help(presentation.switchOn ? "Чтобы изменить режим, сначала выключите переключатель" : "Выберите режим, затем включите переключатель")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
            HStack {
                Spacer()
                Button(presentation.quitTitle, action: onQuit)
                    .keyboardShortcut("q", modifiers: .command)
                    .help("Завершить после подтверждённого восстановления сна")
            }
        }
        .padding(20).frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.locale, Locale(identifier: "ru_RU"))
    }

    @ViewBuilder private var statusBlock: some View {
        if #available(macOS 26.0, *) {
            statusContent
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
        } else {
            statusContent
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var statusContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                EyeMark(bolt: presentation.bolt).accessibilityHidden(true)
                Text(presentation.title).font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if presentation.showsSwitch {
                    Toggle("Режим Don’t Sleep", isOn: Binding(get: { presentation.switchOn }, set: onToggle))
                        .toggleStyle(.switch).labelsHidden()
                        .disabled(presentation.operationPending || (!presentation.switchOn && !presentation.allowsModes))
                        .accessibilityValue(presentation.switchOn ? "Включено" : "Выключено")
                        .help(presentation.switchOn ? "Выключить режим и восстановить сон" : "Включить выбранный режим")
                }
            }
            HStack(spacing: 5) {
                if presentation.onAC {
                    Image(systemName: "bolt.fill").accessibilityLabel("Питание от сети")
                }
                Text(presentation.charge).lineLimit(1)
                Spacer(minLength: 8)
                if let remaining = presentation.remaining {
                    Text(remaining).monospacedDigit().lineLimit(1)
                        .accessibilityLabel(remaining)
                }
            }.foregroundStyle(.secondary)
        }
        .padding(12)
    }
}
