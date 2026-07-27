// AudioTapRecorder — マイクとシステム音声を1つのステレオ m4a に録音する CLI
//   L チャンネル: デフォルト入力デバイス（自分の声）
//   R チャンネル: システム音声のプロセスタップ（会議相手の声。出力デバイスに関係なく取れる）
// 使い方: MeetingScribeRecorder <output.m4a>   SIGINT/SIGTERM で停止・ファイナライズ
// ビルド: ./build.sh（macOS 14.4+ の Core Audio process tap API を使用）
import AVFoundation
import CoreAudio
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("error: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func check(_ status: OSStatus, _ what: String) {
    if status != noErr { fail("\(what) failed (OSStatus \(status))") }
}

// MARK: - Core Audio プロパティ取得ヘルパー

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

// MARK: - セットアップ

guard CommandLine.arguments.count == 2 else { fail("usage: MeetingScribeRecorder <output.m4a>") }
let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])

let micDevice = defaultInputDevice()
let micChannels = max(1, inputChannelCount(micDevice))
FileHandle.standardError.write("input device: \(deviceName(micDevice)) (\(micChannels)ch)\n".data(using: .utf8)!)

// システム音声のグローバルタップ（除外プロセスなし = 全アプリの出力音声）
let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
tapDescription.name = "MeetingScribeTap"
tapDescription.isPrivate = true
var tapID = AudioObjectID(kAudioObjectUnknown)
check(AudioHardwareCreateProcessTap(tapDescription, &tapID), "create process tap")

// マイクとタップを1つの集約デバイスにまとめる（ドリフト補正はCore Audio任せ）
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

// MARK: - タップのキープアライブ

// システム音声が完全に無音だとタップが止まり、集約デバイスの IO コールバックごと
// 止まってしまう（実機確認済み）。無音を常時再生してタップを流しっぱなしにする。
// ゼロを混ぜるだけなので録音内容には影響しない。
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
        FileHandle.standardError.write("warning: silence engine failed: \(error)\n".data(using: .utf8)!)
    }
}
// 出力デバイスが切り替わるとエンジンが止まるので再起動する
NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                                       object: silenceEngine, queue: nil) { _ in
    startSilenceEngine()
}
startSilenceEngine()

// MARK: - 録音ループ

// 集約デバイスの入力バッファは「サブデバイス（マイク）→ タップ」の順にチャンネルが並ぶ。
// 先頭 micChannels ch を L（自分）、残りを R（相手）に平均して書き込む。
// 既知の制限: 録音中に入力デバイスが消える（AirPods の電池切れ等）とチャンネル構成が
// 変わり L/R の割り当てが崩れる可能性がある。その場合は録音を止めて再開すること。
let ioQueue = DispatchQueue(label: "recorder.io")
var ioProcID: AudioDeviceIOProcID?
var writeFailed = false
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
    for frame in 0..<frameCount {
        var mic: Float = 0
        for source in micSources { mic += sample(source, frame) }
        left[frame] = micSources.isEmpty ? 0 : mic / Float(micSources.count)
        var tap: Float = 0
        for source in tapSources { tap += sample(source, frame) }
        right[frame] = tapSources.isEmpty ? 0 : tap / Float(tapSources.count)
    }
    do {
        try audioFile.write(from: pcm)
    } catch {
        // ディスクフル等で書けなくなったら「録音中」のまま無音を垂れ流さず、
        // ログを残してシグナルハンドラのファイナライズ経路で終了する
        if !writeFailed {
            writeFailed = true
            FileHandle.standardError.write("error: write failed: \(error)\n".data(using: .utf8)!)
            kill(getpid(), SIGTERM)
        }
    }
}, "create IO proc")

check(AudioDeviceStart(aggregateID, ioProcID), "start aggregate device")
FileHandle.standardError.write("recording to \(outputURL.path) @\(Int(sampleRate))Hz\n".data(using: .utf8)!)

// MARK: - 終了処理（SIGINT / SIGTERM でファイナライズ）

func makeSignalHandler(_ sig: Int32) -> DispatchSourceSignal {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        AudioDeviceStop(aggregateID, ioProcID)
        if let ioProcID { AudioDeviceDestroyIOProcID(aggregateID, ioProcID) }
        // ioQueue 上の書き込みが終わってからファイルを閉じる
        ioQueue.sync {}
        audioFile.close()
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
