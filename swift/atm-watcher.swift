// === atm-watcher (v4.5.0) ===
// Native macOS FSEvents watcher for Adobe Toggle Manager.
// Watches the given paths recursively. On every file event it sends
// SIGUSR1 to the daemon PID — the adobe-toggle daemon then interrupts
// its safety-tick sleep and immediately runs a discovery+block
// cycle.
//
// Build (universal binary for arm64 + x86_64):
//   swiftc -O \
//          -target arm64-apple-macos11 \
//          -o atm-watcher-arm64 atm-watcher.swift
//   swiftc -O \
//          -target x86_64-apple-macos11 \
//          -o atm-watcher-x86_64 atm-watcher.swift
//   lipo -create -output atm-watcher atm-watcher-arm64 atm-watcher-x86_64
//
// Build (single-arch for the current machine — test/dev):
//   swiftc -O -o atm-watcher atm-watcher.swift
//
// Usage:
//   atm-watcher <daemon-pid> <path1>:<path2>:<path3>:...
//
// Exit-Codes:
//   0  = SIGINT/SIGTERM clean shutdown
//   2  = usage error
//   3  = FSEventStreamCreate failed
//   4  = invalid daemon-pid

import Foundation
import CoreServices

// === argv parsing ===
guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(
        "Usage: atm-watcher <daemon-pid> <path1>:<path2>:...\n".data(using: .utf8)!
    )
    exit(2)
}

guard let daemonPid = pid_t(CommandLine.arguments[1]), daemonPid > 0 else {
    FileHandle.standardError.write(
        "atm-watcher: invalid daemon-pid '\(CommandLine.arguments[1])'\n".data(using: .utf8)!
    )
    exit(4)
}

let pathsStr = CommandLine.arguments[2]
let paths = pathsStr.split(separator: ":").map { String($0) }

guard !paths.isEmpty else {
    FileHandle.standardError.write(
        "atm-watcher: no paths to watch\n".data(using: .utf8)!
    )
    exit(2)
}

// === Daemon PID in a heap-allocated container for the callback closure ===
// FSEventStreamContext.info is an UnsafeMutableRawPointer — we must place the
// pid_t in a stable memory slot (the stack is not stable across the
// run-loop lifetime).
class DaemonPidHolder {
    let pid: pid_t
    init(_ pid: pid_t) { self.pid = pid }
}
let pidHolder = DaemonPidHolder(daemonPid)
let pidPointer = Unmanaged.passRetained(pidHolder).toOpaque()

// === FSEvent callback ===
// Called for EVERY event batch. We send ONE SIGUSR1 per batch
// (FSEventStream does the coalescing itself via the latency parameter, see below).
let callback: FSEventStreamCallback = { (
    streamRef,
    clientCallBackInfo,
    numEvents,
    eventPaths,
    eventFlags,
    eventIds
) in
    guard let info = clientCallBackInfo else { return }
    let holder = Unmanaged<DaemonPidHolder>.fromOpaque(info).takeUnretainedValue()
    // SIGUSR1 → daemon loop interrupts sleep + tick.
    kill(holder.pid, SIGUSR1)
}

// === FSEventStream setup ===
var context = FSEventStreamContext(
    version: 0,
    info: pidPointer,
    retain: nil,
    release: nil,
    copyDescription: nil
)

let pathsCFArray = paths as CFArray

// Coalescing latency: 0.5s — multiple events within 500ms are bundled into a
// single callback invocation → 1 SIGUSR1 instead of 50.
let latency: CFAbsoluteTime = 0.5

// kFSEventStreamCreateFlagFileEvents = we want file-level events
// (not just directory-level), because Adobe plists/helpers appear as individual
// files. kFSEventStreamCreateFlagNoDefer = immediate delivery on the
// first event in each latency window (instead of at the end).
let flags: FSEventStreamCreateFlags = FSEventStreamCreateFlags(
    kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
)

guard let stream = FSEventStreamCreate(
    nil,
    callback,
    &context,
    pathsCFArray,
    FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
    latency,
    flags
) else {
    FileHandle.standardError.write(
        "atm-watcher: FSEventStreamCreate failed\n".data(using: .utf8)!
    )
    Unmanaged<DaemonPidHolder>.fromOpaque(pidPointer).release()
    exit(3)
}

// === Run-Loop scheduling ===
FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
FSEventStreamStart(stream)

// === Signal handler for clean shutdown ===
// SIGINT (Ctrl+C), SIGTERM (kill from parent daemon).
//
// Pattern: pthread_sigmask blocks the default action (= terminate),
// DispatchSourceSignal still picks up the signal via libdispatch/kqueue.
// signal(SIG_IGN) would be WRONG HERE — it would ignore the signal entirely
// and DispatchSourceSignal would not receive it either.
var sigMask = sigset_t()
sigemptyset(&sigMask)
sigaddset(&sigMask, SIGINT)
sigaddset(&sigMask, SIGTERM)
pthread_sigmask(SIG_BLOCK, &sigMask, nil)

let shutdownSource: (Int32) -> DispatchSourceSignal = { sig in
    let src = DispatchSource.makeSignalSource(signal: sig, queue: DispatchQueue.global(qos: .utility))
    src.setEventHandler {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        Unmanaged<DaemonPidHolder>.fromOpaque(pidPointer).release()
        exit(0)
    }
    src.resume()
    return src
}

// Keep the sources in scope (otherwise they get released immediately)
let _intSource = shutdownSource(SIGINT)
let _termSource = shutdownSource(SIGTERM)

// === Block the run loop until a signal ===
dispatchMain()
