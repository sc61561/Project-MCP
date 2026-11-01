import SwiftUI
import AppKit

struct MainView: View {
    @StateObject private var app = AppController.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// macOS 26+ controls opt into native Liquid Glass; earlier systems and the
    /// reduce-transparency setting keep the existing frosted styling.
    private var glassControls: Bool { !reduceTransparency && LiquidGlassSupport.isAvailable }

    var body: some View {
        VStack(spacing: 28) {
            HStack(alignment: .center) {
                Text("Project MCP").font(.system(size: 18, weight: .semibold))
                Spacer()
                Link(destination: URL(string: "https://github.com/sc61561/Project-MCP")!) {
                    if let url = Bundle.main.url(forResource: "github", withExtension: "svg"),
                       let icon = NSImage(contentsOf: url) {
                        Image(nsImage: icon).renderingMode(.template).resizable()
                            .scaledToFit().frame(width: 17, height: 17)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "link").frame(width: 28, height: 28)
                    }
                }
                .buttonStyle(.plain)
                .liquidGlassButton(available: glassControls, prominent: false)
                .help("GitHub 仓库").accessibilityLabel("GitHub 仓库")
                Button { app.showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 16))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .liquidGlassButton(available: glassControls, prominent: false)
                .help("设置").accessibilityLabel("设置")
            }
            .frame(height: 36)

            Button { app.chooseProject() } label: {
                HStack(spacing: 13) {
                    Image(systemName: "folder").font(.system(size: 23, weight: .light))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, alignment: .center)
                    Text(app.projectName).font(.system(size: 15, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        if !glassControls { RoundedRectangle(cornerRadius: 15).fill(.primary.opacity(0.035)) }
                    }
                    .overlay {
                        if !glassControls { RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.07)) }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 15))
            }
            .buttonStyle(.plain)
            .liquidGlass(available: glassControls, interactive: !reduceMotion, in: RoundedRectangle(cornerRadius: 15))
            .disabled(app.isRunning)
                .help(app.settings.projectPath.isEmpty ? "选择项目" : app.settings.projectPath)
                .accessibilityLabel(app.settings.projectPath.isEmpty ? "选择项目" : app.settings.projectPath)

            HStack(spacing: 7) {
                Circle().fill(app.isReady ? Color.green.opacity(0.8) : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(app.statusText).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if app.errorMessage != nil {
                    Button("设置") { app.showSettings = true }
                        .buttonStyle(.plain).font(.system(size: 12))
                }
            }

            Button {
                Task { await app.toggleConnection() }
            } label: {
                HStack(spacing: 8) {
                    if app.isBusy { ProgressView().controlSize(.small) }
                    Text(app.isRunning ? "停止" : "启动").font(.system(size: 14, weight: .semibold))
                }.frame(maxWidth: .infinity).frame(height: 44)
                    .background {
                        if !glassControls { RoundedRectangle(cornerRadius: 15).fill(.primary.opacity(0.1)) }
                    }
                    .overlay {
                        if !glassControls { RoundedRectangle(cornerRadius: 15).strokeBorder(.primary.opacity(0.07)) }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 15))
            }
            .buttonStyle(.plain)
            .liquidGlass(available: glassControls, interactive: !reduceMotion, in: RoundedRectangle(cornerRadius: 15))
            .disabled(app.isBusy)
            .keyboardShortcut(.return, modifiers: [])
        }
        .padding(28).padding(.top, 28).frame(width: 440)
        .hideHomeFocusEffect()
        .background {
            if reduceTransparency { Color(nsColor: .windowBackgroundColor).ignoresSafeArea() }
            else { GlassBackground().ignoresSafeArea() }
        }
        .background(WindowBehavior().frame(width: 0, height: 0))
        .sheet(isPresented: $app.showSettings) { SettingsView(app: app) }
        .onAppear { app.restore() }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: app.isRunning)
    }
}

private extension View {
    @ViewBuilder func hideHomeFocusEffect() -> some View {
        if #available(macOS 14, *) { self.focusEffectDisabled() }
        else { self }
    }
}

private struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
    }
}

@MainActor
final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    static let shared = WindowCloseDelegate()
    private let minimizeOnClose: () -> Bool

    init(minimizeOnClose: @escaping () -> Bool = {
        UserDefaults.standard.object(forKey: "minimizeOnClose") as? Bool ?? true
    }) {
        self.minimizeOnClose = minimizeOnClose
    }

    @objc func closeButtonPressed(_ button: NSButton) {
        guard let window = button.window else { return }
        if windowShouldClose(window) { window.close() }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if minimizeOnClose() {
            sender.miniaturize(nil)
            return false
        }
        guard AppController.shared.isRunning else { return true }
        let alert = NSAlert()
        alert.messageText = "停止连接并关闭？"
        alert.addButton(withTitle: "关闭")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        Task { @MainActor in
            await AppController.shared.stop()
            sender.close()
        }
        return false
    }
}

private struct WindowBehavior: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowBehaviorView { WindowBehaviorView() }
    func updateNSView(_ view: WindowBehaviorView, context: Context) { view.configureWindow() }
}

final class WindowBehaviorView: NSView {
    var closeHandler = WindowCloseDelegate.shared
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configureWindow() }
    func configureWindow() {
        guard let window else { return }
        // Windows created outside Interface Builder default to releasedWhenClosed,
        // which double-releases under ARC/SwiftUI ownership and crashes on close.
        window.isReleasedWhenClosed = false
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.delegate = closeHandler
        if let button = window.standardWindowButton(.closeButton) {
            button.target = closeHandler
            button.action = #selector(WindowCloseDelegate.closeButtonPressed(_:))
        }
    }
}
