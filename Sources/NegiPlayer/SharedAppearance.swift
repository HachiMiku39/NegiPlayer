import SwiftUI

enum PlayerTheme:String,CaseIterable {
    case negi,day,night
    var name:String { switch self { case .negi:return "Negi"; case .day:return "日间"; case .night:return "夜间" } }
    var scheme:ColorScheme { self == .day ? .light : .dark }
    var accent:Color { switch self { case .negi:return Color(red:0.224,green:0.773,blue:0.733); case .day:return Color(red:0.08,green:0.37,blue:0.39); case .night:return Color(red:0.64,green:0.76,blue:0.8) } }
    var background:Color { switch self { case .negi:return Color(red:0.055,green:0.075,blue:0.085); case .day:return Color(red:0.955,green:0.96,blue:0.95); case .night:return Color(red:0.065,green:0.07,blue:0.09) } }
}
var activeTheme:PlayerTheme { PlayerTheme(rawValue:UserDefaults.standard.string(forKey:"appearance-theme") ?? "negi") ?? .negi }
var accent:Color { activeTheme.accent }
var pinkAccent:Color { activeTheme == .negi ? Color(red:0.91,green:0.35,blue:0.54) : activeTheme.accent.opacity(0.6) }
var surface:Color { activeTheme.background }
private enum PlayerStrings {
    static let values:[String:[String:String]] = {
        guard let url=Bundle.main.url(forResource:"PlayerStrings",withExtension:"json"), let data=try? Data(contentsOf:url), let value=try? JSONDecoder().decode([String:[String:String]].self,from:data) else { return [:] }; return value
    }()
    static let keys=values.keys.sorted{$0.count>$1.count}
}
func L(_ text:String) -> String {
    let language=UserDefaults.standard.string(forKey:"appearance-language") ?? "zh-Hans"
    if language == "zh-Hans" { return text }
    if let value=PlayerStrings.values[text]?[language] { return value }
    // Only complete, anchored status templates may interpolate values; never replace words inside unknown text.
    for key in PlayerStrings.keys where key.contains("%@") || key.contains("%d") {
        let placeholder="%(?:@|d|[+.0-9]*f)"
        guard let token=try? NSRegularExpression(pattern:placeholder) else { continue }
        let parts=token.matches(in:key,range:NSRange(key.startIndex...,in:key))
        guard !parts.isEmpty, let translated=PlayerStrings.values[key]?[language] else { continue }
        var pattern="^", start=key.startIndex
        for part in parts {
            guard let range=Range(part.range,in:key) else { continue }
            pattern+=NSRegularExpression.escapedPattern(for:String(key[start..<range.lowerBound]))+"(.+?)"; start=range.upperBound
        }
        pattern+=NSRegularExpression.escapedPattern(for:String(key[start...]))+"$"
        guard let regex=try? NSRegularExpression(pattern:pattern), let match=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)) else { continue }
        var output=translated
        let target=token.matches(in:translated,range:NSRange(translated.startIndex...,in:translated))
        guard target.count==parts.count else { continue }
        for i in target.indices.reversed() {
            guard let valueRange=Range(match.range(at:i+1),in:text), let replaceRange=Range(target[i].range,in:output) else { continue }
            output.replaceSubrange(replaceRange,with:String(text[valueRange]))
        }
        return output
    }
    return text
}
struct AppearanceControls:View {
    @AppStorage("appearance-theme") var theme="negi"
    @AppStorage("appearance-language") var language="zh-Hans"
    var body:some View {
        Picker(L("主题"),selection:$theme) { ForEach(PlayerTheme.allCases,id:\.rawValue) { Text(L($0.name)).tag($0.rawValue) } }
        Picker(L("语言"),selection:$language) { Text("中文").tag("zh-Hans"); Text("日本語").tag("ja"); Text("English").tag("en") }
    }
}

func LF(_ key:String,_ arguments:CVarArg...) -> String { String(format:L(key),locale:Locale(identifier:UserDefaults.standard.string(forKey:"appearance-language") ?? "zh-Hans"),arguments:arguments) }
