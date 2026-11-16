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
            if shouldShowFullControls {
                fullControls
            } else {
                // 进入了「非当前朗读」的书：只给一个「播放本书」入口，
                // 避免底部控制条显示成「在播这本书」而实际在播另一本，造成混淆。
                HStack(spacing: 14) {
                    Button {
                        player.requestStartPlayback(from: nil)
                    } label: {
                        Label("播放本书", systemImage: "play.fill")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .padding(.horizontal)
            }
        }
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    /// 是否显示完整播放控制（回退/播放·停止/前进/语速/分声/目录）：
    /// - 主界面（没有阅读页在显示）→ 始终显示，可继续/停止当前朗读的那本书；
    /// - 正在阅读某本书 → 仅当这本书就是当前在朗读的书时显示完整控制，
    ///   否则只显示「播放本书」（见 body 的 else 分支）。
    private var shouldShowFullControls: Bool {
        guard let reading = player.readingViewBookId else { return true }
        guard let active = player.currentDocumentId else { return false }
        return reading == active
    }

    private var fullControls: some View {
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

    private var labelText: String {
        if player.isPlaying { return "停止" }
        return player.isLoaded ? "继续" : "播放"
    }
    private var labelImage: String {
        player.isPlaying ? "stop.fill" : "play.fill"
    }

    // MARK: 速度控制（精度 0.25，点击数值一键回到 1.0×）

    private var speedControl: some View {
        HStack(spacing: 4) {
            Button { adjustRate(-0.25) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("语速 -0.25")
            Button { player.rate = 1.0 } label: {
                Text(String(format: "%.2f×", player.rate))
                    .frame(minWidth: 52, alignment: .center)
            }
            .buttonStyle(.borderless)
            .font(.callout.monospacedDigit())
            .help("点击回到 1.0×")
            Button { adjustRate(0.25) } label: { Image(systemName: "plus.circle") }
                .buttonStyle(.borderless)
                .help("语速 +0.25")
        }
    }

    private func adjustRate(_ delta: Float) {
        // 以 0.25 为一档，吸附到档位上，避免浮点累积出 1.06 之类的值
        let stepped = ((player.rate + delta) / 0.25).rounded() * 0.25
        player.rate = min(max(stepped, 0.5), 3.0)
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
