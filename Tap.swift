import AppKit
import ApplicationServices
import Darwin
import IOKit.hid

enum Tap {
    static let port: UInt16 = 5000
    static let note = "org.kikibridge.tap.state"

    static func unlock() -> Int32 {
        Pointer.reset()
        Karabiner.set(false, wait: true)
        fputs("kikibridge: unlocked pointer, karabiner kikibridge=0\n", stderr)
        return 0
    }

    static func run(arguments: [String]) -> Int32 {
        signal(SIGPIPE, kbIgnoreSignal)
        let w = Worker()
        return w.run(arguments: arguments)
    }
}

private final class Worker {
    var on = false
    var stop = false
    var cmdHeld = false
    var cmdTab = false
    var winDown = false
    var hidden = false
    var quietUntil: UInt64 = 0
    var accDx: Int32 = 0
    var accDy: Int32 = 0
    var btn: [UInt8] = [0, 0, 0, 0]
    var sock: Int32 = -1
    var guardFd: Int32 = -1
    var parent: pid_t = 0
    var addr = sockaddr_in()
    var down = [UInt8](repeating: 0, count: 256)
    var keyTap: CFMachPort?
    var mouseTap: CFMachPort?
    var mouseListen: CFMachPort?
    var hid: IOHIDManager?
    var host = "deck"
    var resolveFails = 0
    var park = CGPoint.zero
    let keyMap: [Int]
    let hidMap: [Int]

    init() {
        var km = [Int](repeating: 0, count: 128)
        km[0x00]=30; km[0x01]=31; km[0x02]=32; km[0x03]=33
        km[0x04]=35; km[0x05]=34; km[0x06]=44; km[0x07]=45
        km[0x08]=46; km[0x09]=47; km[0x0B]=48
        km[0x0C]=16; km[0x0D]=17; km[0x0E]=18; km[0x0F]=19
        km[0x10]=21; km[0x11]=20
        km[0x12]=2;  km[0x13]=3;  km[0x14]=4;  km[0x15]=5
        km[0x16]=7;  km[0x17]=6;  km[0x18]=13; km[0x19]=10
        km[0x1A]=8;  km[0x1B]=12; km[0x1C]=9;  km[0x1D]=11
        km[0x1E]=27; km[0x1F]=24; km[0x20]=22; km[0x21]=26
        km[0x22]=23; km[0x23]=25; km[0x24]=28
        km[0x25]=38; km[0x26]=36; km[0x27]=40; km[0x28]=37
        km[0x29]=39; km[0x2A]=43; km[0x2B]=51; km[0x2C]=53
        km[0x2D]=49; km[0x2E]=50; km[0x2F]=52
        km[0x30]=15; km[0x31]=57; km[0x32]=41; km[0x33]=14
        km[0x35]=1
        km[0x38]=42; km[0x39]=58
        km[0x3A]=56;  km[0x3B]=29;  km[0x3C]=54;  km[0x3D]=100
        km[0x3E]=97
        km[0x41]=83; km[0x43]=55; km[0x45]=78; km[0x47]=69
        km[0x4B]=98; km[0x4C]=96; km[0x4E]=74; km[0x51]=117
        km[0x52]=82; km[0x53]=79; km[0x54]=80; km[0x55]=81
        km[0x56]=75; km[0x57]=76; km[0x58]=77; km[0x59]=71
        km[0x5B]=72; km[0x5C]=73
        km[0x60]=63; km[0x61]=64; km[0x62]=65; km[0x63]=61
        km[0x64]=66; km[0x65]=67; km[0x67]=87; km[0x69]=183
        km[0x6B]=184; km[0x6D]=68; km[0x6F]=88; km[0x71]=185
        km[0x72]=110; km[0x73]=102; km[0x74]=104; km[0x75]=111
        km[0x76]=62; km[0x77]=107; km[0x78]=60; km[0x79]=109
        km[0x7A]=59; km[0x7B]=105; km[0x7C]=106; km[0x7D]=108
        km[0x7E]=103
        km[0x48]=115; km[0x49]=114; km[0x4A]=113
        keyMap = km

        var hm = [Int](repeating: 0, count: 256)
        hm[0x04]=30; hm[0x05]=48; hm[0x06]=46; hm[0x07]=32
        hm[0x08]=18; hm[0x09]=33; hm[0x0A]=34; hm[0x0B]=35
        hm[0x0C]=23; hm[0x0D]=36; hm[0x0E]=37; hm[0x0F]=38
        hm[0x10]=50; hm[0x11]=49; hm[0x12]=24; hm[0x13]=25
        hm[0x14]=16; hm[0x15]=19; hm[0x16]=31; hm[0x17]=20
        hm[0x18]=22; hm[0x19]=47; hm[0x1A]=17; hm[0x1B]=45
        hm[0x1C]=21; hm[0x1D]=44
        hm[0x1E]=2;  hm[0x1F]=3;  hm[0x20]=4;  hm[0x21]=5
        hm[0x22]=6;  hm[0x23]=7;  hm[0x24]=8;  hm[0x25]=9
        hm[0x26]=10; hm[0x27]=11
        hm[0x28]=28; hm[0x29]=1;  hm[0x2A]=14; hm[0x2B]=15
        hm[0x2C]=57; hm[0x2D]=12; hm[0x2E]=13; hm[0x2F]=26
        hm[0x30]=27; hm[0x31]=43; hm[0x33]=39; hm[0x34]=40
        hm[0x35]=41; hm[0x36]=51; hm[0x37]=52; hm[0x38]=53
        hm[0x39]=58
        hm[0x3A]=59; hm[0x3B]=60; hm[0x3C]=61; hm[0x3D]=62
        hm[0x3E]=63; hm[0x3F]=64; hm[0x40]=65; hm[0x41]=66
        hm[0x42]=67; hm[0x43]=68; hm[0x44]=87; hm[0x45]=88
        hm[0x46]=99; hm[0x47]=70; hm[0x48]=119
        hm[0x49]=110; hm[0x4A]=102; hm[0x4B]=104; hm[0x4C]=111
        hm[0x4D]=107; hm[0x4E]=109; hm[0x4F]=106; hm[0x50]=105
        hm[0x51]=108; hm[0x52]=103
        hm[0x53]=69; hm[0x54]=98; hm[0x55]=55; hm[0x56]=74
        hm[0x57]=78; hm[0x58]=96
        hm[0x59]=71; hm[0x5A]=72; hm[0x5B]=73; hm[0x5C]=75
        hm[0x5D]=76; hm[0x5E]=77; hm[0x5F]=79; hm[0x60]=80
        hm[0x61]=81; hm[0x62]=82; hm[0x63]=83
        hm[0x65]=127
        hidMap = hm
    }

    func run(arguments: [String]) -> Int32 {
        Pointer.reset()
        parent = getppid()
        var i = 1
        let args = arguments
        while i < args.count {
            if args[i] == "--host", i + 1 < args.count { host = args[i + 1]; i += 2; continue }
            if args[i] == "--guard-fd", i + 1 < args.count { guardFd = Int32(args[i + 1]) ?? -1; i += 2; continue }
            if args[i] == "--parent-pid", i + 1 < args.count { parent = Int32(args[i + 1]) ?? parent; i += 2; continue }
            i += 1
        }
        if guardFd < 0 && parent <= 1 {
            fputs("kikibridge-tap: need --guard-fd or --parent-pid (won't run orphaned)\n", stderr)
            return 1
        }
        if parent <= 1 {
            fputs("kikibridge-tap: parent gone, refuse to start\n", stderr)
            return 1
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        if !AXIsProcessTrusted() {
            fputs("kikibridge-tap: accessibility not granted\n", stderr)
            return 2
        }
        _ = CGRequestListenEventAccess()
        _ = CGRequestPostEventAccess()
        if !CGPreflightListenEventAccess() {
            fputs("kikibridge-tap: input monitoring not effective\n", stderr)
            return 6
        }
        if resolve() != 0 {
            fputs("kikibridge-tap: cannot resolve \(host)\n", stderr)
            return 4
        }
        sock = socket(AF_INET, SOCK_DGRAM, 0)
        if sock < 0 { return 5 }
        _ = fcntl(sock, F_SETFL, O_NONBLOCK)

        let mm: CGEventMask =
            CGEventMaskBit(.mouseMoved) | CGEventMaskBit(.leftMouseDown) | CGEventMaskBit(.leftMouseUp) |
            CGEventMaskBit(.rightMouseDown) | CGEventMaskBit(.rightMouseUp) |
            CGEventMaskBit(.otherMouseDown) | CGEventMaskBit(.otherMouseUp) |
            CGEventMaskBit(.leftMouseDragged) | CGEventMaskBit(.rightMouseDragged) |
            CGEventMaskBit(.otherMouseDragged) | CGEventMaskBit(.scrollWheel)
        mouseListen = makeTap2(.cghidEventTap, mm, options: .listenOnly, kind: .listen)
        mouseTap = makeTap2(.cgSessionEventTap, mm, options: .defaultTap, kind: .eat)
        installKeyboard()
        if keyTap == nil {
            fputs("kikibridge-tap: no keyboard source\n", stderr)
            return 3
        }
        if mouseTap == nil {
            fputs("kikibridge-tap: mouse tap failed\n", stderr)
            return 3
        }
        watchParent()
        let apply = { [weak self] in
            guard let self, !self.stop else { return }
            self.setBridged(Self.isKikiEye(NSWorkspace.shared.frontmostApplication))
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in apply() }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in apply() }
        nc.addObserver(forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main) { _ in apply() }

        let tick = DispatchSource.makeTimerSource(queue: .main)
        tick.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(100))
        tick.setEventHandler(handler: apply)
        tick.resume()

        let parkT = DispatchSource.makeTimerSource(queue: .main)
        parkT.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        parkT.setEventHandler { [weak self] in
            guard let self, self.on, self.hidden else { return }
            CGWarpMouseCursorPosition(self.park)
            CGAssociateMouseAndMouseCursorPosition(0)
        }
        parkT.resume()

        apply()
        if !on { postState("wait") }
        app.run()
        shutdown()
        Pointer.reset()
        Karabiner.set(false, wait: true)
        return 0
    }

    private func resolve() -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        let port = "\(Tap.port)"
        var rc = getaddrinfo(host, port, &hints, &res)
        if rc != 0 || res == nil {
            rc = getaddrinfo("\(host).local", port, &hints, &res)
        }
        guard rc == 0, let r = res else { return -1 }
        _ = withUnsafeMutableBytes(of: &addr) { dest in
            memcpy(dest.baseAddress, r.pointee.ai_addr, MemoryLayout<sockaddr_in>.size)
        }
        freeaddrinfo(r)
        resolveFails = 0
        return 0
    }

    private func send(_ bytes: [UInt8]) {
        if sock < 0 { return }
        let n = bytes.withUnsafeBufferPointer { buf -> ssize_t in
            withUnsafePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    Darwin.sendto(sock, buf.baseAddress, buf.count, MSG_DONTWAIT, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if n < 0 {
            resolveFails += 1
            if resolveFails == 8 { _ = resolve() }
            if resolveFails > 8 { resolveFails = 5 }
        } else {
            resolveFails = 0
        }
    }

    private func mapKey(_ kc: Int) -> Int { (kc >= 0 && kc < 128) ? keyMap[kc] : 0 }

    private func sendKey(_ code: Int, _ downNow: Bool, force: Bool = false) {
        if code <= 0 || code > 255 { return }
        let d: UInt8 = downNow ? 1 : 0
        if !force {
            if downNow && down[code] != 0 { return }
            if !downNow && down[code] == 0 { return }
        }
        var b: [UInt8] = [6, 0, 0, d]
        let u = UInt16(code)
        b[1] = UInt8(u & 0xff); b[2] = UInt8(u >> 8)
        let times = downNow ? 1 : 3
        for _ in 0..<times { send(b) }
        down[code] = d
    }

    private func releaseKeys() {
        for i in 1..<256 where down[i] != 0 { sendKey(i, false) }
        down = [UInt8](repeating: 0, count: 256)
    }

    private func sendBtn(_ b: Int, _ downNow: Bool, _ clicks: Int64) {
        if b < 1 || b > 3 { return }
        let d: UInt8 = downNow ? 1 : 0
        let c: UInt8 = clicks < 1 ? 1 : UInt8(min(clicks, 8))
        let pkt: [UInt8] = [4, UInt8(b), d, c]
        send(pkt)
        btn[b] = d
        quietUntil = DispatchTime.now().uptimeNanoseconds + 500_000_000
        accDx = 0
        accDy = 0
    }

    private func releaseButtons() {
        for b in 1...3 { sendBtn(b, false, 1) }
    }

    private func setBridged(_ enable: Bool) {
        if enable == on { return }
        on = enable
        cmdHeld = false
        cmdTab = false
        winDown = false
        lockPointer(enable)
        if !enable {
            releaseButtons()
            releaseKeys()
            send([7])
        }
        postState(enable ? "on" : "wait")
    }

    private func lockPointer(_ enable: Bool) {
        if enable {
            if let e = CGEvent(source: nil) { park = e.location }
            CGAssociateMouseAndMouseCursorPosition(0)
            if !hidden {
                CGDisplayHideCursor(CGMainDisplayID())
                hidden = true
            }
            CGWarpMouseCursorPosition(park)
            CGAssociateMouseAndMouseCursorPosition(0)
        } else {
            Pointer.reset()
            hidden = false
        }
    }

    private func handleFlags(_ kc: Int, _ f: CGEventFlags) {
        var isDown = false
        if kc == 0x38 || kc == 0x3C { isDown = f.contains(.maskShift) }
        else if kc == 0x3B || kc == 0x3E { isDown = f.contains(.maskControl) }
        else if kc == 0x3A || kc == 0x3D { isDown = f.contains(.maskAlternate) }
        else if kc == 0x39 { isDown = f.contains(.maskAlphaShift) }
        else { return }
        sendKey(mapKey(kc), isDown)
    }

    private func handleKey(_ kc: Int, _ isDown: Bool, _ f: CGEventFlags) {
        if f.contains(.maskShift) { if down[42] == 0 { sendKey(42, true) } }
        else { if down[42] != 0 { sendKey(42, false) } }
        if f.contains(.maskControl) { if down[29] == 0 { sendKey(29, true) } }
        else { if down[29] != 0 { sendKey(29, false) } }
        if f.contains(.maskAlternate) { if down[56] == 0 { sendKey(56, true) } }
        else { if down[56] != 0 { sendKey(56, false) } }
        sendKey(mapKey(kc), isDown)
    }

    private var mouseQuiet: Bool { cmdTab }

    private func commandBegin() {
        if cmdHeld { return }
        cmdHeld = true
        cmdTab = false
        winDown = false
    }

    private func commandEnd() {
        if !cmdHeld && !winDown { return }
        cmdHeld = false
        if cmdTab {
            winDown = false
            send([7])
            releaseButtons()
            releaseKeys()
            if on { lockPointer(true) }
            cmdTab = false
            return
        }
        if winDown {
            sendKey(125, false, force: true)
        } else {
            sendKey(125, true, force: true)
            sendKey(125, false, force: true)
        }
        winDown = false
        send([7])
        releaseButtons()
        releaseKeys()
    }

    private func keyEvent(_ type: CGEventType, _ ev: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = keyTap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(ev)
        }
        if !on { return Unmanaged.passUnretained(ev) }
        let f = ev.flags
        if type == .flagsChanged {
            let kc = Int(ev.getIntegerValueField(.keyboardEventKeycode))
            if kc == 0x37 || kc == 0x36 {
                if f.contains(.maskCommand) { commandBegin() }
                else { commandEnd() }
                return Unmanaged.passUnretained(ev)
            }
            handleFlags(kc, f)
            return nil
        }
        if type == .keyDown || type == .keyUp {
            let kc = Int(ev.getIntegerValueField(.keyboardEventKeycode))
            if kc == 0x37 || kc == 0x36 {
                if type == .keyDown { commandBegin() }
                else { commandEnd() }
                return nil
            }
            if (cmdHeld || f.contains(.maskCommand)) && kc == 0x30 {
                cmdTab = true
                if winDown {
                    sendKey(125, false, force: true)
                    winDown = false
                }
                lockPointer(false)
                return Unmanaged.passUnretained(ev)
            }
            if (cmdHeld || f.contains(.maskCommand)) && type == .keyDown && !winDown && !cmdTab {
                sendKey(125, true, force: true)
                winDown = true
            }
            handleKey(kc, type == .keyDown, f)
            return nil
        }
        return Unmanaged.passUnretained(ev)
    }

    private func mouseListenEvent(_ type: CGEventType, _ ev: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = mouseListen { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(ev)
        }
        if !on { return Unmanaged.passUnretained(ev) }
        if mouseQuiet { return Unmanaged.passUnretained(ev) }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            var dx = Int32(ev.getIntegerValueField(.mouseEventDeltaX))
            var dy = Int32(ev.getIntegerValueField(.mouseEventDeltaY))
            if dx != 0 || dy != 0 {
                let held = btn[1] != 0 || btn[2] != 0 || btn[3] != 0
                let t = DispatchTime.now().uptimeNanoseconds
                if t < quietUntil || held {
                    accDx += dx
                    accDy += dy
                    if !held || abs(accDx) + abs(accDy) < 48 {
                        return Unmanaged.passUnretained(ev)
                    }
                    dx = accDx
                    dy = accDy
                    accDx = 0
                    accDy = 0
                    quietUntil = 0
                }
                var b = [UInt8](repeating: 0, count: 9)
                b[0] = 3
                putI32(&b, 1, dx); putI32(&b, 5, dy)
                send(b)
            }
            return Unmanaged.passUnretained(ev)
        case .leftMouseDown, .leftMouseUp:
            sendBtn(1, type == .leftMouseDown, ev.getIntegerValueField(.mouseEventClickState))
            return Unmanaged.passUnretained(ev)
        case .rightMouseDown, .rightMouseUp:
            sendBtn(2, type == .rightMouseDown, ev.getIntegerValueField(.mouseEventClickState))
            return Unmanaged.passUnretained(ev)
        case .otherMouseDown, .otherMouseUp:
            sendBtn(3, type == .otherMouseDown, ev.getIntegerValueField(.mouseEventClickState))
            return Unmanaged.passUnretained(ev)
        case .scrollWheel:
            let d = Int32(ev.getIntegerValueField(.scrollWheelEventDeltaAxis1))
            if d != 0 {
                var b = [UInt8](repeating: 0, count: 5)
                b[0] = 5
                putI32(&b, 1, d)
                send(b)
            }
            return Unmanaged.passUnretained(ev)
        default:
            return Unmanaged.passUnretained(ev)
        }
    }

    private func mouseEatEvent(_ type: CGEventType, _ ev: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = mouseTap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(ev)
        }
        if !on { return Unmanaged.passUnretained(ev) }
        if cmdTab { return Unmanaged.passUnretained(ev) }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
             .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
             .otherMouseDown, .otherMouseUp, .scrollWheel:
            return nil
        default:
            return Unmanaged.passUnretained(ev)
        }
    }

    private func hidValue(_ value: IOHIDValue) {
        _ = value
    }

    private func hidSkip(_ el: IOHIDElement) -> Bool {
        let dev = IOHIDElementGetDevice(el)
        guard let prod = IOHIDDeviceGetProperty(dev, kIOHIDProductKey as CFString) as? String else { return false }
        let n = prod.lowercased()
        return n.contains("karabiner") || n.contains("virtual")
    }

    private enum TapKind { case key, listen, eat }

    private func makeTap2(_ loc: CGEventTapLocation, _ mask: CGEventMask, options: CGEventTapOptions, kind: TapKind) -> CFMachPort? {
        let info = Unmanaged.passUnretained(self).toOpaque()
        let cb: CGEventTapCallBack
        switch kind {
        case .key:
            cb = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<Worker>.fromOpaque(refcon).takeUnretainedValue().keyEvent(type, event)
            }
        case .listen:
            cb = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<Worker>.fromOpaque(refcon).takeUnretainedValue().mouseListenEvent(type, event)
            }
        case .eat:
            cb = { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<Worker>.fromOpaque(refcon).takeUnretainedValue().mouseEatEvent(type, event)
            }
        }
        guard let t = CGEvent.tapCreate(tap: loc, place: .headInsertEventTap, options: options, eventsOfInterest: mask, callback: cb, userInfo: info) else { return nil }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return t
    }

    private func installKeyboard() {
        let km = CGEventMaskBit(.keyDown) | CGEventMaskBit(.keyUp) | CGEventMaskBit(.flagsChanged)
        keyTap = makeTap2(.cgSessionEventTap, km, options: .defaultTap, kind: .key)
    }

    private static func isKikiEye(_ a: NSRunningApplication?) -> Bool {
        guard let a else { return false }
        if (a.bundleIdentifier ?? "").lowercased().contains("kikieye") { return true }
        if (a.localizedName ?? "").lowercased().contains("kikieye") { return true }
        return (a.executableURL?.path ?? "").lowercased().contains("kikieye")
    }

    private func shutdown() {
        if stop { return }
        stop = true
        setBridged(false)
        Karabiner.set(false, wait: true)
        Pointer.reset()
        hidden = false
        if let t = keyTap { CGEvent.tapEnable(tap: t, enable: false) }
        if let t = mouseListen { CGEvent.tapEnable(tap: t, enable: false) }
        if let t = mouseTap { CGEvent.tapEnable(tap: t, enable: false) }
        keyTap = nil; mouseListen = nil; mouseTap = nil
        if let h = hid {
            IOHIDManagerClose(h, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(h, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            hid = nil
        }
        if sock >= 0 { _ = close(sock); sock = -1 }
        if guardFd >= 0 { _ = close(guardFd); guardFd = -1 }
        postState("dead")
        NSApp.stop(nil)
        CFRunLoopStop(CFRunLoopGetMain())
    }

    private func watchParent() {
        let q = DispatchQueue.main
        if parent > 1 {
            let p = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: q)
            p.setEventHandler { [weak self] in self?.shutdown() }
            p.resume()
        }
        if guardFd >= 0 {
            let r = DispatchSource.makeReadSource(fileDescriptor: guardFd, queue: q)
            r.setEventHandler { [weak self] in
                guard let self else { return }
                var buf = [UInt8](repeating: 0, count: 8)
                let n = read(self.guardFd, &buf, 8)
                if n <= 0 { self.shutdown() }
            }
            r.resume()
        }
        signal(SIGTERM, kbIgnoreSignal)
        signal(SIGINT, kbIgnoreSignal)
        signal(SIGHUP, kbIgnoreSignal)
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            let s = DispatchSource.makeSignalSource(signal: sig, queue: q)
            s.setEventHandler { [weak self] in self?.shutdown() }
            s.resume()
        }
    }

    private func postState(_ s: String) {
        let st = s, h = host
        let f = NSWorkspace.shared.frontmostApplication
        let front = f?.localizedName ?? f?.bundleIdentifier ?? ""
        DispatchQueue.main.async {
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name(Tap.note), object: nil,
                userInfo: ["s": st, "host": h, "front": front], deliverImmediately: true
            )
        }
    }
}

private func putI32(_ b: inout [UInt8], _ o: Int, _ v: Int32) {
    b[o] = UInt8(truncatingIfNeeded: v)
    b[o + 1] = UInt8(truncatingIfNeeded: v >> 8)
    b[o + 2] = UInt8(truncatingIfNeeded: v >> 16)
    b[o + 3] = UInt8(truncatingIfNeeded: v >> 24)
}

private func CGEventMaskBit(_ t: CGEventType) -> CGEventMask {
    CGEventMask(1) << CGEventMask(t.rawValue)
}

private let kbIgnoreSignal: @convention(c) (Int32) -> Void = { _ in }

enum Pointer {
    static func reset() {
        CGAssociateMouseAndMouseCursorPosition(1)
        for _ in 0..<16 { CGDisplayShowCursor(CGMainDisplayID()) }
    }
}

enum Karabiner {
    static func set(_ on: Bool, wait: Bool) {
        let bins = [
            "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli",
            "/Applications/Karabiner-Elements.app/Contents/MacOS/karabiner_cli",
        ]
        let json = "{\"kikibridge\":\(on ? 1 : 0)}"
        for bin in bins {
            guard access(bin, X_OK) == 0 else { continue }
            var pid: pid_t = 0
            let args = [bin, "--set-variables", json]
            let argv = args.map { strdup($0) } + [nil]
            defer { argv.forEach { free($0) } }
            bin.withCString { path in
                argv.withUnsafeBufferPointer { buf in
                    _ = posix_spawn(&pid, path, nil, nil, buf.baseAddress, environ)
                }
            }
            if wait { _ = waitpid(pid, nil, 0) }
            break
        }
    }
}

@_silgen_name("CGRequestListenEventAccess")
func CGRequestListenEventAccess() -> Bool
@_silgen_name("CGRequestPostEventAccess")
func CGRequestPostEventAccess() -> Bool
