import AVFoundation
import CoreAudio
import Foundation

func log(_ message: String) {
    FileHandle.standardError.write("\(message)\n".data(using: .utf8)!)
}

func fail(_ message: String) -> Never {
    log("error: \(message)")
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) failed (OSStatus \(status))") }
}

func propertyAddress(_ selector: AudioObjectPropertySelector,
                     scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func defaultInputDevice() -> AudioObjectID {
    var address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    var device = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device),
          "get default input device")
    if device == kAudioObjectUnknown { fail("入力デバイスが見つかりません") }
    return device
}

func deviceUID(_ device: AudioObjectID) -> String {
    var address = propertyAddress(kAudioDevicePropertyDeviceUID)
    var uid: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    check(withUnsafeMutablePointer(to: &uid) {
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
    }, "get device UID")
    return uid as String
}

func deviceName(_ device: AudioObjectID) -> String {
    var address = propertyAddress(kAudioObjectPropertyName)
    var name: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    guard withUnsafeMutablePointer(to: &name, {
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
    }) == noErr else { return "(unknown)" }
    return name as String
}

func inputChannelCount(_ device: AudioObjectID) -> Int {
    var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), "get stream configuration size")
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw), "get stream configuration")
    let bufferList = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
    return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
}

func nominalSampleRate(_ device: AudioObjectID) -> Double {
    var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
    var rate: Float64 = 0
    var size = UInt32(MemoryLayout<Float64>.size)
    check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate), "get sample rate")
    return rate
}

// 呼び出しは IO キュー上に限られるので排他は不要
final class AutoStopMonitor {
    private let silenceStopSecs: TimeInterval
    private let maxRecordSecs: TimeInterval
    private let silenceThresholdDB: Double
    private let stopScript: String?
    private let startedAt = Date()
    private var lastSoundAt: Date
    private var lastLevelLogAt: Date
    private var levelMaxDB = -Double.infinity
    private var stopRequested = false

    init(silenceStopSecs: TimeInterval, maxRecordSecs: TimeInterval, silenceThresholdDB: Double, stopScript: String?) {
        self.silenceStopSecs = silenceStopSecs
        self.maxRecordSecs = maxRecordSecs
        self.silenceThresholdDB = silenceThresholdDB
        self.stopScript = stopScript
        lastSoundAt = startedAt
        lastLevelLogAt = startedAt
    }

    func observe(sumOfSquares: Float, frames: Int) {
        let now = Date()
        let rms = (sumOfSquares / Float(frames)).squareRoot()
        let db = rms > 0 ? 20 * log10(Double(rms)) : -Double.infinity
        if silenceStopSecs > 0 {
            levelMaxDB = max(levelMaxDB, db)
            if db > silenceThresholdDB { lastSoundAt = now }
            if now.timeIntervalSince(lastLevelLogAt) >= 60 {
                log(String(format: "level: max %.1f dBFS / 60s (threshold %.0f)", levelMaxDB, silenceThresholdDB))
                lastLevelLogAt = now
                levelMaxDB = -Double.infinity
            }
            if now.timeIntervalSince(lastSoundAt) >= silenceStopSecs {
                requestStop("無音が \(Int(silenceStopSecs / 60)) 分続いたため録音を自動停止しました")
            }
        }
        if maxRecordSecs > 0, now.timeIntervalSince(startedAt) >= maxRecordSecs {
            requestStop("録音が \(Int(maxRecordSecs / 60)) 分に達したため自動停止しました")
        }
    }

    private func requestStop(_ reason: String) {
        guard !stopRequested else { return }
        stopRequested = true
        log("auto-stop: \(reason)")
        guard let stopScript else { kill(getpid(), SIGINT); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [stopScript, "stop", reason]
        do { try process.run() } catch { kill(getpid(), SIGINT) }
    }
}

guard (2...3).contains(CommandLine.arguments.count) else {
    fail("usage: MeetingScribeRecorder <output.m4a> [live-pcm-path]")
}
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let livePCMPath = CommandLine.arguments.count == 3 ? CommandLine.arguments[2] : nil

let environment = ProcessInfo.processInfo.environment
func envMinutes(_ key: String) -> TimeInterval {
    (environment[key].flatMap(Double.init) ?? 0) * 60
}

let micDevice = defaultInputDevice()
let micChannels = max(1, inputChannelCount(micDevice))
log("input device: \(deviceName(micDevice)) (\(micChannels)ch)")

let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDescription.name = "MeetingScribeTap"
tapDescription.isPrivate = true
var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "create process tap")

let aggregateDescription: [String: Any] = [
    kAudioAggregateDeviceNameKey: "MeetingScribe Recorder",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceIsPrivateKey: true,
    // クロックをマイク側にしないと、システム音声が鳴るまで IO コールバックが始まらない
    kAudioAggregateDeviceMainSubDeviceKey: deviceUID(micDevice),
    kAudioAggregateDeviceSubDeviceListKey: [
        [kAudioSubDeviceUIDKey: deviceUID(micDevice),
         kAudioSubDeviceDriftCompensationKey: true],
    ],
    kAudioAggregateDeviceTapListKey: [
        [kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
         kAudioSubTapDriftCompensationKey: true],
    ],
    kAudioAggregateDeviceTapAutoStartKey: true,
]
var aggregateID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
      "create aggregate device")

let sampleRate = nominalSampleRate(aggregateID)
guard let fileFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                     channels: 2, interleaved: false)
else { fail("audio format の作成に失敗しました") }
let audioFile: AVAudioFile
do {
    audioFile = try AVAudioFile(
        forWriting: outputURL,
        settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 96000,
        ],
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
} catch {
    fail("出力ファイルを作成できません: \(error.localizedDescription)")
}

// ライブ用 PCM を開けなくても録音は続ける
var liveHandle: FileHandle?
if let livePCMPath {
    FileManager.default.createFile(atPath: livePCMPath, contents: nil)
    liveHandle = FileHandle(forWritingAtPath: livePCMPath)
    if liveHandle == nil {
        log("warning: live pcm を開けません: \(livePCMPath)")
    } else {
        try? String(Int(sampleRate)).write(toFile: livePCMPath + ".rate", atomically: true, encoding: .utf8)
    }
}

// システム音声が完全に無音だとタップが止まり、集約デバイスの IO コールバックごと
// 止まってしまう。無音を常時再生してタップを流しっぱなしにする
let silenceEngine = AVAudioEngine()
let silenceSource = AVAudioSourceNode { _, _, _, audioBufferList -> OSStatus in
    for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    return noErr
}
silenceEngine.attach(silenceSource)
silenceEngine.connect(silenceSource, to: silenceEngine.mainMixerNode,
                      format: AVAudioFormat(standardFormatWithSampleRate:
                          silenceEngine.outputNode.outputFormat(forBus: 0).sampleRate, channels: 1))
func startSilenceEngine() {
    do { try silenceEngine.start() } catch {
        log("warning: silence engine failed: \(error)")
    }
}
// 出力デバイスが切り替わるとエンジンが止まるので再起動する
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                       object: silenceEngine, queue: nil) { _ in
    startSilenceEngine()
}
startSilenceEngine()

// 集約デバイスの入力バッファは「サブデバイス（マイク）→ タップ」の順にチャンネルが並ぶ。
// 先頭 micChannels ch を L（自分）、残りを R（相手）に平均して書き込む。
// 録音中に入力デバイスが消えるとチャンネル構成が変わり L/R の割り当てが崩れる
let ioQueue = DispatchQueue(label: "recorder.io")
var ioProcID: AudioDeviceIOProcID?
var writeFailed = false

let autoStop = AutoStopMonitor(
    silenceStopSecs: envMinutes("SILENCE_STOP_MINS"),
    maxRecordSecs: envMinutes("MAX_RECORD_MINS"),
    silenceThresholdDB: environment["SILENCE_THRESHOLD_DB"].flatMap(Double.init) ?? -50,
    stopScript: environment["RECORD_SCRIPT"]
)
check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { _, inputData, _, _, _ in
    // 各バッファ内はインターリーブの可能性があるため (データ位置, ストライド) で全チャンネルを平坦化する。
    // システム音声が鳴っていないときタップのバッファは 0 フレームになるので、
    // フレーム数はバッファごとに持ち、足りない分は無音（0）として扱う
    // （min を取るとタップ無音時にマイク分まで捨ててしまう）。
    var channels: [(data: UnsafePointer<Float>?, stride: Int, offset: Int, frames: Int)] = []
    var frameCount = 0
    for buffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData)) {
        let data = buffer.mData?.assumingMemoryBound(to: Float.self)
        let bufferChannels = max(1, Int(buffer.mNumberChannels))
        let frames = data == nil ? 0 : Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / bufferChannels
        frameCount = max(frameCount, frames)
        for channel in 0..<bufferChannels {
            channels.append((data.map { UnsafePointer($0) }, bufferChannels, channel, frames))
        }
    }
    guard frameCount > 0, channels.count > micChannels || !channels.isEmpty,
          let pcm = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: AVAudioFrameCount(frameCount)),
          let left = pcm.floatChannelData?[0], let right = pcm.floatChannelData?[1]
    else { return }
    pcm.frameLength = AVAudioFrameCount(frameCount)

    func sample(_ source: (data: UnsafePointer<Float>?, stride: Int, offset: Int, frames: Int), _ frame: Int) -> Float {
        guard let data = source.data, frame < source.frames else { return 0 }
        return data[frame * source.stride + source.offset]
    }
    let micSources = channels.prefix(micChannels)
    let tapSources = channels.dropFirst(micChannels)
    var interleaved: [Float] = liveHandle == nil ? [] : .init(repeating: 0, count: frameCount * 2)
    var sumOfSquares: Float = 0
    for frame in 0..<frameCount {
        var mic: Float = 0
        for source in micSources { mic += sample(source, frame) }
        let l = micSources.isEmpty ? 0 : mic / Float(micSources.count)
        left[frame] = l
        var tap: Float = 0
        for source in tapSources { tap += sample(source, frame) }
        let r = tapSources.isEmpty ? 0 : tap / Float(tapSources.count)
        right[frame] = r
        sumOfSquares += max(l * l, r * r)
        if !interleaved.isEmpty {
            interleaved[frame * 2] = l
            interleaved[frame * 2 + 1] = r
        }
    }
    autoStop.observe(sumOfSquares: sumOfSquares, frames: frameCount)
    if let handle = liveHandle {
        do {
            try handle.write(contentsOf: interleaved.withUnsafeBufferPointer { Data(buffer: $0) })
        } catch {
            log("warning: live pcm write failed: \(error)")
            liveHandle = nil
        }
    }
    do {
        try audioFile.write(from: pcm)
    } catch {
        // 書けなくなったら「録音中」のまま続けず、シグナル経由でファイナライズして終わる
        if !writeFailed {
            writeFailed = true
            log("error: write failed: \(error)")
            kill(getpid(), SIGTERM)
        }
    }
}, "create IO proc")

check(AudioDeviceStart(aggregateID, ioProcID), "start aggregate device")
log("recording to \(outputURL.path) @\(Int(sampleRate))Hz")

func makeSignalHandler(_ sig: Int32) -> DispatchSourceSignal {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        AudioDeviceStop(aggregateID, ioProcID)
        if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
        // ioQueue 上の書き込みが終わってからファイルを閉じる
        ioQueue.sync {}
        audioFile.close()
        try? liveHandle?.close()
        AudioHardwareDestroyAggregateDevice(aggregateID)
        AudioHardwareDestroyProcessTap(tapID)
        exit(0)
    }
    source.resume()
    return source
}
let sigintSource = makeSignalHandler(SIGINT)
let sigtermSource = makeSignalHandler(SIGTERM)

dispatchMain()
