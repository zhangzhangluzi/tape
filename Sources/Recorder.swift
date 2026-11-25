import AVFoundation
import AppKit
import SwiftUI
import TapeCore

@MainActor @Observable
final class Recorder {
    enum Phase: Equatable {
        case idle
        case starting
        case recording(since: Date)
        case stopping(since: Date)
    }

    private static let minimumFreeBytesToStart: Int64 = 500_000_000
    private static let minimumFreeBytesWhileRecording: Int64 = 200_000_000
    private static let minimumAudioFileBytes = 4096

    private(set) var phase = Phase.idle
    private(set) var elapsed = 0
    private(set) var notice: Notice?
    private(set) var microphoneName: String?
    private(set) var systemSignalDetected = false
    private(set) var microphoneSignalDetected = false
    private(set) var microphonePermission = MicrophonePermission.current
    private(set) var systemAudioStatus = SystemAudioStatus.unchecked
    private(set) var isCheckingPermissions = false
    private(set) var isSavingToFallback = false
    private(set) var lastRecording: URL? {
        didSet { settings.store.set(lastRecording?.path, forKey: "lastRecording") }
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var session: CaptureSession?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var lastDiskCheck = Date.distantPast
    @ObservationIgnored private var recordingURL: URL?
    @ObservationIgnored private var recordingVolume = ""
    @ObservationIgnored private var fallbackFrom: String?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var activity: NSObjectProtocol?

    var isActive: Bool {
        if case .recording = phase { return true }
        if case .stopping = phase { return true }
        return false
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var actionTitle: String {
        if isCheckingPermissions { return "正在检测权限…" }
        return switch phase {
        case .idle: "开始录音"
        case .starting: "正在准备…"
        case .recording: "停止录音"
        case .stopping: "正在保存…"
        }
    }

    var canToggleRecording: Bool {
        !isCheckingPermissions && (phase == .idle || isRecording)
    }

    var startedAt: Date? {
        if case .recording(let since) = phase { return since }
        if case .stopping(let since) = phase { return since }
        return nil
    }

    init(settings: AppSettings) {
        self.settings = settings
        lastRecording = settings.store.string(forKey: "lastRecording").map { URL(filePath: $0) }
    }

    func start() async {
        guard phase == .idle, !isCheckingPermissions else { return }
        phase = .starting
        systemAudioStatus = .unchecked
        systemSignalDetected = false
        microphoneSignalDetected = false
        if !(await authorizeMicrophoneIfNeeded()) {
            notice = .microphoneDenied
            phase = .idle
            return
        }

        let folder = writableFolder()
        guard let space = Self.freeSpace(at: folder), space.bytes >= Self.minimumFreeBytesToStart else {
            notice = .notEnoughSpace(volume: Self.freeSpace(at: folder)?.volume ?? folder.lastPathComponent)
            phase = .idle
            return
        }
        let url = RecordingFile.url(in: folder, startedAt: .now, fileExtension: "m4a") { FileManager.default.fileExists(atPath: $0.path) }
        settings.store.set(["path": url.path, "pid": Int(getpid())], forKey: "inProgressRecording")
        let id = UUID()
        sessionID = id
        let session: CaptureSession
        var pendingSession: CaptureSession?
        systemAudioStatus = .waitingForSignal
        do {
            let candidate = try CaptureSession(url: url, makeEchoCanceller: settings.reducesEcho ? EchoCanceller.init : nil) { [weak self] event in
                Task { @MainActor in self?.handle(event, from: id) }
            }
            pendingSession = candidate
            try await candidate.start()
            session = candidate
        } catch {
            sessionID = nil
            _ = await pendingSession?.finish()
            try? FileManager.default.removeItem(at: url)
            settings.store.removeObject(forKey: "inProgressRecording")
            refreshPermissions()
            if microphonePermission != .authorized {
                notice = .microphoneDenied
                systemAudioStatus = .unchecked
            } else if (error as? CaptureError)?.isPermissionDenied == true {
                notice = .systemAudioDenied
                systemAudioStatus = .denied
            } else {
                notice = .couldNotStart(message: error.localizedDescription)
                systemAudioStatus = .unchecked
            }
            phase = .idle
            return
        }

        self.session = session
        recordingURL = url
        recordingVolume = space.volume
        notice = nil
        elapsed = 0
        let since = Date.now
        phase = .recording(since: since)
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "正在录音")
        lastDiskCheck = .now
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick(since: since) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        AccessibilityNotification.Announcement("已开始录音").post()
    }

    func stop(reason: StopReason? = nil) async {
        guard case .recording(let since) = phase, let session, let url = recordingURL else { return }
        phase = .stopping(since: since)
        timer?.invalidate()
        let hadSystemAudio = await session.finish()
        systemSignalDetected = hadSystemAudio
        microphoneSignalDetected = session.microphoneSignalDetected
        if session.systemPermissionDenied { systemAudioStatus = .denied }
        else { systemAudioStatus = hadSystemAudio ? .detected : .noSignal }
        if ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < Self.minimumAudioFileBytes {
            try? FileManager.default.removeItem(at: url)
        } else {
            lastRecording = url
        }
        notice = reason.map(Notice.stopped)
            ?? fallbackFrom.map { Notice.fellBack(folder: $0) }
            ?? (!hadSystemAudio && elapsed >= 60 ? .noSystemAudio : nil)
        finishCleanup()
        if case .permissionLost? = reason {
            NSApp.requestUserAttention(.criticalRequest)
        }
        AccessibilityNotification.Announcement(reason.map { Notice.stopped($0).text } ?? "录音已结束").post()
    }

    func recoverInterruptedRecording() async {
        guard let marker = settings.store.dictionary(forKey: "inProgressRecording"), let path = marker["path"] as? String else { return }
        if let pid = marker["pid"] as? Int, pid != Int(getpid()),
           NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return
        }
        settings.store.removeObject(forKey: "inProgressRecording")
        let url = URL(filePath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        if ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) < Self.minimumAudioFileBytes {
            try? FileManager.default.removeItem(at: url)
            return
        }
        if let duration = try? await AVURLAsset(url: url).load(.duration), duration.seconds < 1 {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard phase == .idle else { return }
        lastRecording = url
        notice = .recovered(name: RecordingFile.displayName(of: url))
    }

    func checkPermissions() async {
        guard phase == .idle, !isCheckingPermissions else { return }
        isCheckingPermissions = true
        defer { isCheckingPermissions = false }
        _ = await authorizeMicrophoneIfNeeded()
        if microphonePermission == .authorized, notice == .microphoneDenied { notice = nil }
        systemAudioStatus = .checking
        systemAudioStatus = await SystemAudioPermissionCheck.run()
        refreshPermissions()
        if case .detected = systemAudioStatus, notice == .systemAudioDenied { notice = nil }
    }

    func refreshPermissions(recheckSystemAudio: Bool = false) {
        microphonePermission = .current
        if microphonePermission == .authorized, notice == .microphoneDenied { notice = nil }
        if isRecording, microphonePermission != .authorized {
            Task { await stop(reason: .permissionLost(.microphone)) }
        }
        guard recheckSystemAudio else { return }
        if let session, isRecording {
            session.recheckSystemAudioPermission()
        } else if phase == .idle, !isCheckingPermissions {
            systemAudioStatus = .unchecked
        }
    }

    private func authorizeMicrophoneIfNeeded() async -> Bool {
        microphonePermission = .current
        if microphonePermission == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            microphonePermission = .current
        }
        return microphonePermission == .authorized
    }

    #if DEBUG
    func simulate(since: Date?, microphone: String?, notice: Notice?) {
        phase = since.map { .recording(since: $0) } ?? .idle
        elapsed = since.map { Int(Date.now.timeIntervalSince($0)) } ?? 0
        microphoneName = microphone
        self.notice = notice
    }
    #endif

    private func handle(_ event: CaptureEvent, from id: UUID) {
        guard id == sessionID else { return }
        if case .microphone(let name) = event {
            microphoneName = name
            return
        }
        if event == .systemAudioDenied {
            systemAudioStatus = .denied
            let pane: PrivacyPane = MicrophonePermission.current == .authorized ? .systemAudio : .microphone
            Task { await stop(reason: .permissionLost(pane)) }
            return
        }
        Task { await stop(reason: event == .deviceFailed ? .audioFailed : failureReason()) }
    }

    private func finishCleanup() {
        settings.store.removeObject(forKey: "inProgressRecording")
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        timer = nil
        session = nil
        sessionID = nil
        recordingURL = nil
        fallbackFrom = nil
        isSavingToFallback = false
        microphoneName = nil
        phase = .idle
    }

    private func tick(since: Date) {
        guard case .recording = phase else { return }
        refreshPermissions()
        guard microphonePermission == .authorized else { return }
        elapsed = Int(Date.now.timeIntervalSince(since))
        if let session {
            systemSignalDetected = session.systemSignalDetected
            microphoneSignalDetected = session.microphoneSignalDetected
            if !session.systemPermissionDenied {
                systemAudioStatus = session.hasRecentSystemAudio ? .detected : .waitingForSignal
            }
        }
        guard Date.now.timeIntervalSince(lastDiskCheck) >= 30, let folder = recordingURL?.deletingLastPathComponent() else { return }
        lastDiskCheck = .now
        guard FileManager.default.fileExists(atPath: folder.path), let space = Self.freeSpace(at: folder) else {
            Task { await stop(reason: failureReason()) }
            return
        }
        guard space.bytes < Self.minimumFreeBytesWhileRecording else { return }
        Task { await stop(reason: .diskFull(volume: space.volume)) }
    }

    private func failureReason() -> StopReason {
        guard let folder = recordingURL?.deletingLastPathComponent(), FileManager.default.fileExists(atPath: folder.path) else {
            return .volumeDisconnected(volume: recordingVolume)
        }
        if let space = Self.freeSpace(at: folder), space.bytes < Self.minimumFreeBytesWhileRecording { return .diskFull(volume: space.volume) }
        return .writeFailed
    }

    private func writableFolder() -> URL {
        let fileManager = FileManager.default
        fallbackFrom = nil
        isSavingToFallback = false
        if let custom = settings.customFolder {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: custom.path, isDirectory: &isDirectory), isDirectory.boolValue, fileManager.isWritableFile(atPath: custom.path) {
                return custom
            }
            fallbackFrom = custom.lastPathComponent
            isSavingToFallback = true
        }
        try? fileManager.createDirectory(at: AppSettings.defaultFolder, withIntermediateDirectories: true)
        return AppSettings.defaultFolder
    }

    private static func freeSpace(at folder: URL) -> (bytes: Int64, volume: String)? {
        guard let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedNameKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return (bytes, values.volumeLocalizedName ?? folder.lastPathComponent)
    }
}
