import AppKit
import Combine
import DontSleepCore

/// AppKit owns the menu material. Checkmarked controls in a transparent item
/// allow choosing a mode without dismissing the menu or starting a session.
@MainActor final class NativeStatusMenuController: NSObject, NSMenuDelegate {
    let statusItem: NSStatusItem
    let menu = NSMenu(title: "Don’t Sleep")
    let headerView = NativeMenuHeaderView()
    private let headerItem = NSMenuItem()
    let setupItem = NSMenuItem(title: "Настроить…", action: nil, keyEquivalent: "")
    let openWindowItem = NSMenuItem(title: "Открыть окно…", action: nil, keyEquivalent: "o")
    let quitItem = NSMenuItem(title: "Выйти", action: nil, keyEquivalent: "q")
    let modeGroup = NativeMenuModeGroupView()
    var modeButtons: [NSButton] { modeGroup.buttons }
    private let model: AppModel
    private let onOpenWindow: () -> Void
    private var observation: AnyCancellable?
    private var refreshScheduled = false
    private let badgeView = StatusBadgeImageView()
    private var displayedBolt: Bool?
    private var displayedBadge: StatusBadge?

    init(model: AppModel, onOpenWindow: @escaping () -> Void = {}) {
        self.model = model
        self.onOpenWindow = onOpenWindow
        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
        headerItem.view = headerView
        menu.addItem(headerItem)
        setupItem.target = self
        setupItem.action = #selector(configureService)
        menu.addItem(setupItem)
        menu.addItem(.separator())
        let modesItem = NSMenuItem()
        modesItem.view = modeGroup
        menu.addItem(modesItem)
        modeGroup.onSelect = { [weak self] mode in
            guard let self else { return }
            Task { await self.model.select(mode); self.refresh() }
        }
        menu.addItem(.separator())
        openWindowItem.target = self
        openWindowItem.action = #selector(openWindow)
        openWindowItem.keyEquivalentModifierMask = .command
        menu.addItem(openWindowItem)
        quitItem.target = self
        quitItem.action = #selector(requestQuit)
        quitItem.keyEquivalentModifierMask = .command
        menu.addItem(quitItem)
        statusItem.menu = menu
        if let button = statusItem.button {
            badgeView.frame = NSRect(x: 20, y: 2, width: 9, height: 9)
            badgeView.imageScaling = .scaleProportionallyUpOrDown
            badgeView.autoresizingMask = [.minXMargin, .maxYMargin]
            button.addSubview(badgeView)
        }
        headerView.onToggle = { [weak self] enabled in
            guard let self else { return }
            self.menu.cancelTracking()
            Task { await self.model.toggle(enabled) }
        }
        observation = model.objectWillChange.sink { [weak self] in
            guard let self, !self.refreshScheduled else { return }
            self.refreshScheduled = true
            // Published emits before mutation. Defer one main-actor turn and coalesce the response.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshScheduled = false
                self.refresh()
            }
        }
        refresh()
    }

    deinit {
        observation?.cancel()
        // Explicit actor isolation keeps AppKit cleanup on the main actor.
        Task { @MainActor [statusItem] in NSStatusBar.system.removeStatusItem(statusItem) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        model.setMenuVisible(true, source: .menu)
        refresh()
    }
    func menuDidClose(_ menu: NSMenu) { model.setMenuVisible(false, source: .menu) }

    func refresh() {
        let presentation = model.presentation
        if displayedBolt != presentation.bolt {
            statusItem.button?.image = EyeArtwork.templateImage(bolt: presentation.bolt, compact: true)
            displayedBolt = presentation.bolt
        }
        if displayedBadge != presentation.badge {
            displayedBadge = presentation.badge
            badgeView.isHidden = presentation.badge == .none
            badgeView.image = NSImage(systemSymbolName: presentation.badge == .warning
                ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill", accessibilityDescription: nil)
            badgeView.contentTintColor = presentation.badge == .warning ? .systemOrange : .systemRed
        }
        statusItem.button?.toolTip = "Don’t Sleep — \(presentation.title)"
        statusItem.button?.setAccessibilityLabel("Don’t Sleep, \(presentation.title)")
        let oldSize = headerView.frame.size
        headerView.update(presentation, setupError: model.setupError)
        if oldSize != headerView.frame.size { menu.itemChanged(headerItem) }
        setupItem.isHidden = !(presentation.setupActionAvailable || presentation.setupRequired || presentation.snapshot?.state == .setupRequired)
        setupItem.isEnabled = !presentation.setupBusy
        modeGroup.update(presentation)
        if quitItem.title != presentation.quitTitle { quitItem.title = presentation.quitTitle }
    }

    @objc private func openWindow() {
        menu.cancelTracking()
        onOpenWindow()
    }
    @objc private func requestQuit() { Task { await model.requestQuit() } }
    @objc private func configureService() { Task { await model.installService() } }
}

@MainActor final class NativeMenuModeGroupView: NSView {
    private(set) var buttons: [NSButton] = []
    var onSelect: (Mode) -> Void = { _ in }
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 228))
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel("Режим")
        let title = NSTextField(labelWithString: "Режим")
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 14, y: 4, width: 292, height: 18)
        title.setAccessibilityElement(false)
        addSubview(title)
        for (index, mode) in Mode.allCases.enumerated() {
            let button = MenuModeRowButton(frame: .zero)
            button.title = mode.title
            button.target = self
            button.action = #selector(selectMode(_:))
            button.tag = index
            button.font = .menuFont(ofSize: 13)
            button.frame = NSRect(x: 4, y: 26 + CGFloat(index) * 28, width: 312, height: 28)
            button.setAccessibilityLabel(mode.title)
            buttons.append(button)
            addSubview(button)
        }
        for (button, next) in zip(buttons, buttons.dropFirst()) { button.nextKeyView = next }
        // AppKit exposes each native button cell as AXRadioButton. Let it build
        // the accessibility children instead of substituting the NSButton wrappers.
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ presentation: MenuPresentation) {
        for (mode, button) in zip(Mode.allCases, buttons) {
            let state: NSControl.StateValue = mode == presentation.selectedMode ? .on : .off
            if button.state != state { button.state = state }
            if button.isEnabled != presentation.allowsModes { button.isEnabled = presentation.allowsModes }
            button.toolTip = presentation.switchOn ? "Чтобы изменить режим, сначала выключите переключатель" : nil
        }
    }
    @objc private func selectMode(_ sender: NSButton) {
        guard sender.isEnabled, Mode.allCases.indices.contains(sender.tag) else { return }
        onSelect(Mode.allCases[sender.tag])
    }
}

/// Keeps NSButton's click tracking and single-selection accessibility semantics,
/// while rendering a full-width menu row instead of a circular radio indicator.
/// A normal NSMenuItem would dismiss the menu after each selection.
@MainActor final class MenuModeRowCell: NSButtonCell {
    override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView) -> NSCell.HitResult {
        guard cellFrame.contains(controlView.convert(event.locationInWindow, from: nil)) else { return [] }
        // Radio cells normally hit only their glyph/title. Our visual row is
        // wider, so include its trailing whitespace in native click tracking.
        return isEnabled ? [.contentArea, .trackableArea] : [.contentArea]
    }
}

@MainActor final class MenuModeRowButton: NSButton {
    private var pointerInside = false
    private var hoverArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = MenuModeRowCell(textCell: "")
        setButtonType(.radio)
        isBordered = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }
    override var state: NSControl.StateValue {
        didSet { needsDisplay = true }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
        if let window, window.isVisible {
            pointerInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        } else { pointerInside = false }
        needsDisplay = true
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pointerInside = false
        needsDisplay = true
    }
    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isEnabled && (pointerInside || cell?.isHighlighted == true)
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let foreground: NSColor = !isEnabled ? .disabledControlTextColor
            : (highlighted ? .selectedMenuItemTextColor : .labelColor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.menuFont(ofSize: 13), .foregroundColor: foreground
        ]
        let text = NSAttributedString(string: title, attributes: attributes)
        let height = text.size().height
        text.draw(in: NSRect(x: 30, y: (bounds.height - height) / 2,
                             width: bounds.width - 38, height: height))
        if state == .on {
            let check = NSAttributedString(string: "✓", attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: foreground
            ])
            let size = check.size()
            check.draw(at: NSPoint(x: 10, y: (bounds.height - size.height) / 2))
        }
    }
}

@MainActor final class NativeMenuHeaderView: NSView {
    let toggleControl = NSSwitch()
    let titleLabel = NSTextField(wrappingLabelWithString: "")
    let chargeLabel = NSTextField(labelWithString: "")
    let remainingLabel = NSTextField(labelWithString: "")
    private let eye = NSImageView()
    private let statusSymbol = NSImageView()
    private let warningSymbol = NSImageView()
    private let warningTitle = NSTextField(wrappingLabelWithString: "")
    private let warningDetail = NSTextField(wrappingLabelWithString: "")
    private let setupNote = NSTextField(wrappingLabelWithString: "")
    private let setupErrorLabel = NSTextField(wrappingLabelWithString: "")
    var onToggle: (Bool) -> Void = { _ in }
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 76))
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        chargeLabel.font = .systemFont(ofSize: 12)
        chargeLabel.textColor = .secondaryLabelColor
        remainingLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        remainingLabel.textColor = .secondaryLabelColor
        remainingLabel.alignment = .right
        warningTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        warningDetail.font = .systemFont(ofSize: 12)
        setupNote.font = .systemFont(ofSize: 11)
        setupNote.textColor = .secondaryLabelColor
        setupErrorLabel.font = .systemFont(ofSize: 12)
        toggleControl.controlSize = .small
        toggleControl.target = self
        toggleControl.action = #selector(toggleChanged)
        toggleControl.setAccessibilityLabel("Режим Don’t Sleep")
        for child in [eye, titleLabel, toggleControl, statusSymbol, chargeLabel, remainingLabel,
                      warningSymbol, warningTitle, warningDetail, setupNote, setupErrorLabel] {
            addSubview(child)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ presentation: MenuPresentation, setupError: String?) {
        let padding: CGFloat = 14
        let contentWidth = frame.width - padding * 2
        setText(titleLabel, presentation.title)
        titleLabel.frame = NSRect(x: 48, y: 11, width: contentWidth - 76, height: height(of: titleLabel, width: contentWidth - 76))
        let firstRowHeight = max(26, titleLabel.frame.height)
        eye.image = EyeArtwork.templateImage(bolt: presentation.bolt)
        eye.frame = NSRect(x: padding, y: 11 + (firstRowHeight - 18) / 2, width: 25, height: 18)
        toggleControl.frame = NSRect(x: frame.width - padding - 36, y: 11 + (firstRowHeight - 22) / 2, width: 36, height: 22)
        toggleControl.state = presentation.switchOn ? .on : .off
        toggleControl.isHidden = !presentation.showsSwitch
        toggleControl.isEnabled = !presentation.operationPending && (presentation.switchOn || presentation.allowsModes)
        toggleControl.setAccessibilityValue(presentation.switchOn ? "Включено" : "Выключено")
        toggleControl.toolTip = presentation.switchOn ? "Выключить режим и восстановить сон" : "Включить выбранный режим"
        statusSymbol.isHidden = presentation.showsSwitch
        statusSymbol.frame = NSRect(x: frame.width - padding - 21, y: 11 + (firstRowHeight - 18) / 2, width: 18, height: 18)
        statusSymbol.image = symbol(presentation.badge)
        statusSymbol.contentTintColor = presentation.badge == .warning ? .systemOrange : .systemRed
        var y: CGFloat = 11 + firstRowHeight + 7
        setText(chargeLabel, (presentation.onAC ? "⚡︎ " : "") + presentation.charge)
        setText(remainingLabel, presentation.remaining ?? "")
        chargeLabel.frame = NSRect(x: padding, y: y, width: 125, height: 18)
        remainingLabel.frame = NSRect(x: padding + 125, y: y, width: contentWidth - 125, height: 18)
        y += 18
        let banner = presentation.banner
        warningSymbol.isHidden = banner == nil
        warningTitle.isHidden = banner == nil
        warningDetail.isHidden = banner == nil
        if let banner {
            y += 10
            warningSymbol.image = symbol(banner.severity)
            warningSymbol.contentTintColor = banner.severity == .warning ? .systemOrange : .systemRed
            warningSymbol.frame = NSRect(x: padding, y: y + 1, width: 15, height: 15)
            setText(warningTitle, banner.title)
            setText(warningDetail, banner.detail)
            let textX = padding + 23, textWidth = contentWidth - 23
            warningTitle.frame = NSRect(x: textX, y: y, width: textWidth, height: height(of: warningTitle, width: textWidth))
            y += warningTitle.frame.height + 3
            warningDetail.frame = NSRect(x: textX, y: y, width: textWidth, height: height(of: warningDetail, width: textWidth))
            y += warningDetail.frame.height
        }
        setupNote.isHidden = !presentation.setupRequired
        if presentation.setupRequired {
            y += 9
            setText(setupNote, "Закрытый работающий MacBook оставляйте на открытой поверхности. Не переносите его в сумке.")
            setupNote.frame = NSRect(x: padding, y: y, width: contentWidth, height: height(of: setupNote, width: contentWidth))
            y += setupNote.frame.height
        }
        setupErrorLabel.isHidden = setupError == nil
        if let setupError {
            y += 9
            setText(setupErrorLabel, setupError)
            setupErrorLabel.frame = NSRect(x: padding, y: y, width: contentWidth, height: height(of: setupErrorLabel, width: contentWidth))
            y += setupErrorLabel.frame.height
        }
        setFrameSize(NSSize(width: 320, height: ceil(y + 8)))
    }

    @objc private func toggleChanged() { onToggle(toggleControl.state == .on) }
    private func setText(_ label: NSTextField, _ value: String) {
        if label.stringValue != value { label.stringValue = value }
    }
    private func height(of label: NSTextField, width: CGFloat) -> CGFloat {
        // NSTextField's cell measures the same line wrapping that AppKit will draw.
        ceil(label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000)).height ?? 18)
    }
    private func symbol(_ badge: StatusBadge) -> NSImage? {
        NSImage(systemSymbolName: badge == .warning ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill", accessibilityDescription: nil)
    }
}

private final class StatusBadgeImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
