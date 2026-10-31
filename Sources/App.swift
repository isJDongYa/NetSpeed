import AppKit
import ServiceManagement

@MainActor
final class SpeedStatusView: NSView {
    var download = "—" { didSet { needsDisplay = true } }
    var upload = "—" { didSet { needsDisplay = true } }
    private let horizontalPadding: CGFloat = 5
    private let textFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)

    var requiredWidth: CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: textFont]
        let longestLine = ["↓ " + download, "↑ " + upload].map {
            ($0 as NSString).size(withAttributes: attributes).width
        }.max() ?? 0
        return ceil(longestLine) + horizontalPadding * 2
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: requiredWidth, height: NSStatusBar.system.thickness)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = (superview as? NSStatusBarButton)?.isHighlighted ?? false
        let color: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: color
        ]
        let lines = ["↓ " + download, "↑ " + upload]
        let lineHeight: CGFloat = 11
        let top = (bounds.height - lineHeight * 2) / 2
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: horizontalPadding, y: top + CGFloat(index) * lineHeight), withAttributes: attributes)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
func runStatusLayoutChecks(previewPath: String? = nil) {
    let view = SpeedStatusView(frame: NSRect(x: 0, y: 0, width: 1, height: 24))
    let cases = [("0 B/s", "0 B/s"), ("9.99 MB/s", "128 KB/s"), ("0 B/s", "999.9 Mbps")]
    var widths: [CGFloat] = []
    for (download, upload) in cases {
        view.download = download
        view.upload = upload
        widths.append(view.requiredWidth)
    }
    guard widths[0] < widths[1], widths[0] < widths[2] else {
        fputs("FAIL: menu bar width must grow with either line\n", stderr)
        exit(1)
    }
    view.download = "0 B/s"
    view.upload = "0 B/s"
    guard view.requiredWidth == widths[0], view.requiredWidth < 91 else {
        fputs("FAIL: menu bar width must shrink again\n", stderr)
        exit(1)
    }
    print("PASS: adaptive layout; widths = \(widths.map { Int($0) }) pt; shrinks back to \(Int(view.requiredWidth)) pt")

    guard let previewPath else { return }
    let preview = NSImage(size: NSSize(width: 440, height: 228))
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        preview.lockFocusFlipped(true)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 440, height: 228).fill()
        for (index, values) in cases.enumerated() {
            view.download = values.0
            view.upload = values.1
            view.frame.size = NSSize(width: view.requiredWidth, height: 24)
            let y = CGFloat(index) * 72 + 14
            ("\(Int(view.requiredWidth)) pt" as NSString).draw(at: NSPoint(x: 310, y: y + 13),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor])
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: 18, yBy: y)
            transform.scale(by: 2)
            transform.concat()
            NSColor(srgbRed: 0.92, green: 0.94, blue: 0.96, alpha: 1).setFill()
            view.bounds.fill()
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        preview.unlockFocus()
    }
    do {
        let bitmap = NSBitmapImageRep(data: preview.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: previewPath))
    } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let statusView = SpeedStatusView(frame: .zero)
    private let menu = NSMenu()
    private var timer: Timer?
    private var calculator = RateCalculator()
    private var counters: [String: InterfaceCounter] = [:]
    private var names: [String: String] = [:]
    private var tickCount = 0
    private var primary: String?
    private var active: String?
    private var rate: TransferRate?
    private var readError: String?
    private var sleeping = false
    private var downloadRow: NSMenuItem?
    private var uploadRow: NSMenuItem?
    private var connectionRow: NSMenuItem?
    private var preference: String? {
        UserDefaults.standard.string(forKey: "interface")
    }
    private var unit: SpeedUnit {
        SpeedUnit(rawValue: UserDefaults.standard.string(forKey: "unit") ?? "") ?? .bytes
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "NetSpeed"
        statusItem.behavior = []
        if let button = statusItem.button {
            button.title = ""
            statusView.frame = button.bounds
            statusView.autoresizingMask = [.width, .height]
            button.addSubview(statusView)
            button.setAccessibilityLabel("NetSpeed")
        }
        menu.delegate = self
        statusItem.menu = menu
        names = NetworkReader.interfaceNames()
        sample()
        buildMenu()
        startTimer()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showAbout() }
        return true
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func timerFired() { sample() }

    @objc private func willSleep() {
        sleeping = true
        timer?.invalidate()
        calculator.reset()
        rate = nil
        render()
    }

    @objc private func didWake() {
        sleeping = false
        calculator.reset()
        sample()
        startTimer()
    }

    private func sample() {
        do {
            counters = try NetworkReader.snapshot()
            primary = NetworkReader.primaryInterface(in: counters)
            if tickCount % 15 == 0 { names = NetworkReader.interfaceNames() }
            tickCount += 1
            let selected = preference ?? primary
            active = selected.flatMap { counters[$0]?.isActive == true ? $0 : nil }
            rate = calculator.update(active.flatMap { counters[$0] }, at: ProcessInfo.processInfo.systemUptime)
            readError = nil
        } catch {
            readError = error.localizedDescription
            active = nil
            rate = nil
            calculator.reset()
        }
        render()
    }

    private func label(for name: String) -> String {
        if let display = names[name], display != name { return "\(display) · \(name)" }
        return name
    }

    private var connectionText: String {
        if sleeping { return "电脑休眠中" }
        if let readError { return readError }
        if let active { return label(for: active) + (rate == nil ? " · 正在采样…" : "") }
        if let preference { return "所选网卡未连接：\(preference)" }
        return "网络未连接"
    }

    private func render() {
        let down = rate.map { unit.format($0.download) } ?? "—"
        let up = rate.map { unit.format($0.upload) } ?? "—"
        statusView.download = down
        statusView.upload = up
        if let statusItem, statusItem.length != statusView.requiredWidth {
            statusItem.length = statusView.requiredWidth
            statusItem.button?.layoutSubtreeIfNeeded()
            if let button = statusItem.button { statusView.frame = button.bounds }
        }
        let description = "下载 \(down)，上传 \(up)。\(connectionText)"
        statusItem?.button?.toolTip = description
        statusItem?.button?.setAccessibilityLabel("NetSpeed：" + description)
        statusItem?.button?.setAccessibilityValue("↓ \(down)  ↑ \(up)")
        downloadRow?.title = "↓  下载   " + down
        uploadRow?.title = "↑  上传   " + up
        connectionRow?.title = connectionText
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === self.menu { buildMenu() }
    }

    private func item(_ title: String, action: Selector? = nil) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: action, keyEquivalent: "")
        row.target = self
        row.isEnabled = action != nil
        return row
    }

    private func buildMenu() {
        menu.removeAllItems()
        let heading = item("NetSpeed")
        heading.attributedTitle = NSAttributedString(string: "NetSpeed", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        menu.addItem(heading)
        downloadRow = item("")
        uploadRow = item("")
        connectionRow = item("")
        menu.addItem(downloadRow!)
        menu.addItem(uploadRow!)
        menu.addItem(connectionRow!)
        menu.addItem(.separator())

        let network = NSMenu(title: "网络接口")
        let automaticTitle = primary.map { "自动（\(label(for: $0))）" } ?? "自动（当前连接）"
        let automatic = item(automaticTitle, action: #selector(selectInterface(_:)))
        automatic.representedObject = ""
        automatic.state = preference == nil ? .on : .off
        network.addItem(automatic)
        network.addItem(.separator())
        let available = counters.values.filter { $0.isActive }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for counter in available {
            let row = item(label(for: counter.name), action: #selector(selectInterface(_:)))
            row.representedObject = counter.name
            row.state = preference == counter.name ? .on : .off
            network.addItem(row)
        }
        if let preference, !available.contains(where: { $0.name == preference }) {
            let missing = item("\(preference)（未连接）")
            missing.state = .on
            network.addItem(missing)
        }
        let interfaces = NSMenuItem(title: "网络接口", action: nil, keyEquivalent: "")
        interfaces.submenu = network
        menu.addItem(interfaces)

        let units = NSMenu(title: "速度单位")
        for choice in SpeedUnit.allCases {
            let row = item(choice.menuTitle, action: #selector(selectUnit(_:)))
            row.representedObject = choice.rawValue
            row.state = choice == unit ? .on : .off
            units.addItem(row)
        }
        let unitMenu = NSMenuItem(title: "速度单位", action: nil, keyEquivalent: "")
        unitMenu.submenu = units
        menu.addItem(unitMenu)

        let service = SMAppService.mainApp
        let login = item(service.status == .requiresApproval ? "登录时启动（需系统允许）" : "登录时启动", action: #selector(toggleLogin))
        login.state = service.status == .enabled ? .on : service.status == .requiresApproval ? .mixed : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(item("关于 NetSpeed", action: #selector(showAbout)))
        let quit = item("退出 NetSpeed", action: #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
        render()
    }

    @objc private func selectInterface(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        if value.isEmpty { UserDefaults.standard.removeObject(forKey: "interface") }
        else { UserDefaults.standard.set(value, forKey: "interface") }
        calculator.reset()
        sample()
    }

    @objc private func selectUnit(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        UserDefaults.standard.set(value, forKey: "unit")
        render()
    }

    @objc private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled: try SMAppService.mainApp.unregister()
            case .requiresApproval: SMAppService.openSystemSettingsLoginItems()
            default:
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "未能更改登录启动"
            alert.informativeText = "请将 NetSpeed 保留在“应用程序”文件夹中，然后重试。\n" + error.localizedDescription
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "NetSpeed 1.0"
        alert.informativeText = "轻量的菜单栏网速显示\n\n↓ 下载速度    ↑ 上传速度\n每秒更新，自动跟随当前网络。\n\n只读取本机网卡的流量计数，不收集浏览记录，也不向外发送数据。\n字节单位采用十进制：1 MB = 1,000,000 B。"
        alert.icon = NSApp.applicationIconImage
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
