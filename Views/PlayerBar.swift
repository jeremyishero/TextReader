import SwiftUI
import AVFoundation

/// 全局顶部播放控制条：回退 5 秒 / 播放·停止·继续 / 前进 5 秒 / 语速（±0.5，点数值回 1.0×）/ 角色分声 / 目录。
/// 由 TextReaderApp 在根视图底部统一放置，因此在「我的文档」「阅读页」等所有界面常驻显示；
/// 进入后台 / 锁屏后，通过 TTSPlayer 注册的 MPRemoteCommandCenter 在控制中心 / 锁屏显示「正在播放」卡片。
struct PlayerBar: View {
    @EnvironmentObject var player: TTSPlayer
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button(action: { player.seek(by: -5) }) {
                    Image(systemName: "gobackward.5")
                }
                .help("回退 5 秒")
                .buttonStyle(.bordered)

                Button(action: toggleMainPlay) {
                    Label(labelText, systemImage: labelImage)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)

                Button(action: { player.seek(by: 5) }) {
                    Image(systemName: "goforward.5")
                }
                .help("前进 5 秒")
                .buttonStyle(.bordered)

                speedControl

                Spacer()

                Toggle("分声", isOn: $player.useAnalyzedPlayback)
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .disabled(player.activeTitle == nil)

                Button(action: { player.openTOCHandler?() }) {
                    Image(systemName: "list.bullet")
                }
                .buttonStyle(.bordered)
                .disabled(player.openTOCHandler == nil)
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private var labelText: String {
        if player.isPlaying { return "停止" }
        return player.isLoaded ? "继续" : "播放"
    }
    private var labelImage: String {
        player.isPlaying ? "stop.fill" : "play.fill"
    }

    // MARK: 速度控制（精度 0.5，点击数值一键回到 1.0×）

    private var speedControl: some View {
        HStack(spacing: 4) {
            Button { adjustRate(-0.5) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("语速 -0.5")
            Button { player.rate = 1.0 } label: {
                Text(String(format: "%.1f×", player.rate))
                    .frame(minWidth: 44, alignment: .center)
            }
            .buttonStyle(.borderless)
            .font(.callout.monospacedDigit())
            .help("点击回到 1.0×")
            Button { adjustRate(0.5) } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
                .help("语速 +0.5")
        }
    }

    private func adjustRate(_ delta: Float) {
        player.rate = min(max(player.rate + delta, 0.5), 3.0)
    }

    // MARK: 主播放按钮：播放 / 继续 / 停止

    private func toggleMainPlay() {
        if player.isPlaying {
            player.stop()
        } else if player.isLoaded {
            player.resume()
        } else {
            player.requestStartPlayback(from: nil)
        }
    }
}
