import AppKit
import Foundation
import SystemConfiguration

// Network changes are a prompt to ask Cisco again, never evidence that its
// session changed. A quiet Cisco-only transition still reaches the 1m poll.
private let pluginName = CommandLine.arguments.dropFirst().first ?? "vpn-eta"
private var pendingRefresh: DispatchWorkItem?

private func refresh() {
    if let sink = ProcessInfo.processInfo.environment["VPN_ETA_REFRESH_SINK"] {
        let line = "swiftbar://refreshplugin?name=\(pluginName)\n"
        if let handle = FileHandle(forWritingAtPath: sink) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        }
        return
    }
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.ameba.SwiftBar").isEmpty else {
        return
    }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    guard let encoded = pluginName.addingPercentEncoding(withAllowedCharacters: allowed) else { return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "swiftbar://refreshplugin?name=\(encoded)"]
    try? process.run()
}

private func scheduleRefresh() {
    pendingRefresh?.cancel()
    let request = DispatchWorkItem(block: refresh)
    pendingRefresh = request
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: request)
}

private func changed(_ store: SCDynamicStore, _ keys: CFArray, _ info: UnsafeMutableRawPointer?) {
    scheduleRefresh()
}

if CommandLine.arguments.contains("--test-event") {
    refresh()
    exit(0)
}
if CommandLine.arguments.contains("--test-burst") {
    for _ in 0..<3 { scheduleRefresh() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.7))
    exit(0)
}

guard let store = SCDynamicStoreCreate(nil, "vpn-eta network watch" as CFString, changed, nil) else {
    fputs("Could not observe network state\n", stderr)
    exit(1)
}
let patterns = [
    "State:/Network/Interface/.*/IPv4",
    "State:/Network/Interface/.*/IPv6",
    "State:/Network/Global/IPv4",
    "State:/Network/Global/IPv6",
] as CFArray
guard SCDynamicStoreSetNotificationKeys(store, nil, patterns),
      SCDynamicStoreSetDispatchQueue(store, DispatchQueue.main) else {
    fputs("Could not subscribe to network changes\n", stderr)
    exit(1)
}
RunLoop.main.run()
