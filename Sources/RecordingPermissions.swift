import AVFoundation
import Foundation

enum MicrophonePermission {
    case authorized, notDetermined, denied, restricted, unknown

    static var current: Self {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .unknown
        }
    }

    var text: String {
        switch self {
        case .authorized: "已授权"
        case .notDetermined: "等待授权"
        case .denied: "权限已关闭"
        case .restricted: "受系统限制"
        case .unknown: "待确认"
        }
    }
}

enum SystemAudioStatus {
    case unchecked, checking, waitingForSignal, detected, denied, noSignal
    case failed(String)

    var text: String {
        switch self {
        case .unchecked: "待验证"
        case .checking: "正在验证…"
        case .waitingForSignal: "等待系统播放声"
        case .detected: "已通过声音验证"
        case .denied: "权限受限"
        case .noSignal: "未收到系统声音"
        case .failed: "检测失败"
        }
    }
}

@MainActor
enum SystemAudioPermissionCheck {
    static func run() async -> SystemAudioStatus {
        do {
            // This capture has no output file and ignores microphone buffers.
            let capture = try CaptureSession(url: nil, makeEchoCanceller: nil) { _ in }
            let result: SystemAudioStatus
            do {
                try await capture.start()
                result = try await verifySignal(capture)
            } catch let error as CaptureError where error.isPermissionDenied {
                result = .denied
            } catch {
                result = .failed(error.localizedDescription)
            }
            _ = await capture.finish()
            return capture.systemPermissionDenied ? .denied : result
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func verifySignal(_ capture: CaptureSession) async throws -> SystemAudioStatus {
        let tone = URL.temporaryDirectory.appending(path: "tape-permission-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tone) }
        try writeTestTone(to: tone)

        // Tape excludes its own playback. afplay supplies a separate local audio stream.
        let player = Process()
        player.executableURL = URL(filePath: "/usr/bin/afplay")
        player.arguments = [tone.path]
        player.standardError = FileHandle.nullDevice
        try player.run()
        defer { if player.isRunning { player.terminate() } }

        let deadline = ContinuousClock.now + .seconds(7)
        while ContinuousClock.now < deadline {
            if capture.systemPermissionDenied { return .denied }
            if capture.systemSignalDetected { return .detected }
            if !player.isRunning, player.terminationStatus != 0 {
                return .failed("无法播放系统录音测试音。")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return .noSignal
    }

    private static func writeTestTone(to url: URL) throws {
        let sampleRate = 48000.0
        let count = AVAudioFrameCount(sampleRate * 5)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count),
              let samples = buffer.floatChannelData?[0]
        else { throw CaptureError("无法生成系统录音测试音。") }
        buffer.frameLength = count
        for index in 0..<Int(count) {
            let time = Double(index) / sampleRate
            // A brief pulse each two seconds gives macOS time to show its permission prompt.
            let pulse = time.truncatingRemainder(dividingBy: 2)
            let envelope = max(0, min(1, pulse * 50, (0.28 - pulse) * 50))
            samples[index] = Float(0.025 * envelope * sin(2 * .pi * 740 * time))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
