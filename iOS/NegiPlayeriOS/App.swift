import SwiftUI

@main struct NegiPlayerMobileApp:App {
    @StateObject private var model=MobileModel()
    @AppStorage("appearance-theme") private var theme="negi"
    @AppStorage("appearance-language") private var language="zh-Hans"
    var body:some Scene {
        WindowGroup {
            MobileRoot(model:model,audio:model.audio)
                .preferredColorScheme((PlayerTheme(rawValue:theme) ?? .negi).scheme)
                .environment(\.locale,Locale(identifier:language)).tint(accent).id(theme+language)
                .task { if !model.connected { await model.restore() } }
        }
    }
}
