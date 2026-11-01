import AppKit
import SwiftUI

struct QuickStartView: View {
    @ObservedObject var app: AppController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("快速开始").font(.system(size: 20, weight: .semibold))
                Spacer()
                Button { app.showQuickStart = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭").accessibilityLabel("关闭快速开始")
            }
            .padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let tutorialURL = Bundle.main.url(forResource: "quick-start", withExtension: "gif") {
                        TutorialAnimation(url: tutorialURL, reduceMotion: reduceMotion)
                            .frame(width: 508, height: 286)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .accessibilityLabel("三步连接 Project MCP 的操作示意")
                    }

                    step("1", "获取连接信息") {
                        Text("创建并复制 API Key 和 Tunnel ID，将隧道关联到 ChatGPT 工作区。")
                        HStack {
                            Link("获取 API Key", destination: URL(string: "https://platform.openai.com/api-keys")!)
                            Link("创建 Tunnel", destination: URL(string: "https://platform.openai.com/settings/organization/tunnels")!)
                        }
                    }
                    step("2", "配置并启动") {
                        Text("在设置中填写两项，选择项目文件夹，然后启动。")
                        Button("打开设置") { app.openSettingsFromQuickStart() }
                    }
                    step("3", "添加 ChatGPT 插件") {
                        Text("在插件页选择 ＋ → 添加自定义 MCP 服务器 → Tunnel，选择相同隧道和无身份验证，确认后创建。")
                        Link("打开 ChatGPT 插件", destination: URL(string: "https://chatgpt.com/plugins")!)
                        Text("创建后安装插件，在对话中输入 @ 选择它，再请 ChatGPT 列出项目目录。‘本地就绪’仅表示本地服务就绪。")
                    }
                }
                .font(.system(size: 13))
                .textSelection(.enabled)
                .padding(.horizontal, 26).padding(.bottom, 26)
            }
        }
        .frame(width: 560, height: 650)
    }

    private func step<Content: View>(_ number: String, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.primary.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(size: 15, weight: .semibold))
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TutorialAnimation: NSViewRepresentable {
    var url: URL
    var reduceMotion: Bool

    func makeNSView(context: Context) -> TutorialImageView {
        let view = TutorialImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.image = NSImage(contentsOf: url)
        return view
    }

    func updateNSView(_ view: TutorialImageView, context: Context) {
        view.animates = !reduceMotion
    }
}

private final class TutorialImageView: NSImageView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }
}
