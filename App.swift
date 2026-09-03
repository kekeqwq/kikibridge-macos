import SwiftUI
import AppKit

func kbApplyGlass(_ w: NSWindow) {
    w.titlebarAppearsTransparent = true
    w.titleVisibility = .hidden
    w.styleMask.insert(.fullSizeContentView)
    w.hasShadow = true
    w.isOpaque = false
}

func kbShowInDock() {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate()
}

func kbGirl() -> NSImage? {
    bundleImage("girl")
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
            if v is NSTextField || v is NSTextView { return }
            v.focusRingType = .none
            if let c = v as? NSControl, !(c is NSTextField) {
                c.refusesFirstResponder = true
                c.focusRingType = .none
            }
            for c in v.subviews { walk(c) }
        }
        walk(host)
        if let win = window {
            if win.firstResponder is NSTextView || win.firstResponder is NSTextField { return }
            if win.firstResponder is NSControl {
                win.makeFirstResponder(nil)
            }
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
            if let img = kbGirl() {
                Image(nsImage: img)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 128, height: 128)
            }
            Text("点选对端，再开桥。⌘Tab 切走即回本机。退出本程序会关掉桥。")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Picker("", selection: $bridge.pick) {
                Text("deck").tag("deck")
                Text("pc").tag("pc")
                Text("surface").tag("surface")
                Text("自定义").tag("custom")
            }
            .pickerStyle(.tabs)
            .controlSize(.extraLarge)
            .font(.title3.weight(.medium))
            .labelsHidden()
            .focusEffectDisabled()
            .fixedSize()
            .background { TabPolish() }
            .onChange(of: bridge.pick) { _, _ in
                bridge.hostChanged()
            }

            if bridge.pick == "custom" {
                TextField("主机名", text: $bridge.custom)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.large)
                    .font(.body)
                    .frame(width: 240)
                    .disabled(bridge.running)
                    .onSubmit { bridge.hostChanged() }
                    .onChange(of: bridge.custom) { _, _ in
                        UserDefaults.standard.set(bridge.custom, forKey: "customHost")
                    }
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
            if let img = kbGirl() {
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
            VStack(spacing: 6) {
                Text("管理器。抓键鼠的是 --tap 子进程，退出即带走。")
                Text("KikiEye 在前台时透传到所选主机。")
                Text("更新日期 \(kUpdated)  ·  GPL-3.0-or-later")
                Text("Copyright © 2026 KikiBridge contributors")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 360)
        }
        .padding(32)
        .frame(minWidth: 420, minHeight: 320)
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
        kbShowInDock()
    }

    private func openAbout() {
        openWindow(id: "about")
        kbShowInDock()
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
        kbShowInDock()
    }

    private func openAbout() {
        openWindow(id: "about")
        kbShowInDock()
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
