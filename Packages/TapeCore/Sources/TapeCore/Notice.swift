import Foundation

public enum PrivacyPane: Sendable {
    case microphone, systemAudio

    public var url: URL {
        let anchor = self == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum StopReason: Sendable, Equatable {
    case sleep
    case diskFull(volume: String)
    case volumeDisconnected(volume: String)
    case writeFailed
    case audioFailed
}

public enum Notice: Sendable, Equatable {
    case microphoneDenied
    case systemAudioDenied
    case recovered(name: String)
    case stopped(StopReason)
    case fellBack(folder: String)
    case noSystemAudio
    case notEnoughSpace(volume: String)
    case couldNotStart(message: String)

    public var text: String {
        switch self {
        case .microphoneDenied: "请在系统设置中允许访问麦克风。"
        case .systemAudioDenied: "请在系统设置中允许系统录音。"
        case .recovered(let name): "已找回录音“\(name)”。"
        case .stopped(.sleep): "Mac 进入睡眠，录音已停止。"
        case .stopped(.diskFull(let volume)): "“\(volume)”空间已满，录音已停止。"
        case .stopped(.volumeDisconnected(let volume)): "“\(volume)”连接已断开，录音已停止。"
        case .stopped(.writeFailed): "无法写入录音文件，录音已停止。"
        case .stopped(.audioFailed): "音频设备失去响应，录音已停止。"
        case .fellBack(let folder): "“\(folder)”不可用，录音已保存到“影片／Tape 中文版”。"
        case .noSystemAudio: "上一段录音未检测到系统声音。"
        case .notEnoughSpace(let volume): "“\(volume)”可用空间不足，无法开始录音。"
        case .couldNotStart(let message): "无法开始录音。\(message)"
        }
    }

    public var privacyPane: PrivacyPane? {
        if self == .microphoneDenied { return .microphone }
        if self == .systemAudioDenied || self == .noSystemAudio { return .systemAudio }
        return nil
    }
}
