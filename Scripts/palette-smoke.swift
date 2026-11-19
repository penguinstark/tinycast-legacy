import AppKit
import CoreGraphics

// Exercises the palette summon path against a built app, using only window metadata and the URL
// scheme — no Accessibility or Screen Recording grant. It quits any running copy first.
//   swiftc -swift-version 6 Scripts/palette-smoke.swift -o /tmp/palette-smoke
//   /tmp/palette-smoke ~/Applications/"Tinycast Sonoma Dev.app" tinycast-sonoma-dev

@MainActor var failures = 0

@MainActor
func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
    print("\(passed ? "PASS" : "FAIL")  \(name)\(detail().isEmpty ? "" : " — \(detail())")")
    if !passed { failures += 1 }
}

@MainActor
func exec(_ path: String, _ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

@MainActor
func wait(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

struct Window {
    let layer: Int
    let alpha: Double
    let onscreen: Bool
    let bounds: CGRect
    // Every interface size draws the panel at least 750pt wide; a HUD toast is much narrower.
    var isPalette: Bool { layer == 9 && bounds.width >= 700 && bounds.height > 20 }
    var isStatusItem: Bool { layer == 25 }
}

@MainActor
final class Smoke {
    let appPath: String
    let scheme: String
    let bundle: Bundle
    let bundleID: String

    init(appPath: String, scheme: String) {
        self.appPath = appPath
        self.scheme = scheme
        bundle = Bundle(path: appPath)!
        bundleID = bundle.bundleIdentifier!
    }

    func running() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    func frontmost() -> String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
    }

    func windows() -> [Window] {
        guard let pid = running()?.processIdentifier else { return [] }
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { return nil }
            return Window(
                layer: info[kCGWindowLayer as String] as? Int ?? 0,
                alpha: info[kCGWindowAlpha as String] as? Double ?? 1,
                onscreen: info[kCGWindowIsOnscreen as String] as? Bool ?? false,
                bounds: bounds)
        }
    }

    func palette() -> Window? {
        windows().first { $0.isPalette && $0.onscreen }
    }

    func summon() { _ = exec("/usr/bin/open", ["-a", appPath, "\(scheme)://search"]) }

    func summonFromTerminal() -> Window? {
        _ = exec("/usr/bin/open", ["-a", "Terminal"])
        wait(0.8)
        check("palette is hidden while Terminal is front", palette() == nil)
        summon()
        var found: Window?
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, found == nil {
            found = palette()
            if found == nil { wait(0.01) }
        }
        guard let found else { return nil }
        // The first frame can settle for a moment, and activation can race an outside summon.
        wait(0.25)
        if let settled = palette() { return settled }
        summon()
        wait(0.4)
        return palette() ?? found
    }

    func runChecks() {
        _ = exec("/usr/bin/open", ["-a", "Terminal"])
        wait(1)
        if let existing = running() {
            existing.terminate()
            wait(2)
        }
        check("no instance before launch", running() == nil)

        let before = frontmost()
        // `-g -j` takes the login-item path: background launch, no launch-time show.
        check("launched in background", exec("/usr/bin/open", ["-g", "-j", appPath]) == 0)
        // Prewarm lands one second after start.
        wait(4)
        check("process alive after launch", running()?.isTerminated == false)
        check("prewarm leaves focus alone", frontmost() == before, "\(frontmost()) vs \(before)")
        let visible = windows().filter { $0.onscreen && !$0.isStatusItem }
        check("prewarm leaves no window visible", visible.isEmpty, "\(visible)")

        // One activation settles LaunchServices, so later summons stay in the background.
        _ = exec("/usr/bin/open", ["-a", appPath])
        wait(2)
        _ = exec("/usr/bin/open", ["-a", "Terminal"])
        wait(1)

        var frames: [CGRect] = []
        for cycle in 1...10 {
            guard let found = summonFromTerminal() else {
                check("cycle \(cycle): palette appears", false)
                continue
            }
            frames.append(found.bounds)
            let screens = NSScreen.screens.map(\.frame)
            let union = screens.dropFirst().reduce(screens.first ?? .zero) { $0.union($1) }
            let fits =
                found.bounds.minX >= 0 && found.bounds.minY >= 0
                && found.bounds.maxX <= union.maxX + 1 && found.bounds.maxY <= union.maxY + 1
            check("cycle \(cycle): palette is on screen", fits, "\(found.bounds)")
            check("cycle \(cycle): palette is opaque", found.alpha > 0.99, "alpha \(found.alpha)")
        }
        check("palette appeared on every cycle", frames.count == 10, "\(frames.count)/10")
        if let first = frames.first {
            check(
                "every summon lands on the same frame",
                frames.allSatisfy {
                    abs($0.minX - first.minX) < 1 && abs($0.minY - first.minY) < 1
                        && abs($0.width - first.width) < 1 && abs($0.height - first.height) < 1
                },
                "\(first)")
        }
        check("no crash", running()?.isTerminated == false)

        _ = exec("/usr/bin/open", ["-a", "Terminal"])
        wait(1)
        check("closing leaves no palette window", palette() == nil)
        check("closing returns focus", frontmost() == before, "\(frontmost())")
        running()?.terminate()
    }
}

@main
struct Entry {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 2 else {
            print("usage: palette-smoke <path to .app> <url scheme>")
            exit(2)
        }
        Smoke(appPath: args[1], scheme: args[2]).runChecks()
        print(failures == 0 ? "\nSMOKE PASSED" : "\nSMOKE FAILED (\(failures))")
        exit(failures == 0 ? 0 : 1)
    }
}
