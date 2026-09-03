import AppKit
import ApplicationServices
import Darwin
import Foundation
import MachO

let kVersion = "0.7.28"
let kUpdated = "2026-09-02"
let kPort: UInt16 = 5000

func bundleImage(_ name: String) -> NSImage? {
    let res = Bundle.main.resourceURL
    let cands = [
        res?.appendingPathComponent("\(name).png"),
        res?.appendingPathComponent("AppIcon.icon/Assets/\(name).png"),
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("\(name).png"),
    ]
    for u in cands {
        guard let u, FileManager.default.fileExists(atPath: u.path),
              let img = NSImage(contentsOf: u) else { continue }
        return img
    }
    return nil
}

func selfPath() -> String? {
    var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
    var n = UInt32(buf.count)
    if _NSGetExecutablePath(&buf, &n) != 0 { return nil }
    return String(cString: buf).withCString { p in
        var real = [CChar](repeating: 0, count: Int(PATH_MAX))
        if realpath(p, &real) != nil { return String(cString: real) }
        return String(cString: p)
    }
}

func pidHasTapArg(_ pid: pid_t) -> Bool {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var sz = 0
    if sysctl(&mib, 3, nil, &sz, nil, 0) < 0 || sz < 8 { return false }
    var buf = [UInt8](repeating: 0, count: sz + 1)
    if sysctl(&mib, 3, &buf, &sz, nil, 0) < 0 { return false }
    var argc: Int32 = 0
    buf.withUnsafeBytes { raw in
        _ = memcpy(&argc, raw.baseAddress, MemoryLayout<Int32>.size)
    }
    var i = MemoryLayout<Int32>.size
    while i < sz && buf[i] != 0 { i += 1 }
    i += 1
    var n = 0
    while n < Int(argc) && i < sz {
        var s = ""
        while i < sz && buf[i] != 0 {
            s.append(Character(UnicodeScalar(buf[i])))
            i += 1
        }
        if s == "--tap" { return true }
        i += 1
        n += 1
    }
    return false
}

func probeHost(_ name: String) -> (ip: String?, warning: String?, error: String?) {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_DGRAM
    var res: UnsafeMutablePointer<addrinfo>?
    let port = "\(kPort)"
    var rc = getaddrinfo(name, port, &hints, &res)
    var used = name
    if rc != 0 || res == nil {
        used = "\(name).local"
        rc = getaddrinfo(used, port, &hints, &res)
    }
    guard rc == 0, let r = res else {
        return (nil, nil, "无法解析 \(name) 或 \(name).local（\(String(cString: gai_strerror(rc)))）。对端没在同一局域网，或主机名不是 deck/pc/surface。")
    }
    defer { freeaddrinfo(r) }
    var ipbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    r.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
        var a = sin.pointee.sin_addr
        _ = inet_ntop(AF_INET, &a, &ipbuf, socklen_t(INET_ADDRSTRLEN))
    }
    let ip = String(cString: ipbuf)
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    if fd < 0 { return (nil, nil, "无法创建 UDP socket") }
    var tv = timeval(tv_sec: 0, tv_usec: 200_000)
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var probe: UInt8 = 1
    var pong: UInt8 = 0
    var ok = false
    for _ in 0..<10 {
        _ = sendto(fd, &probe, 1, 0, r.pointee.ai_addr, r.pointee.ai_addrlen)
        var from = sockaddr_storage()
        var flen = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &from) { fp in
            fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                recvfrom(fd, &pong, 1, 0, sp, &flen)
            }
        }
        if n == 1 && pong == 2 {
            ok = true
            break
        }
    }
    _ = close(fd)
    if !ok {
        return (nil, nil, "\(used)（\(ip):\(kPort)）没有回应。对端没开机、receiver 没开，或防火墙拦了 UDP 5000。开机完成后再点启动。")
    }
    return (ip, nil, nil)
}

func spawnTap(path: String, host: String) throws -> (pid: pid_t, fd: Int32) {
    var fds: [Int32] = [0, 0]
    if pipe(&fds) != 0 { throw SpawnError.pipe }
    _ = fcntl(fds[0], F_SETFD, 0)
    _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
    var fa: posix_spawn_file_actions_t?
    _ = posix_spawn_file_actions_init(&fa)
    _ = posix_spawn_file_actions_adddup2(&fa, fds[0], 3)
    _ = posix_spawn_file_actions_addclose(&fa, fds[0])
    _ = posix_spawn_file_actions_addclose(&fa, fds[1])
    let args = [path, "--tap", "--host", host, "--guard-fd", "3", "--parent-pid", String(getpid())]
    let argv = args.map { strdup($0) } + [nil]
    defer { argv.forEach { free($0) } }
    var pid: pid_t = 0
    let rc = path.withCString { cpath in
        argv.withUnsafeBufferPointer { buf in
            posix_spawn(&pid, cpath, &fa, nil, buf.baseAddress, environ)
        }
    }
    _ = posix_spawn_file_actions_destroy(&fa)
    _ = close(fds[0])
    if rc != 0 {
        _ = close(fds[1])
        throw SpawnError.posix(rc)
    }
    return (pid, fds[1])
}

func reapTap(pid: pid_t, fd: Int32) {
    if fd >= 0 { _ = close(fd) }
    if pid == 0 { return }
    var st: Int32 = 0
    var r: pid_t = 0
    for _ in 0..<50 {
        r = waitpid(pid, &st, WNOHANG)
        if r != 0 { break }
        usleep(20_000)
    }
    if r == 0 {
        _ = kill(pid, SIGTERM)
        for _ in 0..<25 {
            r = waitpid(pid, &st, WNOHANG)
            if r != 0 { break }
            usleep(20_000)
        }
    }
    if r == 0 {
        _ = kill(pid, SIGKILL)
        _ = waitpid(pid, &st, 0)
    }
}

enum SpawnError: Error {
    case pipe
    case posix(Int32)
}

/// Darwin wait(2) status. Swift cannot import WIFEXITED / WTERMSIG (function-like macros).
func waitExitCode(_ st: Int32) -> Int32 {
    let wstatus = st & 0x7f
    if wstatus == 0 { return (st >> 8) & 0xff }
    if wstatus != 0x7f { return 128 + wstatus }
    return 0
}

@MainActor
final class Bridge: ObservableObject {
    @Published var host: String
    @Published var pick: String
    @Published var custom: String
    @Published var running = false
    @Published var status = "已停止"
    @Published var goTitle = "启动"

    private var peerIP: String?
    private var tapState: String?
    private var front: String?
    private var child: pid_t = 0
    private var guardWr: Int32 = -1
    private var childSrc: DispatchSourceProcess?
    private var pingSrc: DispatchSourceTimer?
    private var pingFd: Int32 = -1
    private var pingAddr = sockaddr_in()
    private var pingLast: UInt64 = 0
    private var lostTold = false

    init() {
        let h = UserDefaults.standard.string(forKey: "host") ?? "deck"
        let c = UserDefaults.standard.string(forKey: "customHost") ?? ""
        custom = c
        if ["deck", "pc", "surface"].contains(h) {
            pick = h
            host = h
        } else {
            pick = "custom"
            host = h
            if custom.isEmpty { custom = h }
        }
        Pointer.reset()
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(Tap.note), object: nil, queue: .main
        ) { [weak self] n in
            Task { @MainActor in self?.tapNote(n) }
        }
    }

    func targetHost() -> String {
        if pick == "custom" {
            return custom.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return pick
    }

    func hostChanged() {
        let t = targetHost()
        if !t.isEmpty { host = t }
        UserDefaults.standard.set(host, forKey: "host")
        UserDefaults.standard.set(pick, forKey: "hostPick")
        UserDefaults.standard.set(custom, forKey: "customHost")
        if running {
            if targetHost().isEmpty { return }
            stop()
            start()
        }
    }

    func toggle() { running ? stop() : start() }

    func start() {
        if child != 0 { return }
        let name = targetHost()
        if name.isEmpty {
            alert("没有主机名", "自定义里填对端主机名，再点启动。")
            return
        }
        host = name
        lostTold = false
        let p = probeHost(name)
        if let err = p.error {
            alert("对端不通，未启动桥", err)
            return
        }
        guard let ip = p.ip else { return }
        peerIP = ip
        if !Karabiner.ensureRule() {
            let a = NSAlert()
            a.messageText = "先在 Karabiner 里启用规则"
            a.informativeText = """
            已复制到剪贴板。

            1. Complex Modifications
            2. Add your own rule（不是 Add predefined rule）
            3. 粘贴（⌘V）→ Save

            保存后再点启动。
            """
            a.addButton(withTitle: "打开 Karabiner")
            a.addButton(withTitle: "已经保存，继续")
            a.addButton(withTitle: "取消")
            let r = a.runModal()
            if r == .alertFirstButtonReturn {
                Karabiner.openSettings()
                peerIP = nil
                return
            }
            if r != .alertSecondButtonReturn {
                peerIP = nil
                return
            }
        }
        Karabiner.set(true, wait: false)
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            alert("需要辅助功能", "系统设置 → 隐私与安全性 → 辅助功能，勾选终端（nix run）或 KikiBridge，然后重新点启动。")
            peerIP = nil
            return
        }
        _ = CGRequestListenEventAccess()
        _ = CGRequestPostEventAccess()
        guard let tap = selfPath() else {
            alert("找不到本程序路径", "")
            return
        }
        do {
            let s = try spawnTap(path: tap, host: ip)
            guardWr = s.fd
            child = s.pid
            tapState = "wait"
            watch(s.pid)
            startPing(ip)
            paint()
        } catch {
            alert("无法启动桥", "\(error)")
        }
    }

    func stop() {
        stopPing()
        let pid = child
        let wr = guardWr
        guardWr = -1
        childSrc?.cancel()
        childSrc = nil
        reapTap(pid: pid, fd: wr)
        child = 0
        tapState = nil
        peerIP = nil
        Pointer.reset()
        paint()
    }

    private func watch(_ pid: pid_t) {
        childSrc?.cancel()
        let src = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        src.setEventHandler { [weak self] in
            var st: Int32 = 0
            _ = waitpid(pid, &st, WNOHANG)
            Task { @MainActor in self?.childExited(st) }
        }
        src.resume()
        childSrc = src
    }

    private func childExited(_ st: Int32) {
        childSrc?.cancel()
        childSrc = nil
        stopPing()
        child = 0
        if guardWr >= 0 { _ = close(guardWr); guardWr = -1 }
        tapState = nil
        peerIP = nil
        Pointer.reset()
        paint()
        let code = waitExitCode(st)
        if code == 0 || code == 128 + SIGTERM { return }
        if code == 8 {
            peerGone()
            return
        }
        var msg = "桥意外退出"
        if code == 2 { msg = "辅助功能未授权，子进程已退出。" }
        else if code == 3 { msg = "无法安装事件钩子。" }
        else if code == 6 { msg = "输入监控未生效。系统设置 → 隐私 → 输入监控，勾选 KikiBridge 或终端后再开。" }
        else if code == 4 { msg = "无法解析主机 \(host)" }
        else if code == 1 { msg = "子进程拒绝在无父进程时运行。" }
        alert("KikiBridge", "\(msg)（code \(code)）")
    }

    private func tapNote(_ n: Notification) {
        guard let info = n.userInfo else { return }
        let s = info["s"] as? String
        if s == "dead" { return }
        if s == "lost" {
            peerGone()
            return
        }
        tapState = s
        if let f = info["front"] as? String { front = f }
        paint()
    }

    private func peerGone() {
        if lostTold && child == 0 { return }
        lostTold = true
        stop()
        alert("对端离线，已停止", "\(host) 没有回应。开机完成后再点启动。")
    }

    private func startPing(_ ip: String) {
        stopPing()
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        if fd < 0 { return }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(kPort).bigEndian)
        _ = ip.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
        pingAddr = addr
        pingFd = fd
        pingLast = DispatchTime.now().uptimeNanoseconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(400), repeating: 1, leeway: .milliseconds(50))
        t.setEventHandler { [weak self] in self?.pingTick() }
        t.resume()
        pingSrc = t
    }

    private func pingTick() {
        if child == 0 || pingFd < 0 { return }
        var one: UInt8 = 1
        _ = withUnsafePointer(to: &pingAddr) { ap in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                sendto(self.pingFd, &one, 1, 0, sp, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var buf: UInt8 = 0
        var from = sockaddr_in()
        var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
        while true {
            let n = withUnsafeMutablePointer(to: &from) { fp in
                fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                    recvfrom(self.pingFd, &buf, 1, MSG_DONTWAIT, sp, &flen)
                }
            }
            if n <= 0 { break }
            if buf == 2 { pingLast = DispatchTime.now().uptimeNanoseconds }
        }
        let age = DispatchTime.now().uptimeNanoseconds &- pingLast
        if age > 3_000_000_000 {
            peerGone()
        }
    }

    private func stopPing() {
        pingSrc?.cancel()
        pingSrc = nil
        if pingFd >= 0 { _ = close(pingFd); pingFd = -1 }
    }

    private func paint() {
        running = child != 0
        if !running {
            status = "已停止"
            goTitle = "启动"
            return
        }
        goTitle = "停止"
        let peer = peerIP.map { "\(host) (\($0):\(kPort))" } ?? host
        if tapState == "on" { status = "透传中 → \(peer)" }
        else if let front, !front.isEmpty { status = "等待 KikiEye · \(peer)  当前 \(front)" }
        else { status = "等待 KikiEye · \(peer)" }
    }

    private func alert(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.runModal()
    }
}
