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
    }
}
