import ServiceManagement
import SwiftUI
import TapeCore

struct GeneralSettings: View {
    @Bindable var settings: AppSettings
    let recorder: Recorder
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var folderError: String?

    var body: some View {
        Form {
            Section("录音") {
                HStack {
                    Button(recorder.actionTitle, action: toggleRecording)
                        .buttonStyle(.borderedProminent)
                        .disabled(!recorder.canToggleRecording)
                    if recorder.startedAt != nil {
                        Text(ElapsedTime.clock(recorder.elapsed)).monospacedDigit()
                    }
                    Spacer()
                }
                if recorder.startedAt != nil || recorder.systemSignalDetected || recorder.microphoneSignalDetected {
                    LabeledContent("系统声音", value: recorder.systemSignalDetected ? "本次已检测到" : "等待声音")
                    LabeledContent("麦克风声音", value: microphoneStatus)
                }
                if let notice = recorder.notice {
                    Text(notice.text)
                        .font(.callout)
                        .foregroundStyle(.orange)
                    if let pane = notice.privacyPane {
                        Button("打开隐私设置…") { NSWorkspace.shared.open(pane.url) }
                    }
                }
                if recorder.phase == .idle, let recording = recorder.lastRecording {
                    Button("打开最近录音") { NSWorkspace.shared.open(recording) }
                }
            }

            Section {
                LabeledContent("麦克风权限", value: recorder.microphonePermission.text)
                LabeledContent("系统录音", value: recorder.systemAudioStatus.text)
                if case .failed(let message) = recorder.systemAudioStatus {
                    Text(message).font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Button(recorder.isCheckingPermissions ? "检测中…" : "检测权限") {
                        Task { await recorder.checkPermissions() }
                    }
                    .disabled(recorder.phase != .idle || recorder.isCheckingPermissions)
                    Spacer()
                    Button("麦克风设置") { NSWorkspace.shared.open(PrivacyPane.microphone.url) }
                    Button("系统录音设置") { NSWorkspace.shared.open(PrivacyPane.systemAudio.url) }
                }
            } header: {
                Text("录音权限")
            } footer: {
                Text("检测会播放短测试音。未收到声音时，系统录音仍待验证。")
            }

            Section {
                LabeledContent("保存到") {
                    Menu {
                        Button("选取文件夹…", action: chooseFolder)
                        Button("在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([settings.saveFolder])
                        }
                        if settings.customFolder != nil {
                            Divider()
                            Button("使用默认文件夹") {
                                settings.customFolder = nil
                                folderError = nil
                            }
                        }
                    } label: {
                        Label("\(settings.saveFolder.lastPathComponent) (\(settings.saveFolder.deletingLastPathComponent().lastPathComponent))", systemImage: "folder")
                    }
                    .fixedSize()
                }
                if let folderError {
                    Text(folderError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("录音文件")
            } footer: {
                Text("从下一次录音起生效。")
            }

            Section {
                Toggle(isOn: $settings.reducesEcho) {
                    Text("减少回声")
                    Text("使用扬声器时减少被麦克风收进去的对方声音。实验功能。")
                }
            } header: {
                Text("麦克风")
            } footer: {
                Text("从下一次录音起生效。")
            }

            Section {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLaunchAtLogin
                ))
                if loginStatus == .requiresApproval {
                    LabeledContent {
                        Button("打开登录项设置…") { SMAppService.openSystemSettingsLoginItems() }
                    } label: {
                        Text("需要确认")
                        Text("请在系统设置中允许 Tape 中文版随登录启动。")
                    }
                }
                if let loginError {
                    Text(loginError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("版本") {
                LabeledContent("Tape 中文版", value: AppUpdater.currentVersion)
            }
        }
        .formStyle(.grouped)
        .frame(height: 560)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    private var microphoneStatus: String {
        if recorder.startedAt != nil, recorder.microphoneName == nil { return "当前不可用" }
        let status = recorder.microphoneSignalDetected ? "本次已检测到" : "等待声音"
        if let name = recorder.microphoneName { return "\(status) · \(name)" }
        return status
    }

    private func toggleRecording() {
        Task {
            if recorder.isRecording { await recorder.stop() }
            else { await recorder.start() }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.saveFolder
        panel.prompt = "选取"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let probe = folder.appending(path: ".tape-write-test-\(UUID().uuidString)")
        guard (try? Data().write(to: probe)) != nil else {
            folderError = "无法写入“\(folder.lastPathComponent)”。请选择其他文件夹。"
            return
        }
        try? FileManager.default.removeItem(at: probe)
        folderError = nil
        settings.customFolder = folder == AppSettings.defaultFolder ? nil : folder
    }

    private func setLaunchAtLogin(_ isOn: Bool) {
        do {
            if isOn { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "无法更改登录时自动启动。\(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}
