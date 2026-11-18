// builtin-display — turn a MacBook's built-in display off/on (Apple Silicon).
//
// Usage:
//   builtin-display list    show online displays (read-only)
//   builtin-display off     disable the built-in panel (needs an external display)
//   builtin-display on      re-enable it and keep it on until the next `off`
//   builtin-display watch   stay running; disable the built-in panel whenever it
//                           comes back (login, wake, monitor replug) — used by
//                           the LaunchAgent local.builtin-display
//   builtin-display check   one quiet attempt that honours `on`; run by `watch`
//
// Uses the private CoreGraphics call CGSConfigureDisplayEnabled, the same
// mechanism display utilities use for "disconnect display".
//
// Why `watch` hands the work to a child process: a process that has disabled
// the display itself never sees it come back (its CoreGraphics display list
// stops updating), and display-reconfiguration callbacks are not delivered to
// a plain command-line process. So `watch` only observes, by polling, and
// starts a fresh `check` process each time there is something to do.

import CoreGraphics
import Foundation

@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ config: CGDisplayConfigRef?, _ display: CGDirectDisplayID, _ enabled: Bool) -> CGError

setvbuf(stdout, nil, _IOLBF, 0)

let home = FileManager.default.homeDirectoryForCurrentUser
let stateFile = home.appendingPathComponent(".builtin-display-id")       // last known built-in id
let keepOnFile = home.appendingPathComponent(".builtin-display-keep-on") // set by `on`, pauses `watch`

func onlineDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

func builtinDisplay() -> CGDirectDisplayID? {
    onlineDisplays().first { CGDisplayIsBuiltin($0) != 0 }
}

func activeExternals() -> [CGDirectDisplayID] {
    onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0 }
}

func keptOn() -> Bool {
    FileManager.default.fileExists(atPath: keepOnFile.path)
}

func setEnabled(_ id: CGDirectDisplayID, _ enabled: Bool) -> Bool {
    var config: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&config) == .success else { return false }
    let err = CGSConfigureDisplayEnabled(config, id, enabled)
    guard err == .success else {
        CGCancelDisplayConfiguration(config)
        fputs("CGSConfigureDisplayEnabled failed: \(err.rawValue)\n", stderr)
        return false
    }
    return CGCompleteDisplayConfiguration(config, .forSession) == .success
}

enum OffResult { case done, alreadyOff, noExternal, failed }

func turnOff() -> OffResult {
    guard let id = builtinDisplay() else { return .alreadyOff }
    // Never leave the Mac with no screen at all.
    guard !activeExternals().isEmpty else { return .noExternal }
    try? String(id).write(to: stateFile, atomically: true, encoding: .utf8)
    return setEnabled(id, false) ? .done : .failed
}

// MARK: watch mode

var runningCheck: Process?
var checkStarted = Date.distantPast
var nextCheckAllowed = Date.distantPast
var sightings = 0

// Start `builtin-display check` as a fresh process. It writes to the same log.
func runCheck(_ reason: String) {
    guard runningCheck == nil, Date() >= nextCheckAllowed else { return }
    let child = Process()
    child.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["check", reason]
    child.terminationHandler = { finished in
        let failed = finished.terminationStatus != 0
        DispatchQueue.main.async {
            runningCheck = nil
            // After a failure, wait before retrying so a persistent error can't spin.
            nextCheckAllowed = Date().addingTimeInterval(failed ? 30 : 2)
        }
    }
    do {
        try child.run()
        runningCheck = child
        checkStarted = Date()
    } catch {
        print("\(Date()) \(reason): could not start check: \(error.localizedDescription)")
        nextCheckAllowed = Date().addingTimeInterval(30)
    }
}

// MARK: commands

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "list"

switch cmd {
case "list":
    let displays = onlineDisplays()
    for id in displays {
        let b = CGDisplayBounds(id)
        print("id \(id)\t\(CGDisplayIsBuiltin(id) != 0 ? "built-in" : "external")\t" +
              "\(Int(b.width))x\(Int(b.height)) at (\(Int(b.origin.x)),\(Int(b.origin.y)))" +
              "\(CGDisplayIsMain(id) != 0 ? "\tmain" : "")")
    }
    if builtinDisplay() == nil { print("Built-in display: off") }
    if keptOn() {
        print("Kept on by `builtin-display on`; run `builtin-display off` to resume auto-off.")
    }

case "off":
    try? FileManager.default.removeItem(at: keepOnFile)
    switch turnOff() {
    case .done: print("Built-in display disabled.")
    case .alreadyOff: print("Built-in display is already off.")
    case .noExternal:
        fputs("Refusing: no active external display, you'd have no screen at all.\n", stderr)
        exit(1)
    case .failed: exit(1)
    }

case "on":
    FileManager.default.createFile(atPath: keepOnFile.path, contents: nil)
    if let id = builtinDisplay() {
        print("Built-in display \(id) is already on. Auto-off paused until `builtin-display off`.")
        exit(0)
    }
    let saved = (try? String(contentsOf: stateFile, encoding: .utf8))
        .flatMap { CGDirectDisplayID($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    let id = saved ?? 1  // the built-in panel is usually display 1 on Apple Silicon
    if setEnabled(id, true) {
        print("Built-in display \(id) enabled. Auto-off paused until `builtin-display off`.")
    } else { exit(1) }

case "check":
    // One attempt in a fresh process, logged only when it does something.
    if keptOn() { exit(0) }
    let reason = args.dropFirst().first ?? "check"
    switch turnOff() {
    case .done: print("\(Date()) \(reason): built-in display disabled")
    case .failed:
        print("\(Date()) \(reason): failed to disable built-in display")
        exit(1)
    case .alreadyOff, .noExternal: break
    }

case "watch":
    // Read-only poll; this process never changes the display configuration, so
    // its view stays current. Two sightings in a row (about 2 s apart) give
    // the displays time to settle after a wake.
    let poll = Timer(timeInterval: 2, repeats: true) { _ in
        if let child = runningCheck, Date().timeIntervalSince(checkStarted) > 20 {
            child.terminate()  // a stuck check must not stop the watcher for good
        }
        let wanted = !keptOn() && builtinDisplay() != nil && !activeExternals().isEmpty
        sightings = wanted ? sightings + 1 : 0
        if sightings >= 2 {
            sightings = 0
            runCheck("display change")
        }
    }
    poll.tolerance = 0.5
    RunLoop.main.add(poll, forMode: .common)
    // Safety net in case this process's own view of the displays is ever wrong.
    let safetyNet = Timer(timeInterval: 60, repeats: true) { _ in runCheck("periodic check") }
    safetyNet.tolerance = 5
    RunLoop.main.add(safetyNet, forMode: .common)
    print("\(Date()) watching for display changes")
    runCheck("startup")
    CFRunLoopRun()

default:
    fputs("usage: builtin-display [list|off|on|watch]\n", stderr)
    exit(2)
}
