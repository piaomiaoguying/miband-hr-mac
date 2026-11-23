import AppKit
import Carbon.HIToolbox
import Darwin
import Foundation
import QuartzCore

// MARK: - 主题

private let accentColor = NSColor(srgbRed: 0.902, green: 0.404, blue: 0.404, alpha: 1.0)
private let positiveColor = NSColor(srgbRed: 0.047, green: 0.639, blue: 0.047, alpha: 1.0)
private let warnColor = NSColor(srgbRed: 0.980, green: 0.698, blue: 0.098, alpha: 1.0)
private let seriousColor = NSColor(srgbRed: 0.925, green: 0.514, blue: 0.353, alpha: 1.0)
private let mutedColor = NSColor(srgbRed: 0.537, green: 0.529, blue: 0.506, alpha: 1.0)

// MARK: - 数据模型

private struct HeartRateState: Decodable {
    let status: String
    let statusLabel: String
    let bpm: Int?
    let lastValidAgeMs: Int?
    let lastError: String?

    enum CodingKeys: String, CodingKey {
        case status
        case statusLabel = "status_label"
        case bpm
        case lastValidAgeMs = "last_valid_age_ms"
        case lastError = "last_error"
    }
}

// MARK: - 浮窗

private final class FloatWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
}

private final class FloatView: NSView {
    var scale: CGFloat = 1 {
        didSet {
            guard scale != oldValue else { return }
            updateFonts()
            needsLayout = true
            renderContent()
            window?.invalidateCursorRects(for: self)
        }
    }

    var transparentBackground = false {
        didSet {
            renderContent()
            onTransparentChanged?(transparentBackground)
        }
    }

    /// 纯透明模式下窗口不应再有系统投影，否则会在四周留一圈黑色描边。
    var onTransparentChanged: ((Bool) -> Void)?

    /// 是否允许通过手柄缩放（锁定时禁用）。
    var showResizeGrip = true {
        didSet {
            gripVisible = showResizeGrip && isHovering
            window?.invalidateCursorRects(for: self)
        }
    }

    /// 手柄是否实际绘制。默认隐藏，鼠标进入浮窗才显示。
    private var gripVisible = false {
        didSet {
            guard gripVisible != oldValue else { return }
            renderContent()
            window?.invalidateCursorRects(for: self)
        }
    }

    private var isHovering = false
    private var hoverTrackingArea: NSTrackingArea?

    /// 锁定时窗口整体忽略鼠标事件，实现真正的点击穿透。
    /// 解锁依赖全局热键 ⌘⇧L（Carbon，无需辅助功能权限），因此不会锁死。
    var isLocked = false {
        didSet {
            showResizeGrip = !isLocked
            window?.invalidateCursorRects(for: self)
        }
    }

    var makeMenu: (() -> NSMenu)?
    var onPositionChanged: (() -> Void)?
    var onInteractiveScaleChanged: ((CGFloat) -> Void)?

    private let contentLayer = CALayer()
    private let heartLayer = CALayer()
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var lastDragPoint: NSPoint = .zero
    private var resizing = false
    private var resizeStartScale: CGFloat = 1
    private var resizeStartWidth: CGFloat = 0
    private var resizeStartHeight: CGFloat = 0
    private var resizeStartOrigin: NSPoint = .zero

    private var bpmFont = NSFont.monospacedDigitSystemFont(ofSize: 64, weight: .semibold)
    private var statusFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    private var bpmValue: Int?
    private var bpmText = ""
    private var statusText = "等待手环"
    private var statusColor = mutedColor
    private var contentAlpha: CGFloat = 1
    private let labelPadding: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // 视图自身图层交给 AppKit 管理，位图放在独立子图层，避免被重绘覆盖或残留。
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
        // 禁止本视图图层的隐式动画，避免尺寸变化时旧内容被拉伸残留。
        layer?.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "contents": NSNull(),
            "sublayers": NSNull(),
            "frame": NSNull()
        ]
        contentLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "contentsScale": NSNull()
        ]
        contentLayer.contentsGravity = .resize
        contentLayer.magnificationFilter = .linear
        contentLayer.minificationFilter = .linear
        layer?.addSublayer(contentLayer)

        heartLayer.contentsGravity = .resizeAspect
        heartLayer.contents = makeHeartImage()
        heartLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        heartLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
            "transform": NSNull(),
            "contentsScale": NSNull()
        ]
        layer?.addSublayer(heartLayer)
        updateFonts()
        applyState(state: nil, connected: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        self
    }

    /// 锁定后左键穿透到下层应用，但右键仍需命中本视图，否则没有任何入口可以解锁。
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = makeMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func currentEventIsRightClick() -> Bool {
        NSApp.currentEvent?.type == .rightMouseDown
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        makeMenu?()
    }

    override func mouseDown(with event: NSEvent) {
        guard !isLocked, let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        dragStartMouse = NSEvent.mouseLocation
        lastDragPoint = NSEvent.mouseLocation
        if showResizeGrip && gripVisible && gripHitRect.contains(point) {
            resizing = true
            dragStartOrigin = nil
            resizeStartScale = scale
            resizeStartWidth = window.frame.width
            resizeStartHeight = window.frame.height
            resizeStartOrigin = window.frame.origin
        } else {
            resizing = false
            dragStartOrigin = window.frame.origin
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let current = NSEvent.mouseLocation
        if resizing {
            guard let startMouse = dragStartMouse else { return }
            guard resizeStartWidth > 0 else { return }
            let delta = current.x - startMouse.x
            let target = resizeStartScale * (resizeStartWidth + delta) / resizeStartWidth
            let clamped = min(2.0, max(0.6, target))
            guard abs(clamped - scale) > 0.002 else { return }
            scale = clamped
            let newSize = preferredSize
            var frame = window.frame
            frame.origin.x = resizeStartOrigin.x
            frame.origin.y = resizeStartOrigin.y + resizeStartHeight - newSize.height
            frame.size = newSize
            window.setFrame(frame, display: true)
            needsLayout = true
            renderContent()
            onInteractiveScaleChanged?(clamped)
        } else if dragStartOrigin != nil {
            // 用事件自带的增量累加，而不是「起始点 + 当前点」。
            // 快速拖动时事件可能被合并或丢弃，绝对差值会累积成漂移；
            // 增量只依赖相邻两帧的相对位移，不会积累误差。
            let delta = event.deltaX == 0 && event.deltaY == 0
                ? NSPoint(x: current.x - lastDragPoint.x, y: current.y - lastDragPoint.y)
                : NSPoint(x: event.deltaX, y: -event.deltaY)
            lastDragPoint = current
            var origin = window.frame.origin
            origin.x += delta.x
            origin.y += delta.y
            window.setFrameOrigin(origin)
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragStartMouse = nil
        dragStartOrigin = nil
        resizing = false
        onPositionChanged?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if showResizeGrip && gripVisible {
            addCursorRect(gripHitRect, cursor: .crosshair)
        }
    }

    private var gripHitRect: NSRect {
        let side = 20 * scale
        return NSRect(x: bounds.maxX - side, y: 0, width: side, height: side)
    }

    var preferredSize: NSSize {
        let s = scale
        let padX = 18 * s
        let padY = 12 * s
        let heartW = 30 * s
        let gap = 12 * s
        let bpmWidth = measure("000", font: bpmFont).width + labelPadding
        let statusWidth = measure("信号中断 · 00 分钟前", font: statusFont).width
        let mainHeight = max(27 * s, measure("0", font: bpmFont).height)
        let width = padX + heartW + gap + max(bpmWidth, statusWidth + 12 * s) + padX
        let height = padY + mainHeight + 5 * s + measure("0", font: statusFont).height + padY
        return NSSize(width: ceil(width), height: ceil(height))
    }

    func update(state: HeartRateState?, connected: Bool) {
        applyState(state: state, connected: connected)
        needsLayout = true
        renderContent()
    }

    private func applyState(state: HeartRateState?, connected: Bool) {
        let bpm = state?.bpm
        let status = state?.status ?? ""
        let age = state?.lastValidAgeMs
        bpmValue = bpm

        let permissionIssue = connected
            && (state?.lastError?.contains("未授权") == true || state?.lastError?.contains("蓝牙不可用") == true)

        if permissionIssue {
            bpmText = bpm.map(String.init) ?? ""
            statusText = "需要蓝牙权限"
            statusColor = seriousColor
            contentAlpha = 0.85
        } else if !connected {
            bpmText = bpm.map(String.init) ?? ""
            statusText = "后端未运行"
            statusColor = mutedColor
            contentAlpha = 0.7
        } else if bpm != nil {
            bpmText = String(bpm!)
            switch status {
            case "live":
                statusText = "实时"
                statusColor = positiveColor
                contentAlpha = 1
            case "holding":
                statusText = "保持中 · \(ageText(age))"
                statusColor = warnColor
                contentAlpha = 1
            case "stale":
                statusText = "信号中断 · \(ageText(age))"
                statusColor = seriousColor
                contentAlpha = 0.6
            default:
                statusText = state?.statusLabel ?? "等待心率"
                statusColor = mutedColor
                contentAlpha = 0.7
            }
        } else {
            bpmText = ""
            statusText = state?.statusLabel ?? "正在连接"
            statusColor = mutedColor
            contentAlpha = 0.7
        }

        updateHeartAnimation()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        gripVisible = showResizeGrip
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        gripVisible = false
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let s = scale
        let padX = 18 * s
        let padY = 12 * s
        let heartW = 30 * s
        let heartH = 27 * s
        let bpmHeight = measure("0", font: bpmFont).height
        let statusHeight = measure("0", font: statusFont).height
        let mainHeight = max(heartH, bpmHeight)
        let bpmY = padY + statusHeight + 5 * s

        heartLayer.bounds = CGRect(origin: .zero, size: CGSize(width: heartW, height: heartH))
        heartLayer.position = CGPoint(
            x: padX + heartW / 2,
            y: bpmY + mainHeight / 2
        )
        heartLayer.contentsScale = window?.backingScaleFactor ?? 2
        renderContent()
    }

    // 每次更新都在离屏位图上重画整个浮窗，再整块替换图层内容。
    // 不依赖 AppKit 的局部重绘，旧内容没有任何留存通道。
    private func renderContent() {
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let pixelWidth = max(1, Int(ceil(size.width * backingScale)))
        let pixelHeight = max(1, Int(ceil(size.height * backingScale)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        rep.size = size
        guard let graphics = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        drawContent(in: NSRect(origin: .zero, size: size))

        NSGraphicsContext.restoreGraphicsState()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        contentLayer.frame = CGRect(origin: .zero, size: size)
        contentLayer.contentsScale = backingScale
        contentLayer.contents = rep.cgImage
        CATransaction.commit()
    }

    private func drawContent(in rect: NSRect) {
        let s = scale
        if !transparentBackground {
            let pill = NSBezierPath(
                roundedRect: rect,
                xRadius: 22 * s,
                yRadius: 22 * s
            )
            NSColor(srgbRed: 0.36, green: 0.36, blue: 0.36, alpha: 1.0).setFill()
            pill.fill()
            pill.lineWidth = 1
            NSColor.white.withAlphaComponent(0.13).setStroke()
            pill.stroke()
        }

        let padX = 18 * s
        let padY = 12 * s
        let heartW = 30 * s
        let gap = 12 * s
        let statusHeight = measure("0", font: statusFont).height
        let bpmX = padX + heartW + gap
        let bpmY = padY + statusHeight + 5 * s

        if !bpmText.isEmpty {
            styled(bpmText, font: bpmFont, color: .white).draw(at: NSPoint(x: bpmX, y: bpmY))
        }

        let dotSize = 6 * s
        let dotRect = NSRect(
            x: bpmX,
            y: padY + (statusHeight - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )
        statusColor.withAlphaComponent(contentAlpha).setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        styled(statusText, font: statusFont, color: statusColor).draw(
            at: NSPoint(x: dotRect.maxX + 5 * s, y: padY)
        )

        if gripVisible {
            let side = 12 * s
            let origin = NSPoint(
                x: rect.maxX - side - 14 * s,
                y: 12 * s
            )
            let path = NSBezierPath()
            path.lineWidth = max(1, side / 10)
            path.lineCapStyle = .round
            NSColor.white.withAlphaComponent(0.72).setStroke()
            path.move(to: NSPoint(x: origin.x, y: origin.y))
            path.line(to: NSPoint(x: origin.x + side, y: origin.y + side))
            path.move(to: NSPoint(x: origin.x + side * 0.38, y: origin.y))
            path.line(to: NSPoint(x: origin.x + side, y: origin.y + side * 0.62))
            path.move(to: NSPoint(x: origin.x + side * 0.74, y: origin.y))
            path.line(to: NSPoint(x: origin.x + side, y: origin.y + side * 0.26))
            path.stroke()
        }
    }

    private func updateFonts() {
        bpmFont = NSFont.monospacedDigitSystemFont(ofSize: 64 * scale, weight: .semibold)
        statusFont = NSFont.systemFont(ofSize: 11 * scale, weight: .regular)
    }

    private func updateHeartAnimation() {
        heartLayer.removeAnimation(forKey: "beat")
        heartLayer.opacity = Float(contentAlpha)
        let duration = bpmValue.map { max(0.38, min(1.4, 60.0 / Double($0))) } ?? 1.15
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, 1.13, 1.0, 1.06, 1.0, 1.0]
        animation.keyTimes = [0, 0.12, 0.24, 0.36, 0.48, 1]
        animation.duration = duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        heartLayer.add(animation, forKey: "beat")
    }

    private func makeHeartImage() -> CGImage? {
        guard let symbol = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil) else {
            return nil
        }
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .sourceAtop
            accentColor.setFill()
            NSBezierPath(rect: rect).fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func ageText(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "刚刚" }
        if milliseconds < 1500 { return "刚刚" }
        if milliseconds < 60000 {
            return "\(max(1, Int((Double(milliseconds) / 1000).rounded()))) 秒前"
        }
        return "\(max(1, milliseconds / 60000)) 分钟前"
    }

    private func styled(
        _ text: String,
        font: NSFont,
        color: NSColor,
        kern: CGFloat = 0
    ) -> NSAttributedString {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55 * contentAlpha)
        // 投影跟随缩放，避免小尺寸下模糊相对字形过大而渗进数字内圈。
        shadow.shadowBlurRadius = max(0.5, 3 * scale)
        shadow.shadowOffset = NSSize(width: 0, height: max(0.3, -1 * scale))
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color.withAlphaComponent(contentAlpha),
            .shadow: shadow
        ]
        if kern != 0 { attributes[.kern] = kern }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private func measure(_ text: String, font: NSFont, kern: CGFloat = 0) -> NSSize {
        var attributes: [NSAttributedString.Key: Any] = [.font: font]
        if kern != 0 { attributes[.kern] = kern }
        return (text as NSString).size(withAttributes: attributes)
    }
}

// MARK: - App

private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: FloatWindow!
    private var floatView: FloatView!
    private var streamSession: URLSession?
    private var streamTask: URLSessionDataTask?
    private var streamDelegate: EventStreamDelegate?
    private var isStreaming = false
    private var reconnectDelay: Double = 0.5
    private var lastState: HeartRateState?
    private var backendReachable = false
    private var backendProcess: Process?
    private var backendLogHandle: FileHandle?
    private var signalSource: DispatchSourceSignal?
    private var moveObserver: NSObjectProtocol?
    private var saveFrameWorkItem: DispatchWorkItem?
    private var unlockHotKeyRef: EventHotKeyRef?

    private let defaults = UserDefaults.standard
    private var port = 3030
    private var controlPort: Int { port + 1 }
    private var webServiceRunning = false
    private var userVisible = true
    private var locked = false
    private var scale: CGFloat = 1.0
    private var transparentBackground = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        parseArguments()
        loadSettings()
        buildWindow()
        observeTermination()
        observeWindowMoves()
        registerUnlockHotKey()
        startEventStream()
        refreshServiceState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self, !self.backendReachable else { return }
            self.ensureBackend()
        }
    }

    private func observeTermination() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            NSApp.terminate(nil)
        }
        source.resume()
        signalSource = source
    }

    // 加锁后窗口忽略所有鼠标事件，必须有一条不依赖点击的退路。
    // 使用 Carbon RegisterEventHotKey：系统级生效，且不需要「辅助功能」授权。
    private func registerUnlockHotKey() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        let handler: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard hotKeyID.signature == OSType(0x4D424C54) else { return noErr }
            let delegate = Unmanaged<AppDelegate>
                .fromOpaque(userData)
                .takeUnretainedValue()
            DispatchQueue.main.async {
                delegate.unlockFromHotKey()
            }
            return noErr
        }

        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            selfPointer,
            nil
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x4D424C54), id: 1)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(
            UInt32(kVK_ANSI_L),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        unlockHotKeyRef = ref
    }

    fileprivate func unlockFromHotKey() {
        guard locked else { return }
        locked = false
        saveSettings()
        floatView.isLocked = false
        window.ignoresMouseEvents = false
        updateVisibility()
        NSSound.beep()
    }

    private func observeWindowMoves() {
        // 拖动过程中每帧都会触发 didMove。直接落盘会造成明显掉帧，
        // 这里只在停止移动 300ms 后写一次。
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.saveFrameWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.saveWindowFrame()
            }
            self.saveFrameWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopEventStream()
        saveWindowFrame()
        backendLogHandle?.closeFile()
        backendLogHandle = nil
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !userVisible {
            userVisible = true
            saveSettings()
        }
        updateVisibility()
        window.orderFrontRegardless()
        return true
    }

    private func parseArguments() {
        if let env = ProcessInfo.processInfo.environment["MIBAND_HR_PORT"],
           let parsed = Int(env),
           (1...65535).contains(parsed) {
            port = parsed
        }
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            if arg == "--port", let value = args.next(), let parsed = Int(value), (1...65535).contains(parsed) {
                port = parsed
            }
        }
    }

    private func loadSettings() {
        if defaults.object(forKey: "float.visible") != nil {
            userVisible = defaults.bool(forKey: "float.visible")
        }
        locked = defaults.bool(forKey: "float.locked")
        if defaults.object(forKey: "float.scale") != nil {
            scale = CGFloat(defaults.double(forKey: "float.scale"))
        }
        if !(0.6...2.0).contains(scale) {
            scale = 1.0
        }
        transparentBackground = defaults.bool(forKey: "float.transparent")
    }

    private func saveSettings() {
        defaults.set(userVisible, forKey: "float.visible")
        defaults.set(locked, forKey: "float.locked")
        defaults.set(Double(scale), forKey: "float.scale")
        defaults.set(transparentBackground, forKey: "float.transparent")
    }

    private func buildWindow() {
        floatView = FloatView(frame: NSRect(origin: .zero, size: NSSize(width: 240, height: 96)))
        floatView.scale = scale
        floatView.transparentBackground = transparentBackground
        floatView.onTransparentChanged = { [weak self] transparent in
            self?.window?.hasShadow = !transparent
        }
        floatView.makeMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        floatView.onPositionChanged = { [weak self] in
            self?.saveSettings()
            self?.saveWindowFrame()
        }
        floatView.onInteractiveScaleChanged = { [weak self] value in
            self?.scale = value
        }
        floatView.isLocked = locked

        let size = floatView.preferredSize
        let frame = restoredFrame(size: size)
        window = FloatWindow(contentRect: frame)
        window.contentView = floatView
        window.setContentSize(size)
        window.setFrame(frame, display: false)
        window.hasShadow = !transparentBackground
        window.ignoresMouseEvents = locked
        floatView.needsLayout = true
        updateVisibility()
        window.orderFrontRegardless()
    }

    private func restoredFrame(size: NSSize) -> NSRect {
        if let saved = defaults.string(forKey: "float.frame") {
            let rect = NSRectFromString(saved)
            if rect.width > 40, rect.height > 30 {
                // 优先恢复到保存时所在的屏幕，保持右上角相对位置。
                let screen = NSScreen.screens.first { $0.frame.intersects(rect) }
                if let screen {
                    let visible = screen.visibleFrame
                    let x = min(max(rect.origin.x, visible.minX), visible.maxX - size.width)
                    let top = min(max(rect.maxY, visible.minY + size.height), visible.maxY)
                    return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
                }
                if let fallback = NSScreen.main?.visibleFrame {
                    return NSRect(
                        x: min(rect.origin.x, fallback.maxX - size.width),
                        y: min(rect.origin.y, fallback.maxY - size.height),
                        width: size.width,
                        height: size.height
                    )
                }
            }
        }
        return defaultFrame(size: size)
    }

    private func defaultFrame(size: NSSize) -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: screen.maxX - size.width - 24,
            y: screen.maxY - size.height - 24,
            width: size.width,
            height: size.height
        )
    }

    private func saveWindowFrame() {
        guard window != nil else { return }
        defaults.set(NSStringFromRect(window.frame), forKey: "float.frame")
    }

    private func resizeWindowKeepingTopRight() {
        guard window != nil else { return }
        let size = floatView.preferredSize
        var frame = window.frame
        frame.origin.x = frame.maxX - size.width
        frame.origin.y = frame.maxY - size.height
        frame.size = size
        window.setFrame(frame, display: true)
        floatView.needsLayout = true
        saveWindowFrame()
    }

    private func updateVisibility() {
        guard window != nil else { return }
        let shouldShow = userVisible
        if shouldShow {
            if !window.isVisible {
                window.orderFrontRegardless()
            }
            } else if window.isVisible {
            window.orderOut(nil)
        }
    }

    private var projectRoot: URL? {
        let bundle = Bundle.main.bundleURL
        let root = bundle.deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent("bin/miband-hr-mac")
        return FileManager.default.isExecutableFile(atPath: binary.path) ? root : nil
    }

    private func ensureBackend(force: Bool = false) {
        guard !backendReachable else { return }
        if !force, let process = backendProcess, process.isRunning { return }
        guard let root = projectRoot else { return }
        let binary = root.appendingPathComponent("bin/miband-hr-mac")
        let dataDir = root.appendingPathComponent("data")
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

        let logURL = dataDir.appendingPathComponent("app.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        backendLogHandle?.closeFile()
        let logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()
        let stamp = ISO8601DateFormatter().string(from: Date())
        logHandle?.write("===== \(stamp) 浮窗自动启动 =====\n".data(using: .utf8)!)

        let process = Process()
        process.executableURL = binary
        process.currentDirectoryURL = root
        process.arguments = ["--no-open", "--port", String(port)]
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.backendReachable = false
            }
        }

        do {
            try process.run()
            backendProcess = process
            backendLogHandle = logHandle
            let pidFile = dataDir.appendingPathComponent("app.pid")
            try? String(process.processIdentifier).write(to: pidFile, atomically: true, encoding: .utf8)
        } catch {
            logHandle?.closeFile()
            backendLogHandle = nil
        }
    }

    private func stopBackend() {
        if let process = backendProcess, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            scheduleForceKill(pid)
        } else if let pid = backendPid(), isBackendProcess(pid) {
            Darwin.kill(pid, SIGTERM)
            scheduleForceKill(pid)
        } else if let pid = portListenerPid(), isBackendProcess(pid) {
            Darwin.kill(pid, SIGTERM)
            scheduleForceKill(pid)
        }

        backendProcess = nil
        backendLogHandle?.closeFile()
        backendLogHandle = nil
        backendReachable = false
        floatView.update(state: lastState, connected: false)
        updateVisibility()
        if let root = projectRoot {
            try? FileManager.default.removeItem(at: root.appendingPathComponent("data/app.pid"))
        }
    }

    private func scheduleForceKill(_ pid: Int32) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            if Darwin.kill(pid, 0) == 0 {
                Darwin.kill(pid, SIGKILL)
            }
        }
    }

    private func backendPid() -> Int32? {
        guard let root = projectRoot else { return nil }
        let path = root.appendingPathComponent("data/app.pid")
        guard let content = try? String(contentsOf: path, encoding: .utf8),
              let pid = Int32(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    private func portListenerPid() -> Int32? {
        guard let output = runProcess("/usr/sbin/lsof", ["-tiTCP:\(port)", "-sTCP:LISTEN"]),
              let first = output.split(whereSeparator: { $0.isNewline }).first,
              let pid = Int32(first) else {
            return nil
        }
        return pid
    }

    private func isBackendProcess(_ pid: Int32) -> Bool {
        guard let output = runProcess("/bin/ps", ["-p", String(pid), "-o", "command="]) else {
            return false
        }
        return output.contains("miband-hr-mac")
    }

    private func runProcess(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// 订阅后端推送流。没有广播时连接静默，不做任何轮询计算。
    /// 断线后按指数退避重连，最长 10 秒。
    private func startEventStream() {
        guard !isStreaming else { return }
        isStreaming = true
        reconnectDelay = 0.5
        openEventStream()
    }

    private func openEventStream() {
        guard let url = URL(string: "http://127.0.0.1:\(controlPort)/api/events") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3600
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let delegate = EventStreamDelegate(
            onLine: { [weak self] payload in
                guard let self else { return }
                guard let data = payload.data(using: .utf8) else {
                    NSLog("SSE: payload 转 Data 失败: %@", payload)
                    return
                }
                let state: HeartRateState
                do {
                    state = try JSONDecoder().decode(HeartRateState.self, from: data)
                } catch {
                    NSLog("SSE: 解码失败 %@ / 原始: %@", String(describing: error), payload)
                    return
                }
                self.backendReachable = true
                self.lastState = state
                self.applyState(connected: true)
            },
            onEnd: { [weak self] in
                guard let self else { return }
                self.backendReachable = false
                self.applyState(connected: false)
                self.scheduleReconnect()
            }
        )
        // URLSession 的 delegate 必须在初始化时绑定，用 dataTask(with:) 拿不到回调。
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: .main
        )
        streamDelegate = delegate
        streamSession = session
        streamTask = session.dataTask(with: request)
        streamTask?.resume()
    }

    private func scheduleReconnect() {
        streamTask?.cancel()
        streamTask = nil
        streamSession?.invalidateAndCancel()
        streamSession = nil
        streamDelegate = nil
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 10)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.openEventStream()
        }
    }

    private func stopEventStream() {
        streamTask?.cancel()
        streamTask = nil
        streamSession?.invalidateAndCancel()
        streamSession = nil
        streamDelegate = nil
        isStreaming = false
    }

    private func applyState(connected: Bool) {
        floatView.update(state: lastState, connected: connected)
        updateVisibility()
        let bpm = lastState?.bpm
        let label = lastState?.statusLabel ?? (connected ? "等待数据" : "后端未运行")
        window?.title = bpm.map { "心率 \($0) BPM · \(label)" } ?? "心率浮窗 · \(label)"
    }

    @objc private func toggleVisible() {
        userVisible.toggle()
        saveSettings()
        updateVisibility()
    }

    @objc private func toggleLocked() {
        locked.toggle()
        saveSettings()
        floatView.isLocked = locked
        window.ignoresMouseEvents = locked
        updateVisibility()
    }

    @objc private func toggleTransparent() {
        transparentBackground.toggle()
        floatView.transparentBackground = transparentBackground
        window.hasShadow = !transparentBackground
        saveSettings()
    }

    // MARK: - 开机自启动

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("local.miband.float.plist")
    }

    private var launchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @objc private func toggleLaunchAtLogin() {
        if launchAtLoginEnabled {
            disableLaunchAtLogin()
        } else {
            enableLaunchAtLogin()
        }
    }

    private func enableLaunchAtLogin() {
        let executable = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/MibandFloat")
            .path
        let plist: [String: Any] = [
            "Label": "local.miband.float",
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LimitLoadToSessionType": "Aqua"
        ]
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0
            )
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: launchAgentURL, options: .atomic)
            // 立即注册到 launchd，下次登录无需等重新扫描 LaunchAgents。
            runLaunchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
        } catch {
            presentAlert("无法开启开机自启动：\(error.localizedDescription)")
        }
    }

    private func disableLaunchAtLogin() {
        // 先从 launchd 卸载，避免已注册的任务继续生效。
        runLaunchctl(["bootout", "gui/\(getuid())/local.miband.float"])
        do {
            try FileManager.default.removeItem(at: launchAgentURL)
        } catch CocoaError.fileNoSuchFile {
            // 已经不存在，视为已关闭
        } catch {
            presentAlert("无法关闭开机自启动：\(error.localizedDescription)")
        }
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }

    private func presentAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "心率浮窗"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }

    @objc private func setScale(_ sender: NSMenuItem) {
        guard let value = (sender.representedObject as? NSNumber)?.doubleValue else { return }
        scale = CGFloat(value)
        floatView.scale = scale
        saveSettings()
        resizeWindowKeepingTopRight()
    }

    @objc private func openPanel() {
        // 网页服务默认关闭，打开面板前先确保它已启动。
        guard let serviceURL = URL(
            string: "http://127.0.0.1:\(controlPort)/api/service?action=on"
        ) else { return }
        var request = URLRequest(url: serviceURL)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.webServiceRunning = true
                self.openPanelInBrowser()
            }
        }.resume()
    }

    private func openPanelInBrowser() {
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return }
        let edge = URL(fileURLWithPath: "/Applications/Microsoft Edge.app")
        if FileManager.default.fileExists(atPath: edge.path) {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: edge,
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func resetPosition() {
        window.setFrame(defaultFrame(size: floatView.preferredSize), display: true)
        saveWindowFrame()
    }

    @objc private func startBackend() {
        backendReachable = false
        ensureBackend(force: true)
    }

    @objc private func stopBackendAction() {
        stopBackend()
    }

    @objc private func restartBackend() {
        stopBackend()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.ensureBackend(force: true)
        }
    }

    @objc private func toggleWebService() {
        let target = webServiceRunning ? "off" : "on"
        guard let url = URL(string: "http://127.0.0.1:\(controlPort)/api/service?action=\(target)") else {
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            var running = (target == "on")
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let value = json["web"] as? Bool {
                running = value
            }
            DispatchQueue.main.async {
                self.webServiceRunning = running
                self.refreshServiceState()
            }
        }.resume()
    }

    /// 读取控制端口的服务状态，保持菜单勾选与实际一致。
    private func refreshServiceState() {
        guard let url = URL(string: "http://127.0.0.1:\(controlPort)/api/service") else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let running = json["web"] as? Bool
            else { return }
            DispatchQueue.main.async {
                self.webServiceRunning = running
            }
        }.resume()
    }

    @objc private func openBluetoothSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        saveWindowFrame()
        NSApp.terminate(nil)
    }

    @objc private func quitAndStopBackend() {
        stopBackend()
        saveWindowFrame()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        addToggle(to: menu, title: "显示浮窗", action: #selector(toggleVisible), on: userVisible)
        addToggle(to: menu, title: "锁定位置（点击穿透，⌘⇧L 解锁）", action: #selector(toggleLocked), on: locked)
        addToggle(to: menu, title: "纯透明背景", action: #selector(toggleTransparent), on: transparentBackground)
        addToggle(to: menu, title: "开机自动启动", action: #selector(toggleLaunchAtLogin), on: launchAtLoginEnabled)
        menu.addItem(.separator())

        let sizeItem = NSMenuItem(title: "大小", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (title, value) in [("小", 0.8), ("中", 1.0), ("大", 1.3), ("特大", 1.6)] {
            let item = NSMenuItem(title: title, action: #selector(setScale(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: value)
            item.state = abs(scale - CGFloat(value)) < 0.01 ? .on : .off
            sizeMenu.addItem(item)
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        if backendReachable {
            addAction(to: menu, title: "停止后台服务", action: #selector(stopBackendAction))
            addAction(to: menu, title: "重启后台服务", action: #selector(restartBackend))
        } else {
            addAction(to: menu, title: "启动后台服务", action: #selector(startBackend))
        }
        // 网页服务与网页面板相邻，先开关再打开，符合使用顺序。
        addToggle(
            to: menu,
            title: "网页服务（面板 / OBS）",
            action: #selector(toggleWebService),
            on: webServiceRunning
        )
        addAction(to: menu, title: "打开网页面板", action: #selector(openPanel))
        addAction(to: menu, title: "蓝牙权限设置", action: #selector(openBluetoothSettings))
        addAction(to: menu, title: "重置位置", action: #selector(resetPosition))

        menu.addItem(.separator())
        addAction(to: menu, title: "退出浮窗", action: #selector(quit))
        addAction(to: menu, title: "退出并停止后台服务", action: #selector(quitAndStopBackend))
        return menu
    }

    @discardableResult
    private func addAction(to menu: NSMenu, title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addToggle(to menu: NSMenu, title: String, action: Selector, on: Bool) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }
}

// MARK: - SSE 客户端

/// 逐行解析 text/event-stream，把 `data:` 行交给回调；连接结束时触发 onEnd。
private final class EventStreamDelegate: NSObject, URLSessionDataDelegate {
    private let onLine: (String) -> Void
    private let onEnd: () -> Void
    private var buffer = Data()
    private var finished = false

    init(onLine: @escaping (String) -> Void, onEnd: @escaping () -> Void) {
        self.onLine = onLine
        self.onEnd = onEnd
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else { continue }
            onLine(String(payload))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        finished = true
        onEnd()
    }
}

// MARK: - 入口

private let application = NSApplication.shared
private let delegate = AppDelegate()
application.delegate = delegate
application.run()



