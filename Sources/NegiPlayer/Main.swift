import SwiftUI
import AppKit

@main struct NegiPlayerApp: App {
    @StateObject private var model = AppModel()
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("NegiPlayer") {
            ContentView(model: model, playback: model.playback)
                .frame(minWidth: 1040, minHeight: 700)
                .preferredColorScheme(.dark)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
                .task { _ = await NativeVerification.runIfRequested() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .appSettings) { Button("聆听设置…") { model.page = "output" }.keyboardShortcut(",") }
            CommandGroup(after: .newItem) { Button("导入音乐文件夹…") { model.importFolder() }.keyboardShortcut("o") }
            CommandMenu("播放") {
                Button("展开正在播放") { model.page = "playing" }.keyboardShortcut("p",modifiers:[.command,.shift])
                Button("播放／暂停") { model.toggle() }.keyboardShortcut(" ",modifiers:.command)
                Button("上一首") { model.playback.previous() }.keyboardShortcut(.leftArrow,modifiers:[.command,.option])
                Button("下一首") { model.playback.advance() }.keyboardShortcut(.rightArrow,modifiers:[.command,.option])
                Button("静音／取消静音") { model.playback.isMuted.toggle() }.keyboardShortcut("m",modifiers:[.command,.shift])
            }
            #if DEBUG
            CommandMenu("开发验证") {
                Button("运行原生编解码与 DSP 验证") {
                    model.notice = "正在运行原生验证…"
                    Task {
                        model.notice = await NativeVerification.runIfRequested { message in
                            await MainActor.run { model.notice = message }
                        }
                    }
                }
            }
            #endif
            CommandGroup(replacing: .undoRedo) {
                Button("撤销歌词修改") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo)
                Button("重做歌词修改") { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
            }
        }
    }
}
