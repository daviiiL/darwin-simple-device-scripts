import Foundation
import CoreGraphics
import ApplicationServices

let escTarget = 5
let streakTimeoutNs: UInt64 = 1_000_000_000   // 1 second
let kVKEscape: CGKeyCode = 53

var escCount = 0
var lastEscTimeNs: UInt64 = 0
var tapRef: CFMachPort?

let modifierMask: CGEventFlags = [
    .maskCommand, .maskControl, .maskAlternate, .maskShift,
]

setvbuf(stdout, nil, _IOLBF, 0)

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func emit(_ line: String) {
    fputs(line + "\n", stdout)
    fflush(stdout)
}

func die(_ msg: String, code: Int32 = 1) -> Never {
    fputs("kbsink: " + msg + "\n", stderr)
    exit(code)
}

// 1. Accessibility permission gate — pops the system prompt on first run.
let promptOpts = [
    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
] as CFDictionary
guard AXIsProcessTrustedWithOptions(promptOpts) else {
    die("""
        Accessibility permission required. Grant it for THIS binary in
        System Settings -> Privacy & Security -> Accessibility, then re-run.
        """, code: 2)
}

// 2. Event tap callback. Swallows everything; tracks standalone-ESC streak.
let callback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = tapRef { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return nil }

    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let hasModifier = !event.flags.intersection(modifierMask).isEmpty
    let isStandaloneEsc = (keyCode == kVKEscape) && !hasModifier

    let prev = escCount
    let now = nowNs()
    if isStandaloneEsc {
        if escCount == 0 || (now - lastEscTimeNs) > streakTimeoutNs {
            escCount = 1
        } else {
            escCount += 1
        }
        lastEscTimeNs = now
    } else {
        escCount = 0
    }

    if escCount != prev {
        emit("count=\(escCount)")
    }

    if escCount >= escTarget {
        emit("released")
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    return nil   // swallow — event never reaches WindowServer/apps
}

// 3. Install the tap above WindowServer for the current session.
//    NX_SYSDEFINED (14) carries volume / brightness / media / eject keys,
//    which travel as system-defined events rather than keyDowns. Mask both.
let NX_SYSDEFINED: UInt32 = 14
let mask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue) |
    (1 << CGEventType.keyUp.rawValue) |
    (1 << CGEventType.flagsChanged.rawValue) |
    (1 << NX_SYSDEFINED)
guard let tap = CGEvent.tapCreate(
    tap: .cgSessionEventTap,
    place: .headInsertEventTap,
    options: .defaultTap,
    eventsOfInterest: mask,
    callback: callback,
    userInfo: nil
) else {
    die("failed to create event tap (Accessibility permission may be revoked).")
}
tapRef = tap

let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

// 4. Idle reset: poll every 100ms, expire the streak after streakTimeoutNs of silence.
let timer = Timer(timeInterval: 0.1, repeats: true) { _ in
    if escCount > 0 && (nowNs() - lastEscTimeNs) > streakTimeoutNs {
        escCount = 0
        emit("count=0")
    }
}
RunLoop.current.add(timer, forMode: .common)

emit("ready")
CFRunLoopRun()
