import Foundation

// 録音中の raw PCM（2ch float32 インターリーブ）を一定間隔で切り出し、自分/相手を並列に whisper にかける
final class LiveTranscriber {
    private static let bytesPerFrame: UInt64 = 8
    private static let minChunkSecs: UInt64 = 2

    private let config: LiveConfig
    private let pcmPath: String
    private let transcriptPath: String
    private let queue = DispatchQueue(label: "live.transcribe")
    private let tmpDir: String
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var running: [Process] = []
    private var stopped = false
    private var offset: UInt64
    private var rate: UInt64?

    init(config: LiveConfig, pcmPath: String, transcriptPath: String, resumeFromEnd: Bool) {
        self.config = config
        self.pcmPath = pcmPath
        self.transcriptPath = transcriptPath
        tmpDir = NSTemporaryDirectory() + "meetingscribe-live-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        offset = resumeFromEnd ? LiveTranscriber.frameAlignedSize(pcmPath) : 0
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .seconds(config.intervalSecs), repeating: .seconds(config.intervalSecs))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    // 実行中の whisper ごと止める。残すと最終文字起こしとモデルが同時に走る
    func stop() {
        lock.lock()
        stopped = true
        running.forEach { $0.terminate() }
        lock.unlock()
        timer?.cancel()
        queue.async { [tmpDir] in try? FileManager.default.removeItem(atPath: tmpDir) }
    }

    private static func frameAlignedSize(_ path: String) -> UInt64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64 ?? 0
        return size / bytesPerFrame * bytesPerFrame
    }

    private func tick() {
        if rate == nil {
            rate = (try? String(contentsOfFile: pcmPath + ".rate", encoding: .utf8))
                .flatMap { UInt64($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        guard let rate else { return }
        let size = LiveTranscriber.frameAlignedSize(pcmPath)
        guard size > offset, size - offset >= rate * LiveTranscriber.bytesPerFrame * LiveTranscriber.minChunkSecs,
              let handle = FileHandle(forReadingAtPath: pcmPath) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.read(upToCount: Int(size - offset)) else { return }

        let selfWav = "\(tmpDir)/self.wav", othersWav = "\(tmpDir)/others.wav"
        let split = [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "f32le", "-ar", "\(rate)", "-ac", "2", "-i", "pipe:0",
            "-filter_complex", "[0:a]channelsplit=channel_layout=stereo[l][r]",
            "-map", "[l]", "-ac", "1", "-ar", "16000", selfWav,
            "-map", "[r]", "-ac", "1", "-ar", "16000", othersWav,
        ]
        guard run(config.ffmpegBin, split, stdin: chunk) else { return }

        let offsetMs = offset / LiveTranscriber.bytesPerFrame * 1000 / rate
        offset = size

        let whispers = [("self", selfWav), ("others", othersWav)].map { name, wav in
            launch(config.whisperBin, [
                "-m", config.model, "-l", config.language, "-f", wav, "-oj", "-of", "\(tmpDir)/\(name)", "-np",
                "--vad", "--vad-model", config.vadModel,
            ], stderrPath: "\(tmpDir)/\(name).log")
        }
        let succeeded = whispers.map { $0.map(wait) == true }
        guard !succeeded.contains(false) else {
            logWhisperFailure()
            return
        }

        let output = Pipe()
        let merge = [config.mergeScript, "\(tmpDir)/self.json", "\(tmpDir)/others.json",
                     "--offset-ms", "\(offsetMs)", "--labels", "always"]
        guard let process = launch("/usr/bin/python3", merge, stdout: output) else { return }
        let text = output.fileHandleForReading.readDataToEndOfFile()
        guard wait(process), let transcript = FileHandle(forWritingAtPath: transcriptPath) else { return }
        defer { try? transcript.close() }
        _ = try? transcript.seekToEnd()
        try? transcript.write(contentsOf: text)
    }

    // whisper は -np でも GPU の初期化ログを大量に出すので、失敗したときだけ record.log に残す
    private func logWhisperFailure() {
        lock.lock()
        let wasStopped = stopped
        lock.unlock()
        guard !wasStopped else { return }
        let log = logHandle()
        for name in ["self", "others"] {
            if let data = FileManager.default.contents(atPath: "\(tmpDir)/\(name).log") { log.write(data) }
        }
    }

    private func run(_ executable: String, _ arguments: [String], stdin data: Data) -> Bool {
        let input = Pipe()
        guard let process = launch(executable, arguments, stdin: input) else { return false }
        try? input.fileHandleForWriting.write(contentsOf: data)
        try? input.fileHandleForWriting.close()
        return wait(process)
    }

    private func launch(_ executable: String, _ arguments: [String], stdin: Pipe? = nil, stdout: Pipe? = nil,
                        stderrPath: String? = nil) -> Process? {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = stdin ?? FileHandle.nullDevice
        process.standardOutput = stdout ?? FileHandle.nullDevice
        if let stderrPath, FileManager.default.createFile(atPath: stderrPath, contents: nil),
           let handle = FileHandle(forWritingAtPath: stderrPath) {
            process.standardError = handle
        } else {
            process.standardError = logHandle()
        }
        guard (try? process.run()) != nil else { return nil }
        running.append(process)
        return process
    }

    private func wait(_ process: Process) -> Bool {
        process.waitUntilExit()
        lock.lock()
        running.removeAll { $0 === process }
        lock.unlock()
        return process.terminationStatus == 0
    }
}
