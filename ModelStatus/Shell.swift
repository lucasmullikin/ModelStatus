import Foundation

/// Subprocess runner — hardened across many audit rounds, now living in its
/// own file (architect-D53 split: was nested inside `LocalProbe` in
/// `Provider.swift`, mixing layers).
///
/// Public surface: `Shell.run(_:args:timeout:)`. The callsite contract is
/// identical to the previous `LocalProbe.runShell(_:args:timeout:)` and the
/// `LocalSystemAccess.runShell(...)` protocol method continues to honor that
/// shape — only the internal implementation has moved.
enum Shell {
    /// Maximum stdout bytes a single shell invocation may produce. Beyond this
    /// the child is SIGTERM'd and what we have so far is returned (or nil
    /// when capped, per the `tryFinish` policy below). Keeps a runaway /
    /// noisy binary from forcing unbounded memory use.
    static let maxOutputBytes = 4 * 1024 * 1024

    /// Hardened (v0.2 D-revised + D50-hard refinements): streams stdout via
    /// `readabilityHandler`, drains any remaining pipe data once the child
    /// exits before resuming (so output isn't truncated when the child dies
    /// before the readability callback drains its last chunk), caps the
    /// buffer at `maxOutputBytes`, and escalates SIGTERM → SIGKILL on a
    /// two-stage deadline. A single-fire latch ensures the continuation
    /// resumes exactly once even when multiple resolution paths race.
    ///
    /// Scope-down note (per v0.2 security blocker B3): we kill the immediate
    /// child only, not the process group. Every caller in ModelStatus invokes
    /// a known binary with explicit argv (`/bin/ps`, `/usr/sbin/lsof`,
    /// `/usr/bin/pgrep`, `/usr/bin/open`, `/usr/bin/pkill`,
    /// `/opt/homebrew/bin/brew`). None of these fork grandchildren that
    /// outlive SIGKILL. If a future call site needs `/bin/sh -c`, add
    /// process-group kill via `posix_spawn` + `POSIX_SPAWN_SETPGROUP` first.
    static func run(_ path: String, args: [String], timeout: TimeInterval = 5) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice

            // Mutable state lives in a reference type so closures that fire on
            // arbitrary GCD threads (readabilityHandler, terminationHandler, kill
            // timers) can share it without Sendable copy semantics. Access is
            // serialized through `sync` — the @unchecked annotation is honest.
            final class State: @unchecked Sendable {
                var buffer = Data()
                var resumed = false
                var capExceeded = false
                var terminated = false
                var detached = false   // Audit-round-D50-hard: idempotent latch
            }
            let state = State()
            let sync = DispatchQueue(label: "modelstatus.shell.sync")
            let readFH = pipe.fileHandleForReading

            // Audit-round-D14/D50-hard: detach SYNCHRONOUSLY and IDEMPOTENTLY
            // under the sync queue. FileHandle's `readabilityHandler = nil`
            // is documented safe from any thread, but doing it through the
            // single serialization queue both makes the ordering with
            // buffer-append callbacks explicit AND ensures only the first
            // detach call performs the nil-assignment — subsequent calls
            // become no-ops. The previous version could fire from the
            // readability callback, `tryFinish`, the proc.run failure path,
            // and the backstop, with no formal ordering guarantee between
            // them.
            let detachHandler: @Sendable () -> Void = {
                sync.sync {
                    guard !state.detached else { return }
                    state.detached = true
                    readFH.readabilityHandler = nil
                }
            }

            // Audit-round-D46: dedicated SIGKILL escalation for the
            // cap-exceeded path. If a child ignores SIGTERM after we hit the
            // 4 MiB stdout cap, the only existing escalation lives on the
            // general timeout schedule (timeout + 2s for SIGKILL). For a
            // noisy fast-emitting child, that can mean an extra 5–10s of
            // resource consumption. A cap-specific SIGKILL at +500ms keeps
            // the bound tight without changing the happy-path behavior.
            let capKillWorkItem = DispatchWorkItem {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
            readFH.readabilityHandler = { fh in
                let chunk = fh.availableData
                if chunk.isEmpty {
                    // Writer side closed → no more data coming. Detach the handler so
                    // GCD stops dispatching. terminationHandler drains + resumes.
                    detachHandler()
                    return
                }
                let exceeded = sync.sync { () -> Bool in
                    if state.buffer.count + chunk.count > maxOutputBytes {
                        state.capExceeded = true
                        return true
                    }
                    state.buffer.append(chunk)
                    return false
                }
                if exceeded && proc.isRunning {
                    proc.terminate()
                    DispatchQueue.global(qos: .utility)
                        .asyncAfter(deadline: .now() + 0.5, execute: capKillWorkItem)
                }
            }

            // Single-fire finalizer. Called from terminationHandler, the SIGKILL
            // backstop, or — if the kernel somehow doesn't reap — a fallback timer.
            // Drains remaining pipe data ONLY when we're sure the writer side is
            // closed (process terminated OR we've explicitly given up). Audit-
            // round-3 fix: a blind `readToEnd()` from the never-terminated backstop
            // path could deadlock if the child was still alive and holding the pipe.
            //
            // Audit-round-4 fix: when `capExceeded` is set, return nil so callers
            // (ps / lsof / pgrep parsers) fail closed instead of acting on a
            // truncated mid-line buffer.
            //
            // Audit-round-6 fix: don't explicitly close `readFH` here. Closing
            // can race a still-queued `readabilityHandler` callback or a not-yet-
            // reaped child. The Pipe/Process owners deinit will close cleanly
            // once everything releases; that's the safe path.
            let tryFinish: @Sendable () -> Void = {
                // Audit-round-D21: single-fire latch first, then conditional
                // drain ONLY when the process has been observed terminated
                // (kernel closed the writer-side fd, so readToEnd returns
                // immediately without blocking — no hang risk). For paths
                // where termination wasn't observed (cap-exceeded mid-stream,
                // run-failure), skip the drain and resume with what we have.
                let shouldResume = sync.sync { () -> Bool in
                    if state.resumed { return false }
                    state.resumed = true
                    return true
                }
                guard shouldResume else { return }
                detachHandler()
                let terminated = sync.sync { state.terminated }
                if terminated {
                    // Wait for any in-flight readability callback to finish
                    // its sync.sync append before we drain. Then read the
                    // remaining bytes — the writer's closed at this point,
                    // so readToEnd is non-blocking.
                    sync.sync {}
                    if let tail = try? readFH.readToEnd(), !tail.isEmpty {
                        sync.sync {
                            if state.buffer.count + tail.count > maxOutputBytes {
                                state.capExceeded = true
                            } else {
                                state.buffer.append(tail)
                            }
                        }
                    }
                }
                let (buffer, capped) = sync.sync { (state.buffer, state.capExceeded) }
                if capped {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: String(data: buffer, encoding: .utf8))
                }
            }

            // Audit-round-D19: create the timeout work items + the
            // terminationHandler wrapping BEFORE proc.run() so a very fast
            // process can't exit in the window between run() and our
            // post-run setup. The handler installed here cancels the timers
            // when terminationHandler fires.
            let termWorkItem = DispatchWorkItem {
                if proc.isRunning { proc.terminate() }
            }
            let killWorkItem = DispatchWorkItem {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
            let backstopWorkItem = DispatchWorkItem {
                let alreadyTerminated = sync.sync { state.terminated }
                if !alreadyTerminated {
                    sync.sync { state.capExceeded = true }
                    if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                }
                tryFinish()
            }
            proc.terminationHandler = { _ in
                termWorkItem.cancel()
                killWorkItem.cancel()
                backstopWorkItem.cancel()
                capKillWorkItem.cancel()
                sync.sync { state.terminated = true }
                tryFinish()
            }

            do {
                try proc.run()
            } catch {
                // Failure-path resume must go through the same single-fire latch
                // so a callback that already armed itself can't double-resume.
                // Audit-round-D17: detach + resume INSIDE the shouldResume
                // branch so a parallel callback path's teardown isn't
                // interfered with when the latch is already fired.
                let shouldResume = sync.sync { () -> Bool in
                    if state.resumed { return false }
                    state.resumed = true
                    return true
                }
                if shouldResume {
                    detachHandler()
                    continuation.resume(returning: nil)
                }
                return
            }

            // Schedule the timers. The work items were created above; the
            // terminationHandler wrapper cancels them on clean exit.
            let killQueue = DispatchQueue.global(qos: .utility)
            killQueue.asyncAfter(deadline: .now() + timeout, execute: termWorkItem)
            killQueue.asyncAfter(deadline: .now() + timeout + 2.0, execute: killWorkItem)
            killQueue.asyncAfter(deadline: .now() + timeout + 3.0, execute: backstopWorkItem)
        }
    }
}
