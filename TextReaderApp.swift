import SwiftUI
import AVFoundation

@main
struct TextReaderApp: App {
    @StateObject private var store = DocumentStore()
    @StateObject private var player = TTSPlayer()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                DocumentListView()
                    .task { configureAudioSession() }
                PlayerBar()
            }
            .environmentObject(store)
            .environmentObject(player)
            .environmentObject(settings)
        }
    }

    /// 配置后台音频会话，使锁屏/后台仍可朗读。
    func configureAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession 配置失败: \(error)")
        }
    }
}
