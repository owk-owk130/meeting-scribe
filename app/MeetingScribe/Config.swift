import Foundation

// .app は build.sh がプロジェクトルートに生成するので、バンドルの親 = プロジェクトルート
let rootDir = URL(fileURLWithPath: Bundle.main.bundlePath).deletingLastPathComponent().path
let stateDir = "\(rootDir)/state"
let liveTranscriptFile = "\(stateDir)/live-transcript.md"
let logFile = "\(stateDir)/record.log"

struct Config {
    let recordingsDir: String
    let vaultMeetingsDir: String
    let liveTranscribe: Bool
    let silenceStopMins: String
    let silenceThresholdDB: String
    let maxRecordMins: String
    let recordingsKeepDays: Int
    let inboxDir: String
    let remindMeetings: Bool
    let live: LiveConfig
}

struct LiveConfig {
    let intervalSecs: Int
    let whisperBin: String
    let ffmpegBin: String
    let model: String
    let vadModel: String
    let language: String
    let mergeScript: String
}

// ツールの既定パスは common.sh が持つので、shell スクリプトと同じ値を読む
func loadConfig() -> Config? {
    let variables = [
        "$RECORDINGS_DIR", "$VAULT_MEETINGS_DIR", "${LIVE_TRANSCRIBE:-1}", "${SILENCE_STOP_MINS:-0}",
        "${SILENCE_THRESHOLD_DB:-}", "${MAX_RECORD_MINS:-0}", "${RECORDINGS_KEEP_DAYS:-0}", "${INBOX_DIR:-}",
        "${REMIND_MEETINGS:-1}", "${LIVE_INTERVAL_SECS:-30}", "$WHISPER_BIN", "$FFMPEG_BIN", "$MODEL", "$VAD_MODEL", "$WHISPER_LANG",
    ]
    let result = runShell("/bin/bash", [
        "-c",
        "ROOT_DIR=\"\(rootDir)\" SCRIPT_DIR=\"\(rootDir)/scripts\" && source \"$ROOT_DIR/config.sh\" "
            + "&& source \"$SCRIPT_DIR/common.sh\" && printf '%s\\n' "
            + variables.map { "\"\($0)\"" }.joined(separator: " "),
    ])
    let lines = result.stdout.components(separatedBy: "\n")
    guard result.exitCode == 0, lines.count == variables.count, !lines[0].isEmpty, !lines[1].isEmpty else { return nil }
    let live = LiveConfig(intervalSecs: Int(lines[9]) ?? 30, whisperBin: lines[10], ffmpegBin: lines[11],
                          model: lines[12], vadModel: lines[13], language: lines[14],
                          mergeScript: "\(rootDir)/scripts/merge_transcript.py")
    return Config(recordingsDir: lines[0], vaultMeetingsDir: lines[1], liveTranscribe: lines[2] != "0",
                  silenceStopMins: lines[3], silenceThresholdDB: lines[4], maxRecordMins: lines[5],
                  recordingsKeepDays: Int(lines[6]) ?? 0, inboxDir: lines[7],
                  remindMeetings: lines[8] != "0", live: live)
}

let config = loadConfig()
