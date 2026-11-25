import Accelerate
import AVFoundation
import CoreAudio
import Synchronization
import TapeCore

enum CaptureEvent: Sendable, Equatable {
    case microphone(String?)
    case systemAudioDenied
    case deviceFailed
    case writeFailed
}

struct CaptureError: LocalizedError {
    let errorDescription: String?
    let isPermissionDenied: Bool

    init(_ message: String, status: OSStatus = noErr) {
        errorDescription = status == noErr ? message : "\(message) (\(status))"
        isPermissionDenied = status == kAudioDevicePermissionsError
    }
}

// The realtime IOProc only copies into `ring`. Device state is owned by `controlQueue`; echo cancelling, conversion and writing by `processingQueue`.
final class CaptureSession: @unchecked Sendable {
    private static let outputRate = 48000.0
    private static let rebuildAttemptsWithMicrophone = 3
    private static let firstAudioTimeout = 5.0
    private static let systemSignalWindow: UInt64 = 8_000_000_000

    private let controlQueue = DispatchQueue(label: "dev.gustaf.tape.control")
    private let processingQueue = DispatchQueue(label: "dev.gustaf.tape.processing", qos: .userInitiated)
    private let ring: AudioRing?
    private let deviceRate = Atomic<UInt64>(0)
    private let lastSystemSignal = Atomic<UInt64>(0)
    private let deniedSystemAudio = Atomic<Bool>(false)
    private let heardMicrophone = Atomic<Bool>(false)
    private let output: (writer: AVAssetWriter, input: AVAssetWriterInput)?
    private let outputFormat: AVAudioFormat
    private let makeEchoCanceller: (@Sendable (Double) -> EchoCanceller)?
    private let onEvent: @Sendable (CaptureEvent) -> Void

    private var tap: (id: AudioObjectID, description: CATapDescription)?
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var rateListeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    private var defaultDeviceListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var rebuildRequest = 0
    private var isStopping = false

    private let resampler: Resampler
    private var echoCanceller: EchoCanceller?
    private var limiter = PeakLimiter(sampleRate: CaptureSession.outputRate)
    private var framesWritten: Int64 = 0
    private var expectedHostSeconds: Double?
    private var isFinished = false
    private var drainTimer: DispatchSourceTimer?
    private let silence = [Float](repeating: 0, count: 4096)

    var systemSignalDetected: Bool { lastSystemSignal.load(ordering: .relaxed) != 0 }
    var hasRecentSystemAudio: Bool {
        let last = lastSystemSignal.load(ordering: .relaxed)
        let now = DispatchTime.now().uptimeNanoseconds
        return last != 0 && now >= last && now - last < Self.systemSignalWindow
    }
    var systemPermissionDenied: Bool { deniedSystemAudio.load(ordering: .relaxed) }
    var microphoneSignalDetected: Bool { heardMicrophone.load(ordering: .relaxed) }

    init(url: URL?, makeEchoCanceller: (@Sendable (Double) -> EchoCanceller)?, onEvent: @escaping @Sendable (CaptureEvent) -> Void) throws {
        if let url {
            let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
            writer.movieFragmentInterval = CMTime(seconds: 10, preferredTimescale: 600)
            writer.initialMovieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: Self.outputRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64000,
            ])
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            output = (writer, input)
            ring = AudioRing(slots: 256, framesPerSlot: 2 * 8192)
        } else {
            output = nil
            ring = nil
        }
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.outputRate, channels: 1, interleaved: false) else {
            throw CaptureError("无法设置录音输出格式。")
        }
        self.outputFormat = outputFormat
        resampler = Resampler(outputFormat: outputFormat)
        self.makeEchoCanceller = makeEchoCanceller
        self.onEvent = onEvent
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
            controlQueue.async { [self] in
                do {
                    if let output {
                        guard output.writer.startWriting() else { throw output.writer.error ?? CaptureError("无法创建录音文件。") }
                        output.writer.startSession(atSourceTime: .zero)
                        processingQueue.sync { startDraining() }
                    }
                    tap = try Self.makeTap()
                    try startAggregate(includeMicrophone: output != nil)
                    scheduleProbe(after: 3, repeatWhileRecording: output != nil)
                    if output != nil {
                        listenForDefaultDevices()
                        controlQueue.asyncAfter(deadline: .now() + 8) { [weak self] in self?.probeSystemAudioPermission() }
                        processingQueue.asyncAfter(deadline: .now() + Self.firstAudioTimeout) { [weak self] in
                            guard let self, !isFinished, framesWritten == 0 else { return }
                            onEvent(.deviceFailed)
                        }
                    }
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    func finish() async -> Bool {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            controlQueue.async { [self] in
                isStopping = true
                for (selector, listener) in defaultDeviceListeners {
                    var address = Self.address(selector)
                    AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
                }
                defaultDeviceListeners = []
                stopAggregate()
                if let tap { AudioHardwareDestroyProcessTap(tap.id) }
                tap = nil
                done.resume()
            }
        }
        guard output != nil else { return systemSignalDetected }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            processingQueue.async { [self] in
                drainTimer?.cancel()
                drainTimer = nil
                drain()
                if let echoCanceller { append(resampler.convert(echoCanceller.flush(), rate: echoCanceller.sampleRate)) }
                append(resampler.flush())
                isFinished = true
                if let output, output.writer.status == .writing { output.input.markAsFinished() }
                done.resume()
            }
        }
        if let output, output.writer.status == .writing { await output.writer.finishWriting() }
        return systemSignalDetected
    }

    func recheckSystemAudioPermission() {
        controlQueue.async { [weak self] in self?.probeSystemAudioPermission() }
    }

    // MARK: Devices (controlQueue)

    private func startAggregate(includeMicrophone: Bool) throws {
        guard let tap else { throw CaptureError("系统声音采集尚未初始化。") }
        let micID = includeMicrophone ? Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice) : nil
        guard let clockID = micID ?? Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice),
              let clockUID = Self.string(of: clockID, kAudioDevicePropertyDeviceUID)
        else { throw CaptureError("没有可用的音频设备。") }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Tape",
            kAudioAggregateDeviceUIDKey: "dev.gustaf.tape.aggregate.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // With auto-start, macOS 27 runs the device (mic included) only while something is already playing.
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: clockUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: clockUID, kAudioSubDeviceDriftCompensationKey: true]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tap.description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let created = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate)
        guard created == noErr else { throw CaptureError("无法创建双路音频设备。", status: created) }
        aggregateID = aggregate

        guard let rate = Self.sampleRate(of: aggregate) else { throw CaptureError("无法读取音频设备的采样率。") }
        deviceRate.store(rate.bitPattern, ordering: .relaxed)

        // Sub-device streams come first in the aggregate (FullSubDeviceList order), then the tap's.
        let tapIndex = Self.inputStreamCount(of: clockID)
        let streamCount = Self.inputStreamCount(of: aggregate)
        guard streamCount > tapIndex else { throw CaptureError("当前音频设备未提供系统声音。") }

        if output != nil {
            for object in [aggregate, clockID] {
                let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.sampleRateChanged(on: object) }
                var address = Self.address(kAudioDevicePropertyNominalSampleRate)
                AudioObjectAddPropertyListenerBlock(object, &address, controlQueue, listener)
                rateListeners.append((object, listener))
            }
        }

        var proc: AudioDeviceIOProcID?
        let createdProc = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, nil) { [self] _, inputData, inputTime, _, _ in
            capture(inputData, at: inputTime.pointee, tapIndex: tapIndex)
        }
        guard createdProc == noErr, let proc else { throw CaptureError("无法读取录音设备。", status: createdProc) }
        procID = proc
        let started = AudioDeviceStart(aggregate, proc)
        guard started == noErr else { throw CaptureError("无法启动录音设备。", status: started) }
        onEvent(.microphone(micID.flatMap { Self.string(of: $0, kAudioObjectPropertyName) }))
    }

    private func stopAggregate() {
        for (object, listener) in rateListeners {
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(object, &address, controlQueue, listener)
        }
        rateListeners = []
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
    }

    private func listenForDefaultDevices() {
        let listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = [
            (kAudioHardwarePropertyDefaultInputDevice, { [weak self] _, _ in self?.requestRebuild() }),
        ]
        for (selector, listener) in listeners {
            var address = Self.address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
        }
        defaultDeviceListeners = listeners
    }

    private func sampleRateChanged(on device: AudioObjectID) {
        guard let rate = Self.sampleRate(of: device), rate != Double(bitPattern: deviceRate.load(ordering: .relaxed)) else { return }
        requestRebuild()
    }

    private func requestRebuild() {
        guard !isStopping else { return }
        rebuildRequest += 1
        let request = rebuildRequest
        controlQueue.async { [weak self] in self?.rebuild(request: request, attempt: 0) }
    }

    private func rebuild(request: Int, attempt: Int) {
        guard !isStopping, request == rebuildRequest else { return }
        stopAggregate()
        do {
            try startAggregate(includeMicrophone: attempt < Self.rebuildAttemptsWithMicrophone)
            return
        } catch {
            stopAggregate()
            if let error = error as? CaptureError, error.isPermissionDenied {
                reportSystemAudioDenial()
                return
            }
        }
        guard attempt < Self.rebuildAttemptsWithMicrophone else {
            onEvent(.deviceFailed)
            return
        }
        controlQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.rebuild(request: request, attempt: attempt + 1) }
    }

    private func scheduleProbe(after delay: TimeInterval, repeatWhileRecording: Bool) {
        controlQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !isStopping, !systemPermissionDenied else { return }
            probeSystemAudioPermission()
            if repeatWhileRecording { scheduleProbe(after: 30, repeatWhileRecording: true) }
        }
    }

    // Core Audio does not expose a permission preflight for taps. Treat an explicit
    // permission error as denial, but require actual captured audio to confirm access.
    private func probeSystemAudioPermission() {
        guard !isStopping, !systemPermissionDenied, !hasRecentSystemAudio, let tap else { return }
        var address = Self.address(kAudioTapPropertyDescription)
        let status = withUnsafePointer(to: tap.description) {
            AudioObjectSetPropertyData(tap.id, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), $0)
        }
        guard status == kAudioDevicePermissionsError else { return }
        reportSystemAudioDenial()
    }

    private func reportSystemAudioDenial() {
        guard !systemPermissionDenied else { return }
        deniedSystemAudio.store(true, ordering: .relaxed)
        onEvent(.systemAudioDenied)
    }

    // MARK: Realtime IOProc

    private func capture(_ data: UnsafePointer<AudioBufferList>, at time: AudioTimeStamp, tapIndex: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: data))
        if buffers.indices.contains(tapIndex), let raw = buffers[tapIndex].mData {
            let samples = UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: Int(buffers[tapIndex].mDataByteSize) / MemoryLayout<Float>.size)
            if samples.contains(where: { abs($0) > 0.0001 }) {
                lastSystemSignal.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)
            }
        }
        guard let ring else { return }
        guard let first = buffers.first(where: { $0.mData != nil && $0.mNumberChannels > 0 }) else { return }
        let available = Int(first.mDataByteSize) / MemoryLayout<Float>.size / Int(first.mNumberChannels)
        let hostSeconds = Double(AudioConvertHostTimeToNanos(time.mHostTime)) / 1e9
        let rate = Double(bitPattern: deviceRate.load(ordering: .relaxed))
        ring.write(hostSeconds: hostSeconds, sampleRate: rate) { slot in
            let frames = min(available, slot.count / 2)
            slot[0..<2 * frames].update(repeating: 0)
            let system = UnsafeMutableBufferPointer(rebasing: slot[0..<frames])
            let microphone = UnsafeMutableBufferPointer(rebasing: slot[frames..<2 * frames])
            for index in buffers.indices {
                let buffer = buffers[index]
                guard let raw = buffer.mData, buffer.mNumberChannels > 0 else { continue }
                let stream = InterleavedStream(
                    samples: UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size),
                    channels: Int(buffer.mNumberChannels)
                )
                Mixer.addLoudestChannel(of: stream, into: index < tapIndex ? microphone : system)
            }
            return 2 * frames
        }
    }

    // MARK: Writing (processingQueue)

    private func startDraining() {
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        drainTimer = timer
    }

    private func drain() {
        guard let ring else { return }
        while !isFinished, ring.read({ chunk, samples in consume(chunk, samples) }) {}
    }

    private func consume(_ chunk: AudioRingChunk, _ samples: UnsafeBufferPointer<Float>) {
        guard chunk.sampleRate > 0 else { return }
        let frames = samples.count / 2
        let microphone = samples[frames...]
        if !microphoneSignalDetected, microphone.contains(where: { abs($0) > 0.005 }) {
            heardMicrophone.store(true, ordering: .relaxed)
        }
        var gap = expectedHostSeconds.map { SilenceGap.frames(expectedSeconds: $0, actualSeconds: chunk.hostSeconds, sampleRate: chunk.sampleRate) } ?? 0
        while gap > 0 {
            let zeros = silence.prefix(gap)
            mix(system: zeros, microphone: zeros, rate: chunk.sampleRate)
            gap -= zeros.count
        }
        expectedHostSeconds = chunk.hostSeconds + Double(frames) / chunk.sampleRate
        mix(system: samples[0..<frames], microphone: microphone, rate: chunk.sampleRate)
    }

    private func mix<Plane: AccelerateBuffer & Sequence<Float>>(system: Plane, microphone: Plane, rate: Double) {
        guard let makeEchoCanceller else {
            append(resampler.convert(vDSP.add(system, microphone), rate: rate))
            return
        }
        if let echoCanceller, echoCanceller.sampleRate != rate {
            append(resampler.convert(echoCanceller.flush(), rate: echoCanceller.sampleRate))
            self.echoCanceller = nil
        }
        let canceller = echoCanceller ?? makeEchoCanceller(rate)
        echoCanceller = canceller
        append(resampler.convert(vDSP.add(system, canceller.process(microphone: microphone, reference: system)), rate: rate))
    }

    private func append(_ samples: [Float]) {
        guard let output, !samples.isEmpty else { return }
        guard output.writer.status == .writing else {
            failWriting()
            return
        }
        var samples = samples
        limiter.process(&samples)
        let byteCount = samples.count * MemoryLayout<Float>.size
        let timestamp = CMTime(value: framesWritten, timescale: CMTimeScale(Self.outputRate))
        framesWritten += Int64(samples.count)
        guard output.input.isReadyForMoreMediaData else { return }
        var block: CMBlockBuffer?
        var sample: CMSampleBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr,
              let block,
              samples.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }) == noErr,
              CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: outputFormat.formatDescription, sampleCount: samples.count, presentationTimeStamp: timestamp, packetDescriptions: nil, sampleBufferOut: &sample) == noErr,
              let sample
        else { return }
        if !output.input.append(sample) { failWriting() }
    }

    private func failWriting() {
        guard !isFinished else { return }
        isFinished = true
        onEvent(.writeFailed)
    }

    // MARK: Core Audio properties

    private static func makeTap() throws -> (id: AudioObjectID, description: CATapDescription) {
        var pid = getpid()
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let translated = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &processObject)
        guard translated == noErr else { throw CaptureError("无法找到 Tape 的音频进程。", status: translated) }
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: [processObject])
        description.name = "Tape"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tapID = AudioObjectID(kAudioObjectUnknown)
        let created = AudioHardwareCreateProcessTap(description, &tapID)
        guard created == noErr else { throw CaptureError("无法开始采集系统声音。", status: created) }
        return (tapID, description)
    }

    private static func sampleRate(of device: AudioObjectID) -> Double? {
        var rate = Float64(0)
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = address(kAudioDevicePropertyNominalSampleRate)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return status == noErr && rate > 0 ? rate : nil
    }

    private static func inputStreamCount(of device: AudioObjectID) -> Int {
        var size = UInt32(0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(selector)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }

    static func string(of object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = address(selector)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }
}

private final class Resampler {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var rate = 0.0

    init(outputFormat: AVAudioFormat) {
        self.outputFormat = outputFormat
    }

    func convert(_ samples: [Float], rate: Double) -> [Float] {
        let flushed = rate == self.rate ? [] : flush()
        if converter == nil {
            converter = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
                .flatMap { AVAudioConverter(from: $0, to: outputFormat) }
            self.rate = rate
        }
        guard !samples.isEmpty, let converter,
              let source = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(samples.count)),
              let destination = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(Double(samples.count) * outputFormat.sampleRate / rate) + 1024),
              let sourceChannel = source.floatChannelData?[0]
        else { return flushed }
        source.frameLength = AVAudioFrameCount(samples.count)
        sourceChannel.update(from: samples, count: samples.count)
        var supplied = false
        var error: NSError?
        converter.convert(to: destination, error: &error) { _, status in
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
        guard error == nil else { return flushed }
        return flushed + Self.samples(of: destination)
    }

    func flush() -> [Float] {
        defer {
            converter = nil
            rate = 0
        }
        guard let converter, let destination = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 8192) else { return [] }
        var error: NSError?
        converter.convert(to: destination, error: &error) { _, status in
            status.pointee = .endOfStream
            return nil
        }
        return error == nil ? Self.samples(of: destination) : []
    }

    private static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }
}
