import SwiftUI

struct AboutSettings: View {
    var body: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Tape 中文版")
                .font(.title.bold())
            Text("版本 \(version)（\(build)）")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("把电脑播放声和麦克风声音保存为本机 M4A 录音。")
                .padding(.top, 8)
            Text("在会议软件里静音时，Tape 仍会录制本机麦克风。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Link("Tape 原项目 · Gustaf Eriksson · MIT", destination: URL(string: "https://github.com/gustaferiksson/tape")!)
                .font(.callout)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
        .frame(height: 280)
    }
}
