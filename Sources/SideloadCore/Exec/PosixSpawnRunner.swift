import Darwin
import Dispatch
import Foundation
import Synchronization

/// Runs a command with `posix_spawn` in its own process group (design section 5). Foundation's `Process`
/// cannot do that, and the group kill is what stops `xcodebuild` helpers. One dedicated thread per run
/// does a blocking `poll(2)` over stdout, stderr, stdin and a wake pipe, so there is no sleep loop and
/// stdin cannot deadlock against output.
public struct PosixSpawnRunner: Runner {
    /// Non-blocking `waitpid`: returns the pid once reaped, 0 while the child is still running, -1 on error.
    typealias Reap = @Sendable (pid_t, UnsafeMutablePointer<Int32>) -> pid_t

    static let defaultGrace: Duration = .seconds(2)

    private let children: LiveChildren
    private let grace: Duration
    private let signalGroup: @Sendable (pid_t, Int32) -> Int32
    private let pipeFactory: @Sendable () -> (read: Int32, write: Int32)?
    private let afterSpawn: @Sendable () -> Void
    private let reap: Reap
    private let reapTimeout: Duration

    public init(children: LiveChildren = .shared) {
        self.init(children: children, grace: Self.defaultGrace, signalGroup: { killpg($0, $1) })
    }

    /// Tests inject a short grace period, a recording signal sender, and a pipe factory that can fail.
    init(
        children: LiveChildren, grace: Duration, signalGroup: @escaping @Sendable (pid_t, Int32) -> Int32,
        pipeFactory: @escaping @Sendable () -> (read: Int32, write: Int32)? = makePipe,
        afterSpawn: @escaping @Sendable () -> Void = {},
        reap: @escaping Reap = { waitpid($0, $1, WNOHANG) },
        reapTimeout: Duration = .seconds(5)
    ) {
        self.children = children
        self.grace = grace
        self.signalGroup = signalGroup
        self.pipeFactory = pipeFactory
        self.afterSpawn = afterSpawn
        self.reap = reap
        self.reapTimeout = reapTimeout
    }

    public func run(_ spec: CommandSpec) async -> RunResult {
        let waker = Waker()
        let job = Execution(
            spec: spec, children: children, grace: grace.nanoseconds, signalGroup: signalGroup, waker: waker,
            pipeFactory: pipeFactory, afterSpawn: afterSpawn, reap: reap, reapTimeout: reapTimeout.nanoseconds)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<RunResult, Never>) in
                let thread = Thread { continuation.resume(returning: job.run()) }
                thread.name = "sideload.runner"
                thread.start()
            }
        } onCancel: {
            waker.wake()
        }
    }
}

extension Duration {
    /// Saturating conversion; durations here are positive.
    var nanoseconds: UInt64 {
        let (seconds, attoseconds) = components
        guard seconds > 0 || attoseconds > 0 else { return 0 }
        let (product, overflow) = UInt64(max(seconds, 0)).multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return UInt64.max / 4 }
        return min(product &+ UInt64(max(attoseconds, 0) / 1_000_000_000), UInt64.max / 4)
    }
}

/// Lets Task cancellation interrupt the run thread's `poll`. The write end is only touched under the lock
/// and is disarmed before the thread closes it, so a late cancel can never write to a recycled fd.
private final class Waker: Sendable {
    private struct State {
        var fd: Int32 = -1
        var cancelled = false
    }

    private let state = Mutex(State())

    func wake() {
        state.withLock { s in
            s.cancelled = true
            if s.fd >= 0 { Self.poke(s.fd) }
        }
    }

    func arm(_ fd: Int32) {
        state.withLock { s in
            s.fd = fd
            if s.cancelled { Self.poke(fd) }
        }
    }

    func disarm() {
        state.withLock { $0.fd = -1 }
    }

    private static func poke(_ fd: Int32) {
        var byte: UInt8 = 1
        _ = write(fd, &byte, 1)
    }
}

/// The state of one run. Created on the caller's side, then used from exactly one thread.
private struct Execution: Sendable {
    let spec: CommandSpec
    let children: LiveChildren
    let grace: UInt64
    let signalGroup: @Sendable (pid_t, Int32) -> Int32
    let waker: Waker
    let pipeFactory: @Sendable () -> (read: Int32, write: Int32)?
    let afterSpawn: @Sendable () -> Void  // test seam: runs between posix_spawn and endSpawn
    let reap: PosixSpawnRunner.Reap  // test seam: the non-blocking waitpid
    let reapTimeout: UInt64  // how long to keep trying to reap after the final SIGKILL

    /// After SIGKILL, how long to keep waiting for EOF on pipes a daemonized grandchild may still hold.
    static let drainAfterKill: UInt64 = 1_000_000_000

    func run() -> RunResult {
        // SIGPIPE from writing stdin to a child that exited early must not kill the host process.
        // Block it on this thread and consume it after a failed write instead of changing process state.
        var pipeSet = sigset_t()
        sigemptyset(&pipeSet)
        sigaddset(&pipeSet, SIGPIPE)
        pthread_sigmask(SIG_BLOCK, &pipeSet, nil)

        guard let path = resolveExecutable(spec.executable) else { return spawnFailure("ENOENT") }
        // Created one by one so a failure part-way closes the pipes already made.
        var made: [(read: Int32, write: Int32)] = []
        for _ in 0..<4 {
            guard let pair = pipeFactory() else {
                for p in made { close(p.read); close(p.write) }
                return spawnFailure("EMFILE")
            }
            made.append(pair)
        }
        let (stdinPipe, outPipe, errPipe, wakePipe) = (made[0], made[1], made[2], made[3])
        var parentFds = [stdinPipe.write, outPipe.read, errPipe.read, wakePipe.read, wakePipe.write]
        let childFds = [stdinPipe.read, outPipe.write, errPipe.write]

        // A closed registry means an interrupt is under way and the process is about to exit: don't spawn.
        // Otherwise the spawn is tracked as in flight, so the handler waits for it (or `endSpawn` kills it).
        guard children.beginSpawn() else {
            (parentFds + childFds).forEach { close($0) }
            return spawnFailure("INTERRUPTED")
        }
        let (pid, spawnErrno) = spawn(path: path, stdin: stdinPipe.read, stdout: outPipe.write, stderr: errPipe.write)
        childFds.forEach { close($0) }
        guard spawnErrno == 0 else {
            children.endSpawn(pgid: nil)
            parentFds.forEach { close($0) }
            return spawnFailure(errnoName(spawnErrno))
        }
        afterSpawn()
        children.endSpawn(pgid: pid)
        for fd in [stdinPipe.write, outPipe.read, errPipe.read, wakePipe.read, wakePipe.write] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        waker.arm(wakePipe.write)
        parentFds = []

        var inFd = stdinPipe.write
        var outFd = outPipe.read
        var errFd = errPipe.read
        let input = [UInt8](spec.stdin ?? Data())
        var inputOffset = 0
        if input.isEmpty { close(inFd); inFd = -1 }  // stdin is always closed so tools never wait on it

        var outBytes: [UInt8] = []
        var errBytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        var timedOut = false
        var overflow = false
        var cancelled = false
        var wakeActive = true
        var termSent = false
        var killSent = false
        var killAt = UInt64.max
        var hardStop = UInt64.max
        var status: Int32 = 0
        var reapFailed = false
        var backoffMs: Int32 = 1
        let deadline = now() &+ spec.timeout.nanoseconds

        func send(_ sig: Int32) {
            if signalGroup(pid, sig) != 0 { _ = kill(pid, sig) }  // child left its group: hit the pid itself
        }
        func escalate() {
            guard !termSent else { return }
            termSent = true
            send(SIGTERM)
            killAt = now() &+ grace
        }
        func sendKill() {
            guard !killSent else { return }
            killSent = true
            send(SIGKILL)
            _ = kill(pid, SIGKILL)  // not yet reaped, so the pid is still ours; covers a child that left its group
            hardStop = now() &+ Self.drainAfterKill
        }
        func closeOutputs() {
            if outFd >= 0 { close(outFd); outFd = -1 }
            if errFd >= 0 { close(errFd); errFd = -1 }
        }
        func closeInput() {
            if inFd >= 0 { close(inFd); inFd = -1 }
        }
        func readOutput(stdout isStdout: Bool) {
            let fd = isStdout ? outFd : errFd
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                let room = max(0, spec.maxOutputBytes - outBytes.count - errBytes.count)
                let kept = min(n, room)
                if isStdout { outBytes.append(contentsOf: chunk[0..<kept]) } else { errBytes.append(contentsOf: chunk[0..<kept]) }
                if n > room {
                    overflow = true
                    escalate()
                }
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                close(fd)
                if isStdout { outFd = -1 } else { errFd = -1 }
            }
        }

        loop: while true {
            let pipesOpen = outFd >= 0 || errFd >= 0
            if !pipesOpen {
                let r = reap(pid, &status)
                if r == pid { break loop }
                if r < 0 && errno != EINTR { reapFailed = true; break loop }  // ECHILD: the exit status is unknown
            }

            let t = now()
            let nextEvent = !termSent ? deadline : (!killSent ? killAt : hardStop)
            if t >= nextEvent {
                if !termSent {
                    timedOut = true
                    escalate()
                } else if !killSent {
                    sendKill()
                } else {
                    _ = kill(pid, SIGKILL)
                    closeOutputs()  // a grandchild outside the group still holds the pipes; stop waiting for it
                    // A child stuck in an uninterruptible state may never die; poll instead of blocking so the
                    // run still returns. Giving up leaves it unreaped and the exit status unknown.
                    let reapDeadline = now() &+ reapTimeout
                    var sleepMs: UInt32 = 1
                    while true {
                        let r = reap(pid, &status)
                        if r == pid { break }
                        if (r < 0 && errno != EINTR) || now() >= reapDeadline {
                            reapFailed = true
                            break
                        }
                        usleep(sleepMs * 1000)
                        sleepMs = min(sleepMs * 2, 50)
                    }
                    break loop
                }
                continue
            }

            var waitMs = Int32(clamping: (nextEvent - t + 999_999) / 1_000_000)
            if !pipesOpen {
                // The child closed its pipes but has not been reaped yet: usually microseconds away.
                waitMs = min(waitMs, backoffMs)
                backoffMs = min(backoffMs * 2, 50)
            }
            var fds = [
                pollfd(fd: outFd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: errFd, events: Int16(POLLIN), revents: 0),
                pollfd(fd: inFd, events: inFd >= 0 ? Int16(POLLOUT) : 0, revents: 0),
                pollfd(fd: wakeActive ? wakePipe.read : -1, events: Int16(POLLIN), revents: 0),
            ]
            let ready = poll(&fds, nfds_t(fds.count), waitMs)
            if ready < 0 {
                if errno == EINTR { continue }
                closeOutputs()  // unexpected poll failure: stop and take the kill path rather than spin
                closeInput()
                wakeActive = false
                escalate()
                continue
            }
            if ready == 0 { continue }

            let readable = Int16(POLLIN | POLLHUP | POLLERR)
            if fds[3].revents != 0 {
                wakeActive = false  // cancellation: escalate now instead of waiting for the deadline
                cancelled = true
                escalate()
            }
            if fds[0].revents & readable != 0 && outFd >= 0 { readOutput(stdout: true) }
            if fds[1].revents & readable != 0 && errFd >= 0 { readOutput(stdout: false) }
            if overflow { closeOutputs() }  // stop reading; the child gets EPIPE and the group is being killed
            if inFd >= 0 && fds[2].revents != 0 {
                if fds[2].revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                    closeInput()
                } else {
                    let n = input.withUnsafeBytes {
                        write(inFd, $0.baseAddress! + inputOffset, min(input.count - inputOffset, 64 * 1024))
                    }
                    if n > 0 {
                        inputOffset += n
                        if inputOffset >= input.count { closeInput() }
                    } else if n < 0 && errno != EAGAIN && errno != EINTR {
                        if errno == EPIPE { consumePendingSIGPIPE(pipeSet) }
                        closeInput()
                    }
                }
            }
        }

        // A timed-out, overflowed or cancelled run sweeps the group once more so no grandchild is orphaned.
        if (timedOut || overflow || cancelled) && !killSent { _ = signalGroup(pid, SIGKILL) }
        children.remove(pid)
        closeOutputs()
        closeInput()
        waker.disarm()
        close(wakePipe.read)
        close(wakePipe.write)

        var code: Int32?
        var signal: Int32?
        let termSignal = status & 0x7f
        if reapFailed {
            // Exit status unknown (e.g. SIGCHLD ignored by the host): report neither success nor a signal.
        } else if termSignal == 0 {
            code = (status >> 8) & 0xff
        } else if termSignal != 0x7f {
            signal = termSignal
        }
        return RunResult(
            code: code, signal: signal, stdout: String(decoding: outBytes, as: UTF8.self),
            stderr: String(decoding: errBytes, as: UTF8.self), timedOut: timedOut, overflow: overflow)
    }

    // MARK: - Helpers

    private func spawnFailure(_ name: String) -> RunResult {
        RunResult(code: nil, spawnError: name)
    }

    private func spawn(path: String, stdin: Int32, stdout: Int32, stderr: Int32) -> (pid_t, Int32) {
        var actions: posix_spawn_file_actions_t? = nil
        var attr: posix_spawnattr_t? = nil
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attr)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        if let cwd = spec.cwd { posix_spawn_file_actions_addchdir(&actions, cwd) }

        // Own process group; every other fd closed in the child; default signal dispositions, because
        // the CLI ignores SIGINT/SIGTERM/SIGHUP/SIGPIPE for its DispatchSources and ignored signals
        // would otherwise survive exec and make children immune to the group SIGTERM.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        posix_spawnattr_setflags(&attr, Int16(flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for sig in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM] { sigaddset(&defaults, sig) }
        posix_spawnattr_setsigdefault(&attr, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attr, &mask)

        var argv: [UnsafeMutablePointer<CChar>?] = ([spec.executable] + spec.args).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        // The environment is passed through unchanged.
        var envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, path, &actions, &attr, argv, envp)
        return (pid, rc)
    }
}

// MARK: - Free helpers

private func now() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
}

func makePipe() -> (read: Int32, write: Int32)? {
    var fds: [Int32] = [-1, -1]
    guard pipe(&fds) == 0 else { return nil }
    // pipe() hands out the lowest free fds, which are 0-2 if the host closed them; the file actions' dup2
    // onto 0/1/2 would then clobber each other, so move every fd to 3 or above.
    for i in 0..<2 where fds[i] < 3 {
        let moved = fcntl(fds[i], F_DUPFD_CLOEXEC, 3)
        close(fds[i])
        if moved < 0 {
            close(fds[1 - i])
            return nil
        }
        fds[i] = moved
    }
    // Close-on-exec so a concurrent spawn that is not CLOEXEC_DEFAULT can't inherit the parent's ends;
    // the child gets its own dup2'd copies through the file actions.
    for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    return (fds[0], fds[1])
}

/// A name containing "/" is used as given; a bare name is searched in `PATH` here, explicitly, rather
/// than by `posix_spawnp`, so the lookup is visible and there is no shell involved.
private func resolveExecutable(_ name: String) -> String? {
    if name.contains("/") { return name }
    let searchPath = getenv("PATH").map { String(cString: $0) } ?? "/usr/bin:/bin"
    for dir in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
        let candidate = "\(dir)/\(name)"
        var info = stat()
        if stat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, access(candidate, X_OK) == 0 {
            return candidate
        }
    }
    return nil
}

private func consumePendingSIGPIPE(_ set: sigset_t) {
    var set = set
    var pending = sigset_t()
    var sig: Int32 = 0
    if sigpending(&pending) == 0, sigismember(&pending, SIGPIPE) == 1 { sigwait(&set, &sig) }
}

func errnoName(_ code: Int32) -> String {
    switch code {
    case ENOENT: "ENOENT"
    case EACCES: "EACCES"
    case ENOTDIR: "ENOTDIR"
    case ENOEXEC: "ENOEXEC"
    case EPERM: "EPERM"
    case E2BIG: "E2BIG"
    case ENOMEM: "ENOMEM"
    case EAGAIN: "EAGAIN"
    case EMFILE: "EMFILE"
    case ENFILE: "ENFILE"
    case ELOOP: "ELOOP"
    case ENAMETOOLONG: "ENAMETOOLONG"
    case ETXTBSY: "ETXTBSY"
    case EISDIR: "EISDIR"
    case EINVAL: "EINVAL"
    default: "SPAWN_FAILED"
    }
}
