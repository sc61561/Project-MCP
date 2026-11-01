import SwiftUI
import AppKit
import AVKit
import ProjectMCPCore

struct SettingsView: View {
    @ObservedObject var app: AppController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDiagnostics = false
    @State private var showQuickStart = true
    @AppStorage("minimizeOnClose") private var minimizeOnClose = true
    @State private var draft = ConnectionSettings()
    @State private var draftKey = ""

    private var windowHeight: CGFloat {
        min(720, max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 64))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("设置").font(.system(size: 18, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 12) {
                        GridRow {
                            Text("API Key")
                            SecureField("", text: $draftKey).accessibilityLabel("API Key")
                        }
                        GridRow {
                            Text("Tunnel ID")
                            TextField("", text: $draft.tunnelID).accessibilityLabel("Tunnel ID")
                        }
                    }.textFieldStyle(.roundedBorder).disabled(app.isRunning)
                    DisclosureGroup("高级设置") {
                        HStack {
                            Text("组织 ID（可选）")
                            TextField("", text: $draft.organizationID).accessibilityLabel("组织 ID（可选）")
                                .textFieldStyle(.roundedBorder)
                        }.disabled(app.isRunning).padding(.top, 6)
                    }
                    Toggle("记住密钥", isOn: $draft.rememberKey)
                        .toggleStyle(.checkbox).disabled(app.isRunning)
                    Toggle("关闭窗口时最小化", isOn: $minimizeOnClose)
                        .toggleStyle(.checkbox)

                    DisclosureGroup("快速开始", isExpanded: $showQuickStart) {
                        VStack(alignment: .leading, spacing: 10) {
                            step("1", "获取连接信息") {
                                Text("创建 API Key 和 Tunnel，关联 ChatGPT 工作区。")
                                HStack(spacing: 14) {
                                    Link("获取 API Key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                                    Link("创建 Tunnel", destination: URL(string: "https://platform.openai.com/settings/organization/tunnels")!)
                                }
                            }
                            step("2", "配置并启动") {
                                Text("在上方填写 API Key 和 Tunnel ID，保存后选择项目文件夹并启动。")
                            }
                            step("3", "添加 ChatGPT 插件") {
                                Text("选择添加自定义 MCP 服务器，连接方式选择 Tunnel 和相同隧道，身份验证选择无身份验证，确认后创建并安装。")
                                Link("打开 ChatGPT 插件", destination: URL(string: "https://chatgpt.com/plugins")!)
                                if let url = Bundle.main.url(forResource: "chatgpt-plugin-guide", withExtension: "mp4") {
                                    TutorialVideo(url: url, reduceMotion: reduceMotion)
                                        .frame(width: 250, height: 192)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .accessibilityLabel("添加 ChatGPT 插件操作视频")
                                }
                                Text("视频使用示例隧道，请选择自己的隧道。在对话中输入 @ 选择插件，请它列出项目目录。‘本地就绪’仅表示本地服务就绪。")
                            }
                        }.padding(.top, 10)
                    }

                    if let error = app.errorMessage {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red).lineLimit(2)
                    }
                    DisclosureGroup("诊断", isExpanded: $showDiagnostics) {
                        ScrollView {
                            Text(app.logs.isEmpty ? "暂无日志" : app.logs)
                                .font(.system(size: 10, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(height: 120)
                        Button("复制诊断") { app.copyDiagnostics() }.controlSize(.small)
                    }
                }
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
            }
            HStack {
                Spacer()
                Button("保存") { app.saveSettings(candidate: draft, key: draftKey) }
                    .keyboardShortcut(.defaultAction).disabled(app.isRunning)
                Button("关闭") { app.showSettings = false }.keyboardShortcut(.cancelAction)
            }.font(.system(size: 12))
        }
        .padding(22).frame(width: 560, height: windowHeight)
        .onAppear { draft = app.settings; draftKey = app.apiKey }
    }

    private func step<Content: View>(_ number: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number).font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 22).background(.primary.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                content()
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TutorialVideo: NSViewRepresentable {
    let url: URL
    let reduceMotion: Bool

    final class Coordinator {
        let player = AVQueuePlayer()
        var looper: AVPlayerLooper?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        context.coordinator.player.isMuted = true
        context.coordinator.looper = AVPlayerLooper(player: context.coordinator.player, templateItem: AVPlayerItem(url: url))
        view.player = context.coordinator.player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if reduceMotion { context.coordinator.player.pause() }
        else { context.coordinator.player.play() }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) {
        coordinator.player.pause()
        coordinator.looper?.disableLooping()
        view.player = nil
    }
}
