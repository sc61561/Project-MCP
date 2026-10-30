import SwiftUI
import AppKit
import ProjectMCPCore

struct SettingsView: View {
    @ObservedObject var app: AppController
    @State private var showDiagnostics = false
    @State private var draft = ConnectionSettings()
    @State private var draftKey = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("连接设置").font(.system(size: 18, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 15, verticalSpacing: 15) {
                GridRow {
                    Text("API Key")
                    SecureField("", text: $draftKey).accessibilityLabel("API Key")
                }
                GridRow {
                    Text("Tunnel ID")
                    TextField("", text: $draft.tunnelID).accessibilityLabel("Tunnel ID")
                }
                GridRow {
                    Text("组织 ID")
                    TextField("", text: $draft.organizationID).accessibilityLabel("组织 ID")
                }
            }.textFieldStyle(.roundedBorder).disabled(app.isRunning)
            Toggle("记住密钥", isOn: $draft.rememberKey)
                .toggleStyle(.checkbox).disabled(app.isRunning)

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
            }.font(.system(size: 12))

            HStack(spacing: 15) {
                Link("ChatGPT", destination: URL(string: "https://chatgpt.com/plugins")!)
                Link("隧道", destination: URL(string: "https://platform.openai.com/settings/organization/tunnels")!)
                Button { app.openHelp() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.plain).help("帮助").accessibilityLabel("帮助")
                Spacer()
                Button("保存") { app.saveSettings(candidate: draft, key: draftKey) }.keyboardShortcut(.defaultAction)
                    .disabled(app.isRunning)
                Button("关闭") { app.showSettings = false }.keyboardShortcut(.cancelAction)
            }.font(.system(size: 12))
        }.padding(26).frame(width: 470)
        .onAppear { draft = app.settings; draftKey = app.apiKey }
    }
}
