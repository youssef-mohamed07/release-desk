import Foundation

/// Runs command line tools with the user's login PATH (an app opened from
/// Finder has a bare PATH and would not find flutter), streaming each line.
public enum Shell {
    private static let pathBox = PathBox()

    /// The PATH a login zsh gets, read once.
    public static func loginPATH() async -> String {
        if let p = await pathBox.value { return p }
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        var path = fallback
        if let r = try? await capture("/bin/zsh", ["-lc", "print -r -- $PATH"], path: fallback),
           let line = r.split(separator: "\n").last, line.contains("/") {
            path = String(line)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for extra in ["\(home)/flutter/bin", "\(home)/fvm/default/bin", "/opt/homebrew/bin"] where !path.contains(extra) {
            if FileManager.default.fileExists(atPath: extra) { path += ":\(extra)" }
        }
        await pathBox.set(path)
        return path
    }

    /// Runs and returns all output; throws on a non-zero exit.
    public static func capture(_ exe: String, _ args: [String], cwd: URL? = nil, path: String? = nil) async throws -> String {
        let out = LineCollector()
        let code = try await run(exe, args, cwd: cwd, path: path) { out.append($0) }
        guard code == 0 else { throw ReleaseError.command(([exe] + args).joined(separator: " "), code: code, tail: out.tail(8)) }
        return out.text
    }

    /// Runs `exe` (a path, or a name looked up on PATH) and calls `onLine`
    /// for every line of stdout and stderr. Cancelling the task stops it.
    public static func run(_ exe: String, _ args: [String], cwd: URL? = nil, path: String? = nil,
                           environment: [String: String] = [:], stdin: Data? = nil,
                           onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let resolvedPATH: String
        if let path { resolvedPATH = path } else { resolvedPATH = await loginPATH() }
        let process = Process()
        if exe.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [exe] + args
        }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = resolvedPATH
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["NSUnbufferedIO"] = "YES"
        for (k, v) in environment { env[k] = v }
        process.environment = env
        if let cwd { process.currentDirectoryURL = cwd }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let input = stdin.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        let splitter = LineSplitter(onLine)
        // Read on a thread of its own until EOF, and only return once both the
        // output is drained and the process has exited. A tool that leaves a
        // helper holding the pipe open gets two seconds of grace after exit.
        let drained = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { p in
                    DispatchQueue.global().async {
                        _ = drained.wait(timeout: .now() + 2)
                        splitter.flush()
                        cont.resume(returning: p.terminationStatus)
                    }
                }
                do {
                    try process.run()
                    if let input, let stdin {
                        input.fileHandleForWriting.write(stdin)
                        try? input.fileHandleForWriting.close()
                    }
                    Thread.detachNewThread {
                        while true {
                            let d = reader.availableData
                            if d.isEmpty { break }
                            splitter.feed(d)
                        }
                        drained.signal()
                    }
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: ReleaseError.command(exe, code: -1, tail: error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning {
                process.interrupt()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if process.isRunning { process.terminate() } }
            }
        }
    }
}

private actor PathBox {
    var value: String?
    func set(_ v: String) { value = v }
}

/// Turns chunks of bytes into lines; carriage returns (progress bars) count
/// as line ends too.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    private let onLine: @Sendable (String) -> Void

    init(_ onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let i = buffer.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
            let line = String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...i)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(line) }
        }
        lock.unlock()
        lines.forEach(onLine)
    }

    func flush() {
        lock.lock()
        let rest = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        lock.unlock()
        if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onLine(rest) }
    }
}

final class LineCollector: @unchecked Sendable {
    private var lines: [String] = []
    private let lock = NSLock()
    func append(_ l: String) { lock.lock(); lines.append(l); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    func tail(_ n: Int) -> String { lock.lock(); defer { lock.unlock() }; return lines.suffix(n).joined(separator: "\n") }
}
