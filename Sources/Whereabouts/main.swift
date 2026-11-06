import AppKit

// The app reads and sets the system's time zone, so it must never run on a TZ it inherited:
// started from a terminal in an app on home time, TimeZone.current would report that instead.
unsetenv("TZ")

if CommandLine.arguments.contains("--selftest") {
    Task { @MainActor in await selfTest() }
    dispatchMain()
}

if CommandLine.arguments.contains("--update-selftest") {
    Task { @MainActor in await updateIntegrationTest() }
    dispatchMain()
}

if CommandLine.arguments.contains("--network-selftest") {
    Task { @MainActor in await networkSmokeTest() }
    dispatchMain()
}

if CommandLine.arguments.contains("--firewall-selftest") {
    Task { @MainActor in await liveFirewallTest() }
    dispatchMain()
}

if CommandLine.arguments.contains("--sleep-selftest") {
    Task { @MainActor in await liveSleepTest() }
    dispatchMain()
}

// Chrome passes the calling extension's origin to a native messaging host.
if CommandLine.arguments.dropFirst().first?.hasPrefix("chrome-extension://") == true {
    AlibiHost.serve()
}

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}
