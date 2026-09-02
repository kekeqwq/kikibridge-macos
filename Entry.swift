import AppKit
import Darwin
import Foundation

@available(macOS 27.0, *)
@main
enum KikiBridgeMain {
    static func main() {
        let args = CommandLine.arguments
        if args.dropFirst().first == "--unlock" {
            exit(Tap.unlock())
        }
        if args.dropFirst().contains("--tap") {
            exit(Tap.run(arguments: args))
        }
        let me = getpid()
        let bid = "org.kikibridge.KikiBridge"
        for a in NSRunningApplication.runningApplications(withBundleIdentifier: bid) {
            if a.processIdentifier == me { continue }
            if pidHasTapArg(a.processIdentifier) {
                _ = kill(a.processIdentifier, SIGTERM)
                continue
            }
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("org.kikibridge.gui.show"),
                object: nil, userInfo: nil, deliverImmediately: true
            )
            return
        }
        KikiBridgeApp.main()
    }
}
