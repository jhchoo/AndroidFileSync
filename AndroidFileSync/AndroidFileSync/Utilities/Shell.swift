import Foundation

/// Cancel one startup waiter without stopping the daemon needed by other callers.
nonisolated private final class ADBStartupWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var result: (Int32, String, String)?
    private var continuation: CheckedContinuation<(Int32, String, String), Never>?

    func value(of task: Task<(Int32, String, String), Never>) async -> (Int32, String, String) {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                let completed = result
                if completed == nil { self.continuation = continuation }
                lock.unlock()
                if let completed { continuation.resume(returning: completed); return }
                if Task.isCancelled { finish((-999, "", "Connection cancelled")) }
                Task { finish(await task.value) }
            }
        } onCancel: {
            finish((-999, "", "Connection cancelled"))
        }
    }

    private func finish(_ value: (Int32, String, String)) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

/// Cold ADB 37 startup can take longer than an endpoint query. Share one explicit
/// start so devices, mDNS, and reconnect commands cannot race to launch daemons.
private actor ADBServerStartup {
    static let shared = ADBServerStartup()
    private var starts: [Int: Task<(Int32, String, String), Never>] = [:]

    func prepare(path: String, port: Int) async -> (Int32, String, String)? {
        guard !AppProcessLifecycle.isTerminating, !Task.isCancelled else {
            return (-999, "", "Connection cancelled")
        }
        if let start = starts[port] {
            let result = await ADBStartupWaiter().value(of: start)
            return result.0 == 0 ? nil : result
        }
        if Shell.isADBServerRunning(port: port) { return nil }
        let start = Task {
            let result = await Shell.runAsyncWithTimeout(path, args: ["-P", String(port), "start-server"],
                timeoutSeconds: 6, environment: Shell.serverEnvironment(port: port))
            starts.removeValue(forKey: port)
            return result
        }
        starts[port] = start
        let result = await ADBStartupWaiter().value(of: start)
        return result.0 == 0 ? nil : result
    }
}

nonisolated private final class ADBRoutingState: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [String: Int] = [:]
    private var shared = false
    var serverPorts: [String: Int] {
        get { lock.lock(); defer { lock.unlock() }; return ports }
        set { lock.lock(); ports = newValue; lock.unlock() }
    }
    var useDefault: Bool {
        get { lock.lock(); defer { lock.unlock() }; return shared }
        set { lock.lock(); shared = newValue; lock.unlock() }
    }
}

nonisolated struct Shell {
    /// Dedicated ADB server port used by this app to avoid interfering with other tools.
    /// Any adb process started by app commands will use this private server.
    static let appADBServerPort = 56037
    private static let routing = ADBRoutingState()
    static var serverPortBySerial: [String: Int] {
        get { routing.serverPorts }
        set { routing.serverPorts = newValue }
    }

    /// When true, all ADB commands are routed to the default server (port 5037).
    /// This allows the app to piggyback on an existing server that already owns the
    /// USB transport (e.g. Android Studio), so both tools can coexist without conflict.
    static var useDefaultServer: Bool {
        get { routing.useDefault }
        set { routing.useDefault = newValue }
    }

    /// The environment used for all standard ADB commands.
    /// Automatically routes to the default server (5037) when `useDefaultServer` is true,
    /// or to our private server (56037) otherwise.
    static var activeADBEnvironment: [String: String] {
        useDefaultServer ? defaultADBEnvironment : adbEnvironment
    }

    /// Environment variables applied to ALL processes launched by Shell.
    /// We isolate adb to a private server and disable adb's automatic mDNS auto-connect
    /// so the app controls when connections are established.
    static var adbEnvironment: [String: String] { serverEnvironment(port: appADBServerPort) }
    static var defaultADBEnvironment: [String: String] { serverEnvironment(port: 5037) }

    static func serverEnvironment(port: Int) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // A socket override takes precedence over the port, including in Xcode schemes.
        env.removeValue(forKey: "ADB_SERVER_SOCKET")
        env.removeValue(forKey: "ANDROID_ADB_SERVER_ADDRESS")
        env.removeValue(forKey: "ANDROID_SERIAL")
        env["ANDROID_ADB_SERVER_PORT"] = String(port)
        env["ADB_SERVER_PORT"] = String(port)
        env["ADB_MDNS_AUTO_CONNECT"] = "0"
        return env
    }

    /// A loopback probe avoids starting Android Studio's server just to inspect it.
    static func isDefaultServerRunning() -> Bool {
        isADBServerRunning(port: 5037)
    }

    static func isADBServerRunning(port: Int) -> Bool {
        guard let serverPort = UInt16(exactly: port), serverPort > 0 else { return false }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = serverPort.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    static func environment(for args: [String]) -> [String: String] {
        if let index = args.firstIndex(of: "-s"), args.indices.contains(index + 1),
           let port = serverPortBySerial[args[index + 1]] {
            return serverEnvironment(port: port)
        }
        if let command = args.first, ["connect", "disconnect"].contains(command), args.count > 1,
           let port = serverPortBySerial[args[1]] {
            return serverEnvironment(port: port)
        }
        return activeADBEnvironment
    }
    static func run(_ command: String, args: [String]) -> (Int32, String, String) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)

        let devNull = open("/dev/null", O_RDONLY)
        if devNull >= 0 {
            posix_spawn_file_actions_adddup2(&fileActions, devNull, STDIN_FILENO)
            posix_spawn_file_actions_addclose(&fileActions, devNull)
        }

        let outFd = stdoutPipe.fileHandleForWriting.fileDescriptor
        let errFd = stderrPipe.fileHandleForWriting.fileDescriptor
        posix_spawn_file_actions_adddup2(&fileActions, outFd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errFd, STDERR_FILENO)

        var spawnAttr: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttr)
        posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var cArgs = [strdup(command)]
        for arg in args { cArgs.append(strdup(arg)) }
        cArgs.append(nil)

        let env = environment(for: args)
        var cEnv: [UnsafeMutablePointer<CChar>?] = []
        for (k, v) in env { cEnv.append(strdup("\(k)=\(v)")) }
        cEnv.append(nil)

        var pid: pid_t = 0
        let spawnRes = posix_spawn(&pid, command, &fileActions, &spawnAttr, cArgs, cEnv.count > 1 ? cEnv : nil)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&spawnAttr)
        if devNull >= 0 { close(devNull) }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        for p in cArgs { if let p { free(p) } }
        for p in cEnv { if let p { free(p) } }

        guard spawnRes == 0 else {
            return (spawnRes, "", "posix_spawn failed: \(spawnRes)")
        }

        try? AppProcessLifecycle.registerPID(pid)
        defer { AppProcessLifecycle.didExitPID(pid) }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let exitCode = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : -1

        let output = String(data: outData, encoding: .utf8) ?? String(data: outData, encoding: .isoLatin1) ?? ""
        let error = String(data: errData, encoding: .utf8) ?? String(data: errData, encoding: .isoLatin1) ?? ""

        return (exitCode, output, error)
    }
    
    static func runAsync(_ command: String, args: [String]) async -> (Int32, String, String) {
        await execute(command, args: args, timeout: nil, environment: environment(for: args))
    }

    /// Delivers stdout while the process is running, without buffering an entire
    /// device-tracking session. Cancellation uses the normal child-process cleanup.
    static func stream(_ command: String, args: [String], environment: [String: String],
                       onOutput: @escaping @Sendable (Data) -> Void) async -> (Int32, String, String) {
        await execute(command, args: args, timeout: nil, environment: environment, onOutput: onOutput)
    }

    static func runAsyncWithTimeout(
        _ command: String, args: [String], timeoutSeconds: Double,
        environment: [String: String]? = nil,
        allowDuringTermination: Bool = false
    ) async -> (Int32, String, String) {
        await execute(command, args: args, timeout: timeoutSeconds,
                      environment: environment ?? self.environment(for: args),
                      allowDuringTermination: allowDuringTermination)
    }

    private static func execute(
        _ command: String, args: [String], timeout: Double?, environment: [String: String],
        allowDuringTermination: Bool = false,
        onOutput: (@Sendable (Data) -> Void)? = nil
    ) async -> (Int32, String, String) {
        if !allowDuringTermination, URL(fileURLWithPath: command).lastPathComponent == "adb",
           requiresADBServer(args) {
            let explicitPort = args.firstIndex(of: "-P").flatMap {
                args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil
            }
            let port = explicitPort ?? Int(environment["ANDROID_ADB_SERVER_PORT"] ?? "") ?? appADBServerPort
            if let failure = await ADBServerStartup.shared.prepare(path: command, port: port) {
                return failure
            }
            guard !Task.isCancelled, !AppProcessLifecycle.isTerminating else {
                return (-999, "", "Connection cancelled")
            }
        }
        let execution = CommandProcess(command: command, args: args, environment: environment,
                                       allowDuringTermination: allowDuringTermination, onOutput: onOutput)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { execution.cancel() }
                execution.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            execution.cancel()
        }
    }

    private static func requiresADBServer(_ args: [String]) -> Bool {
        var index = 0
        while args.indices.contains(index), args[index].hasPrefix("-") {
            // Global options with values precede the actual adb command.
            index += ["-P", "-s", "-t", "-H", "-L", "--one-device"].contains(args[index]) ? 2 : 1
        }
        guard args.indices.contains(index) else { return false }
        return !["start-server", "kill-server", "version", "help", "server"].contains(args[index])
    }

    static func bash(_ command: String) async -> (Int32, String, String) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = run("/bin/bash", args: ["-c", command])
                continuation.resume(returning: result)
            }
        }
    }
    
    // New: Run with progress tracking - reads stderr for ADB progress
    static func runWithProgress(
        _ command: String,
        args: [String],
        progressCallback: @escaping (String) -> Void
    ) async -> (Int32, String, String) {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let stdout = Pipe()
                let stderr = Pipe()
                
                process.executableURL = URL(fileURLWithPath: command)
                process.arguments = args
                process.environment = environment(for: args)
                process.standardOutput = stdout
                process.standardError = stderr
                
                var outputData = Data()
                var errorData = Data()
                
                // ADB outputs progress to STDERR, not STDOUT!
                let stderrHandle = stderr.fileHandleForReading
                
                // Read stderr in background thread
                DispatchQueue.global(qos: .userInitiated).async {
                    while true {
                        let data = stderrHandle.availableData
                        if data.isEmpty { break }
                        
                        errorData.append(data)
                        
                        // Send progress updates
                        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                            DispatchQueue.main.async {
                                progressCallback(text)
                            }
                        }
                    }
                }
                
                do {
                    try AppProcessLifecycle.run(process)
                    defer { AppProcessLifecycle.didExit(process) }
                    process.waitUntilExit()
                    
                    // Get final output
                    outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                    
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    let error = String(data: errorData, encoding: .utf8) ?? ""
                    
                    continuation.resume(returning: (process.terminationStatus, output, error))
                } catch {
                    continuation.resume(returning: (-1, "", error.localizedDescription))
                }
            }
        }
    }
    
    /// Run a command and capture raw binary Data from stdout.
    /// Used for `adb exec-out cat` and `adb exec-out head -c` which output binary data.
    /// Uses posix_spawn to preserve exact UTF-8 byte sequences without macOS Process NFD normalization.
    static func runAndCaptureData(
        _ command: String,
        args: [String],
        maxBytes: Int = 0,
        cancellationCheck: @escaping () -> Bool = { false }
    ) async -> (Int32, Data, String) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)

        let devNull = open("/dev/null", O_RDONLY)
        if devNull >= 0 {
            posix_spawn_file_actions_adddup2(&fileActions, devNull, STDIN_FILENO)
            posix_spawn_file_actions_addclose(&fileActions, devNull)
        }

        let outFd = stdoutPipe.fileHandleForWriting.fileDescriptor
        let errFd = stderrPipe.fileHandleForWriting.fileDescriptor
        posix_spawn_file_actions_adddup2(&fileActions, outFd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errFd, STDERR_FILENO)

        var spawnAttr: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttr)
        posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var cArgs = [strdup(command)]
        for arg in args { cArgs.append(strdup(arg)) }
        cArgs.append(nil)

        let env = environment(for: args)
        var cEnv: [UnsafeMutablePointer<CChar>?] = []
        for (k, v) in env { cEnv.append(strdup("\(k)=\(v)")) }
        cEnv.append(nil)

        var pid: pid_t = 0
        let spawnRes = posix_spawn(&pid, command, &fileActions, &spawnAttr, cArgs, cEnv.count > 1 ? cEnv : nil)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&spawnAttr)
        if devNull >= 0 { close(devNull) }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        for p in cArgs { if let p { free(p) } }
        for p in cEnv { if let p { free(p) } }

        guard spawnRes == 0 else {
            return (spawnRes, Data(), "posix_spawn failed")
        }

        try? AppProcessLifecycle.registerPID(pid)

        return await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            let lock = NSLock()
            var stdoutData = Data()
            var stderrData = Data()
            var isTerminated = false

            // Cancellation monitor
            DispatchQueue.global(qos: .utility).async {
                while true {
                    lock.lock()
                    let done = isTerminated
                    lock.unlock()
                    if done { break }
                    if cancellationCheck() {
                        kill(pid, SIGKILL)
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }

            // Read stdout
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let chunk = stdoutPipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    lock.lock()
                    stdoutData.append(chunk)
                    let shouldStop = maxBytes > 0 && stdoutData.count >= maxBytes
                    lock.unlock()
                    if shouldStop {
                        kill(pid, SIGKILL)
                        break
                    }
                }
                group.leave()
            }

            // Read stderr
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let chunk = stderrPipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    lock.lock()
                    stderrData.append(chunk)
                    lock.unlock()
                }
                group.leave()
            }

            // Wait for exit
            DispatchQueue.global(qos: .userInitiated).async {
                var status: Int32 = 0
                waitpid(pid, &status, 0)

                lock.lock()
                isTerminated = true
                lock.unlock()

                AppProcessLifecycle.didExitPID(pid)
                group.wait()

                let exitCode: Int32
                if (status & 0x7f) == 0 {
                    exitCode = (status >> 8) & 0xff
                } else {
                    exitCode = -1
                }

                lock.lock()
                if maxBytes > 0 && stdoutData.count > maxBytes {
                    stdoutData = stdoutData.prefix(maxBytes)
                }
                let errStr = String(data: stderrData, encoding: .utf8) ?? ""
                lock.unlock()

                continuation.resume(returning: (exitCode, stdoutData, errStr))
            }
        }
    }
    
    // New: Run with progress tracking and cancellation support using posix_spawn
    static func runWithProgressCancellable(
        _ command: String,
        args: [String],
        progressCallback: @escaping (String) -> Void,
        cancellationCheck: @escaping () -> Bool = { false }
    ) async -> (Int32, String, String, Process) {
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)

        let devNull = open("/dev/null", O_RDONLY)
        if devNull >= 0 {
            posix_spawn_file_actions_adddup2(&fileActions, devNull, STDIN_FILENO)
            posix_spawn_file_actions_addclose(&fileActions, devNull)
        }

        let outFd = stdoutPipe.fileHandleForWriting.fileDescriptor
        let errFd = stderrPipe.fileHandleForWriting.fileDescriptor
        posix_spawn_file_actions_adddup2(&fileActions, outFd, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, errFd, STDERR_FILENO)

        var spawnAttr: posix_spawnattr_t?
        posix_spawnattr_init(&spawnAttr)
        posix_spawnattr_setflags(&spawnAttr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        var cArgs = [strdup(command)]
        for arg in args { cArgs.append(strdup(arg)) }
        cArgs.append(nil)

        let env = environment(for: args)
        var cEnv: [UnsafeMutablePointer<CChar>?] = []
        for (k, v) in env { cEnv.append(strdup("\(k)=\(v)")) }
        cEnv.append(nil)

        var pid: pid_t = 0
        let spawnRes = posix_spawn(&pid, command, &fileActions, &spawnAttr, cArgs, cEnv.count > 1 ? cEnv : nil)
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&spawnAttr)
        if devNull >= 0 { close(devNull) }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        for p in cArgs { if let p { free(p) } }
        for p in cEnv { if let p { free(p) } }

        guard spawnRes == 0 else {
            return (spawnRes, "", "posix_spawn failed", Process())
        }

        try? AppProcessLifecycle.registerPID(pid)

        return await withCheckedContinuation { continuation in
            let group = DispatchGroup()
            let lock = NSLock()
            var stdoutData = Data()
            var stderrData = Data()
            var isTerminated = false

            // Start cancellation monitor
            DispatchQueue.global(qos: .utility).async {
                while true {
                    lock.lock()
                    let done = isTerminated
                    lock.unlock()
                    if done { break }
                    if cancellationCheck() {
                        print("🛑 Shell: Cancellation detected! Killing PID \(pid) with SIGKILL...")
                        kill(pid, SIGKILL)
                        break
                    }
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }

            // Read stdout
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let chunk = stdoutPipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    lock.lock()
                    stdoutData.append(chunk)
                    lock.unlock()
                }
                group.leave()
            }

            // Read stderr (ADB progress outputs to stderr)
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                while true {
                    let chunk = stderrPipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    lock.lock()
                    stderrData.append(chunk)
                    lock.unlock()
                    if let text = String(data: chunk, encoding: .utf8), !text.isEmpty {
                        DispatchQueue.main.async {
                            progressCallback(text)
                        }
                    }
                }
                group.leave()
            }

            // Wait for exit
            DispatchQueue.global(qos: .userInitiated).async {
                var status: Int32 = 0
                waitpid(pid, &status, 0)

                lock.lock()
                isTerminated = true
                lock.unlock()

                AppProcessLifecycle.didExitPID(pid)
                group.wait()

                let exitCode: Int32
                if (status & 0x7f) == 0 {
                    exitCode = (status >> 8) & 0xff
                } else {
                    exitCode = -1
                }

                let outStr = String(data: stdoutData, encoding: .utf8) ?? ""
                let errStr = String(data: stderrData, encoding: .utf8) ?? ""
                continuation.resume(returning: (exitCode, outStr, errStr, Process()))
            }
        }
    }

}
