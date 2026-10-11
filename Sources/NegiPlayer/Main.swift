import SwiftUI
import AppKit

@main struct NegiPlayerApp: App {
    @StateObject private var model = AppModel()
    @AppStorage("appearance-theme") private var theme="negi"
    @AppStorage("appearance-language") private var language="zh-Hans"
    init() { NSApplication.shared.setActivationPolicy(.regular) }
    var body: some Scene {
        WindowGroup("NegiPlayer") {
            ContentView(model: model, playback: model.playback)
                .frame(minWidth: 1040, minHeight: 700)
                .preferredColorScheme((PlayerTheme(rawValue:theme) ?? .negi).scheme)
                .environment(\.locale,Locale(identifier:language))
                .id(theme+language)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
                .task { await NativeVerification.runOnceIfRequested() }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .appSettings) { Button(L("聆听设置…")) { model.page = "output" }.keyboardShortcut(",") }
            CommandMenu(L("外观与语言")) { Button(L("外观与语言…")) { model.page="appearance" } }
            CommandGroup(after: .newItem) { Button(L("导入音乐文件夹…")) { model.importFolder() }.keyboardShortcut("o") }
            CommandMenu(L("播放")) {
                Button(L("展开正在播放")) { model.page = "playing" }.keyboardShortcut("p",modifiers:[.command,.shift])
                Button(L("播放／暂停")) { model.toggle() }.keyboardShortcut(" ",modifiers:.command)
                Button(L("上一首")) { model.playback.previous() }.keyboardShortcut(.leftArrow,modifiers:[.command,.option])
                Button(L("下一首")) { model.playback.advance() }.keyboardShortcut(.rightArrow,modifiers:[.command,.option])
                Button(L("静音／取消静音")) { model.playback.isMuted.toggle() }.keyboardShortcut("m",modifiers:[.command,.shift])
            }
            #if DEBUG
            CommandMenu(L("开发验证")) {
                Button(L("运行原生编解码与 DSP 验证")) {
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
                Button(L("撤销歌词修改")) { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo)
                Button(L("重做歌词修改")) { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canRedo)
            }
        }
    }
}
