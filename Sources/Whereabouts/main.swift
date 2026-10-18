import AppKit

if CommandLine.arguments.contains("--selftest") {
    selfTest()
    exit(0)
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}
