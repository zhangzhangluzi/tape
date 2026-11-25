import SwiftUI

enum SettingsTab: String {
    case general, about
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let recorder: Recorder
    @AppStorage("settingsTab") private var tab = SettingsTab.general

    var body: some View {
        TabView(selection: $tab) {
            Tab("通用", systemImage: "gearshape", value: .general) {
                GeneralSettings(settings: settings, recorder: recorder)
            }
            Tab("关于", systemImage: "info.circle", value: .about) {
                AboutSettings()
            }
        }
        .frame(width: 480)
        .onAppear {
            #if DEBUG
            guard SettingsSnapshot.output == nil else { return }
            #endif
            // Without a Dock icon, macOS leaves the menu bar blank after a Space switch while Settings is key.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            #if DEBUG
            guard SettingsSnapshot.output == nil else { return }
            #endif
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
