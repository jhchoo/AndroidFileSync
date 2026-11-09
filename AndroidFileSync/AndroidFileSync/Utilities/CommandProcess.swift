import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Owns subprocesses for the app's lifetime. Once quitting starts, only explicit
/// cleanup commands may launch; an in-flight reconnect cannot restart ADB.
nonisolated enum AppProcessLifecycle {
    private static let lock = NSLock()
    private static var terminating = false
    private static var processes: [ObjectIdentifier: Process] = [:]
    private static var pids: Set<pid_t> = []

    static var isTerminating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return terminating
    }

    static func run(_ process: Process, allowDuringTermination: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !terminating || allowDuringTermination else { throw CancellationError() }
        try process.run()
        if !allowDuringTermination {
            processes[ObjectIdentifier(process)] = process
        }
    }

    static func didExit(_ process: Process) {
        lock.lock()
        processes.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
    }

    static func registerPID(_ pid: pid_t, allowDuringTermination: Bool = false) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !terminating || allowDuringTermination else { throw CancellationError() }
        pids.insert(pid)
    }

    static func didExitPID(_ pid: pid_t) {
        lock.lock()
        pids.remove(pid)
        lock.unlock()
    }

    static func beginTermination() {
        lock.lock()
        guard !terminating else { lock.unlock(); return }
        terminating = true
        let children = Array(processes.values)
        let activePids = Array(pids)
        processes.removeAll()
        pids.removeAll()
        lock.unlock()

        for process in children where process.isRunning {
            process.terminate()
        }
        for pid in activePids {
            kill(pid, SIGTERM)
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) {
            for process in children where process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            for pid in activePids {
                kill(pid, SIGKILL)
            }
        }
    }
}

/// Owns a command across launch, cancellation, timeout, and pipe completion using posix_spawn.
/// Preserves exact UTF-8 byte sequences without macOS Process argument NFD normalization.
nonisolated final class CommandProcess: @unchecked Sendable {
    private let command: String
    private let args: [String]
    private let environment: [String: String]
    private let allowDuringTermination: Bool
    private let onOutput: (@Sendable (Data) -> Void)?

    private let stdout = Pipe()
    private let stderr = Pipe()
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var output = Data()
    private var error = Data()
    private var stopped: (Int32, String)?
    private var continuation: CheckedContinuation<(Int32, String, String), Never>?
    private var completed = false
    private var isRunning = false

    init(
        command: String,
        args: [String],
        environment: [String: String],
        allowDuringTermination: Bool = false,
        onOutput: (@Sendable (Data) -> Void)? = nil
    ) {
        self.command = command
        self.args = args
        self.environment = environment
        self.allowDuringTermination = allowDuringTermination
        self.onOutput = onOutput
    }

    func start(timeout: Double?, continuation: CheckedContinuation<(Int32, String, String), Never>) {
        lock.lock()
        self.continuation = continuation
        let previousStop = stopped
        lock.unlock()
        if let previousStop {
            finish(code: previousStop.0, message: previousStop.1)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { self.launch(timeout: timeout) }
    }

    private func launch(timeout: Double?) {
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)

        let devNull = open("/dev/null", O_RDONLY)
        if devNull >= 0 {
            posix_spawn_file_actions_adddup2(&fileActions, devNull, STDIN_FILENO)
            posix_spawn_file_actions_addclose(&fileActions, devNull)
        }

        let outFd = stdout.fileHandleForWriting.fileDescriptor
        let errFd = stderr.fileHandleForWriting.fileDescriptor
        posix_spawn_file_actions_adddup2(&fileActions, outFd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errFd, STDERR_FILENO)

        var spawnAttr: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttr)
        posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var cArgs = [strdup(command)]
        for arg in args {
            cArgs.append(strdup(arg))
        }
        cArgs.append(nil)

        var cEnv: [UnsafeMutablePointer<CChar>?] = []
        for (k, v) in environment {
            cEnv.append(strdup("\(k)=\(v)"))
        }
        cEnv.append(nil)

        lock.lock()
        guard stopped == nil else {
            let stop = stopped!
            lock.unlock()
            posix_spawn_file_actions_destroy(&fileActions)
            posix_spawnattr_destroy(&spawnAttr)
            if devNull >= 0 { close(devNull) }
            for p in cArgs { if let p { free(p) } }
            for p in cEnv { if let p { free(p) } }
            finish(code: stop.0, message: stop.1)
            return
        }

        var localPid: pid_t = 0
        let spawnRes = posix_spawn(&localPid, command, &fileActions, &spawnAttr, cArgs, cEnv.count > 1 ? cEnv : nil)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&spawnAttr)
        if devNull >= 0 { close(devNull) }

        // Close write ends in parent so availableData receives EOF when child exits
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()

        for p in cArgs { if let p { free(p) } }
        for p in cEnv { if let p { free(p) } }

        guard spawnRes == 0 else {
            lock.unlock()
            finish(code: spawnRes, message: "posix_spawn failed with error \(spawnRes)")
            return
        }

        self.pid = localPid
        self.isRunning = true
        do {
            try AppProcessLifecycle.registerPID(localPid, allowDuringTermination: allowDuringTermination)
            lock.unlock()
        } catch {
            lock.unlock()
            kill(localPid, SIGKILL)
            finish(code: -999, message: error.localizedDescription)
            return
        }

        let readers = DispatchGroup()
        for (pipe, isError) in [(stdout, false), (stderr, true)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async { [self] in
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    lock.lock()
                    if isError {
                        error.append(onOutput == nil ? data : data.prefix(max(0, 65_536 - error.count)))
                    } else if onOutput == nil {
                        output.append(data)
                    }
                    let deliver = !completed && stopped == nil
                    lock.unlock()
                    if !isError, deliver { onOutput?(data) }
                }
                readers.leave()
            }
        }

        // Timeout watcher
        if let timeout {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, timeout)) { [weak self] in
                self?.stop(code: -1, message: "Command timed out after \(timeout) seconds")
            }
        }

        // Wait for exit in background
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var status: Int32 = 0
            waitpid(localPid, &status, 0)

            lock.lock()
            isRunning = false
            lock.unlock()

            AppProcessLifecycle.didExitPID(localPid)

            readers.notify(queue: .global(qos: .utility)) { [self] in
                let exitCode: Int32
                if (status & 0x7f) == 0 {
                    exitCode = (status >> 8) & 0xff
                } else {
                    exitCode = -1
                }
                finish(code: exitCode)
            }
        }
    }

    func cancel() { stop(code: -999, message: "Command cancelled") }

    private func stop(code: Int32, message: String) {
        lock.lock()
        guard !completed, stopped == nil else { lock.unlock(); return }
        stopped = (code, message)
        let activePid = pid
        let active = isRunning
        lock.unlock()
        if active && activePid > 0 {
            kill(activePid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let stillRunning = self.isRunning
                self.lock.unlock()
                if stillRunning && activePid > 0 {
                    kill(activePid, SIGKILL)
                }
            }
        }
        finish(code: code, message: message)
    }

    private func finish(code: Int32, message: String = "") {
        lock.lock()
        guard !completed, let continuation else { lock.unlock(); return }
        completed = true
        self.continuation = nil
        let finalCode = stopped?.0 ?? code
        let finalMessage = stopped?.1 ?? message
        let out = String(data: output, encoding: .utf8) ?? String(data: output, encoding: .isoLatin1) ?? ""
        var err = String(data: error, encoding: .utf8) ?? String(data: error, encoding: .isoLatin1) ?? ""
        if !finalMessage.isEmpty { err += (err.isEmpty ? "" : "\n") + finalMessage }
        lock.unlock()
        continuation.resume(returning: (finalCode, out, err))
    }
}
