import SwiftUI
import TapeCore

struct RecordingView: View {
    static let windowID = NSUserInterfaceItemIdentifier("recording")

    let recorder: Recorder

    var body: some View {
        VStack(spacing: 12) {
            Text(recorder.isSavingToFallback ? "正在录音，保存到默认文件夹" : "正在录音")
                .foregroundStyle(.secondary)
            Text(ElapsedTime.clock(recorder.elapsed))
                .font(.system(size: 32, weight: .medium).monospacedDigit())
                .accessibilityLabel("已录制 \(ElapsedTime.spoken(recorder.elapsed))")
            Button("停止录音") { Task { await recorder.stop() } }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!recorder.isRecording)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .frame(minWidth: 240)
        .onChange(of: recorder.isActive) { _, isActive in
            guard !isActive else { return }
            NSApp.windows.first { $0.identifier == Self.windowID }?.close()
        }
    }
}
