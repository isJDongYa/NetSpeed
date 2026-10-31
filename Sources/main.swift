import AppKit
import ServiceManagement

if CommandLine.arguments.contains("--self-test") {
    do {
        try runSelfTests()
        MainActor.assumeIsolated { runStatusLayoutChecks() }
    }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
} else if let flag = CommandLine.arguments.firstIndex(of: "--render-layout"), flag + 1 < CommandLine.arguments.count {
    MainActor.assumeIsolated { runStatusLayoutChecks(previewPath: CommandLine.arguments[flag + 1]) }
} else if CommandLine.arguments.contains("--sample") {
    var calculator = RateCalculator()
    let count = CommandLine.arguments.last.flatMap(Int.init) ?? 5
    for index in 0..<max(2, min(60, count)) {
        do {
            let snapshot = try NetworkReader.snapshot()
            let name = NetworkReader.primaryInterface(in: snapshot)
            let rate = calculator.update(name.flatMap { snapshot[$0] }, at: ProcessInfo.processInfo.systemUptime)
            let json: [String: Any] = [
                "interface": name ?? "none",
                "download_Bps": rate?.download ?? 0,
                "upload_Bps": rate?.upload ?? 0,
                "baseline": rate == nil,
                "received_bytes": name.flatMap { snapshot[$0]?.received } ?? 0,
                "sent_bytes": name.flatMap { snapshot[$0]?.sent } ?? 0
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        } catch { fputs("ERROR: \(error)\n", stderr); exit(1) }
        if index < count - 1 { Thread.sleep(forTimeInterval: 1) }
    }
} else if CommandLine.arguments.contains("--login-status") {
    print("login-item-status: \(SMAppService.mainApp.status.rawValue)")
} else {
    MainActor.assumeIsolated {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
