import Testing
@testable import TapeCore

struct NoticeTests {
    @Test func permissionNoticesOfferThePrivacyPane() {
        #expect(Notice.microphoneDenied.privacyPane == .microphone)
        #expect(Notice.systemAudioDenied.privacyPane == .systemAudio)
        #expect(Notice.noSystemAudio.privacyPane == .systemAudio)
        #expect(Notice.stopped(.sleep).privacyPane == nil)
    }

    @Test func stopReasonsNameTheVolume() {
        #expect(Notice.stopped(.diskFull(volume: "Macintosh HD")).text == "“Macintosh HD”空间已满，录音已停止。")
        #expect(Notice.recovered(name: "Tape 2026-10-26 at 14.03.05").text == "已找回录音“Tape 2026-10-26 at 14.03.05”。")
    }

    @Test func privacyPaneURLs() {
        #expect(PrivacyPane.microphone.url.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        #expect(PrivacyPane.systemAudio.url.absoluteString.hasSuffix("Privacy_ScreenCapture"))
    }
}
