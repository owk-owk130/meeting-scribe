import Foundation

// 子プロセス同士（recorder / whisper / transcribe.sh）が同じログに同時に書くので追記モードで開く
func logHandle() -> FileHandle {
    FileHandle(fileDescriptor: open(logFile, O_WRONLY | O_APPEND | O_CREAT, 0o644), closeOnDealloc: true)
}

struct ShellResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

func runShell(_ launchPath: String, _ args: [String]) -> ShellResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
    } catch {
        return ShellResult(stdout: "", stderr: "\(error.localizedDescription)", exitCode: -1)
    }
    // パイプが詰まらないよう wait より先に EOF まで読み切る
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    func decode(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    return ShellResult(stdout: decode(outData), stderr: decode(errData), exitCode: process.terminationStatus)
}

func notify(_ message: String) {
    _ = runShell("/usr/bin/osascript", ["-e", "display notification \"\(message)\" with title \"MeetingScribe\""])
}

func processPath(_ pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
}
