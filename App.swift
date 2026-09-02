import SwiftUI
import AppKit

func kbApplyGlass(_ w: NSWindow) {
    w.titlebarAppearsTransparent = true
    w.titleVisibility = .hidden
    w.styleMask.insert(.fullSizeContentView)
    w.hasShadow = true
    w.isOpaque = false
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let bridge = Bridge()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { n in
            guard let w = n.object as? NSWindow else { return }
            if w.styleMask.contains(.nonactivatingPanel) { return }
            if w.className.contains("StatusBar") || w.className.contains("NSStatus") { return }
            kbApplyGlass(w)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        bridge.stop()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge.stop()
        Pointer.reset()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .kbShowPanel, object: nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension Notification.Name {
    static let kbShowPanel = Notification.Name("kb.showPanel")
    static let kbShowAbout = Notification.Name("kb.showAbout")
}

/// Strip the accent-color focus ring without disabling click/drag.
final class Polisher: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        polish()
    }
    override func layout() {
        super.layout()
        polish()
    }
    func polish() {
        guard let host = superview else { return }
        func walk(_ v: NSView) {
            v.focusRingType = .none
            if let c = v as? NSControl {
                c.refusesFirstResponder = true
                c.focusRingType = .none
            }
            for c in v.subviews { walk(c) }
        }
        walk(host)
        if let win = window, win.firstResponder is NSControl {
            win.makeFirstResponder(nil)
        }
    }
}

struct TabPolish: NSViewRepresentable {
    func makeNSView(context: Context) -> Polisher { Polisher() }
    func updateNSView(_ v: Polisher, context: Context) { v.polish() }
}

@available(macOS 27.0, *)
struct PanelView: View {
    @EnvironmentObject var bridge: Bridge

    var body: some View {
        VStack(spacing: 22) {
            if let img = bundleImage("kikibridge") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 380, height: 190)
            }
            Text("点选对端，再开桥。⌘Tab 切走即回本机。退出本程序会关掉桥。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Picker("", selection: $bridge.host) {
                Text("deck").tag("deck")
                Text("pc").tag("pc")
                Text("surface").tag("surface")
            }
            .pickerStyle(.tabs)
            .controlSize(.extraLarge)
            .font(.title3.weight(.medium))
            .labelsHidden()
            .focusEffectDisabled()
            .fixedSize()
            .background { TabPolish() }
            .onChange(of: bridge.host) { _, _ in
                bridge.hostChanged()
            }

            Button {
                bridge.toggle()
            } label: {
                Text(bridge.goTitle)
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 10)
            }
            .buttonStyle(.glass)
            .controlSize(.regular)
            .buttonBorderShape(.capsule)
            .glassEffect(.regular.interactive(), in: .capsule)
            .focusEffectDisabled()

            Text(bridge.status)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: 460)
        .containerBackground(.regularMaterial, for: .window)
        .onAppear {
            NSApp.windows.filter { $0.identifier?.rawValue == "panel" }.forEach { w in
                kbApplyGlass(w)
                w.makeFirstResponder(nil)
            }
        }
    }
}

@available(macOS 27.0, *)
struct AboutView: View {
    var body: some View {
        VStack(spacing: 12) {
            if let img = bundleImage("girl") ?? bundleImage("icon") {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 128, height: 128)
            }
            Text("KikiBridge").font(.title2).fontWeight(.semibold)
            Text("版本 \(kVersion)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("管理器。真正抓键鼠的是子进程（同一条二进制 --tap），随本程序退出（含崩溃/强制退出）。\nKikiEye 前台时透传到 deck / pc / surface。\n\n更新日期  \(kUpdated)\n许可证  GPL-3.0-or-later\nCopyright © 2026 KikiBridge contributors")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .padding(32)
        .frame(width: 420)
        .containerBackground(.regularMaterial, for: .window)
        .onAppear {
            NSApp.windows.filter { $0.identifier?.rawValue == "about" }.forEach(kbApplyGlass)
        }
    }
}

@available(macOS 27.0, *)
struct TrayLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let img = bundleImage("kikibridge-template") {
                Image(nsImage: templated(img))
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 16, weight: .semibold))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("org.kikibridge.gui.show"))) { _ in
            openPanel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kbShowPanel)) { _ in openPanel() }
        .onReceive(NotificationCenter.default.publisher(for: .kbShowAbout)) { _ in openAbout() }
    }

    private func openPanel() {
        openWindow(id: "panel")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    private func openAbout() {
        openWindow(id: "about")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    private func templated(_ img: NSImage) -> NSImage {
        let copy = img.copy() as? NSImage ?? img
        copy.isTemplate = true
        copy.size = NSSize(width: 24, height: 24)
        return copy
    }
}

@available(macOS 27.0, *)
struct TrayMenu: View {
    @ObservedObject var bridge: Bridge
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("打开面板") { openPanel() }
        Button(bridge.running ? "停止" : "启动") { bridge.toggle() }
        Divider()
        Button("关于 KikiBridge") { openAbout() }
        Divider()
        Button("退出") {
            bridge.stop()
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func openPanel() {
        openWindow(id: "panel")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    private func openAbout() {
        openWindow(id: "about")
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

@available(macOS 27.0, *)
struct KikiBridgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            TrayMenu(bridge: appDelegate.bridge)
        } label: {
            TrayLabel()
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("关于 KikiBridge") {
                    NotificationCenter.default.post(name: .kbShowAbout, object: nil)
                }
            }
        }

        Window("KikiBridge", id: "panel") {
            PanelView()
                .environmentObject(appDelegate.bridge)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("关于 KikiBridge", id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
