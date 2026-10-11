import SwiftUI
import AppKit
import LibraryDomain

struct ArtworkView: View {
    @ObservedObject var model: AppModel
    let media: MediaFile?
    var cornerRadius: CGFloat = 12
    @State private var artwork: NSImage?
    @State private var source = "没有可用封面"
    private var key: String { media.map { model.artworkKey(for:$0) } ?? "empty" }
    var body: some View {
        ZStack {
            LinearGradient(colors:[Color.primary.opacity(0.09),accent.opacity(0.12)],startPoint:.topLeading,endPoint:.bottomTrailing)
            if let artwork {
                Image(nsImage:artwork).resizable().scaledToFit()
            } else {
                GeometryReader { geometry in
                    Image(systemName:"opticaldisc").resizable().scaledToFit()
                        .padding(min(geometry.size.width,geometry.size.height)*0.28).foregroundStyle(Color.primary.opacity(0.3))
                }
            }
        }
        .aspectRatio(1,contentMode:.fit)
        .clipShape(RoundedRectangle(cornerRadius:cornerRadius))
        .overlay { RoundedRectangle(cornerRadius:cornerRadius).strokeBorder(Color.primary.opacity(0.08),lineWidth:1) }
        .help(L(source))
        .accessibilityLabel(L(artwork == nil ? "封面占位图" : "专辑封面"))
        .task(id:key) {
            artwork = nil; source = "没有可用封面"
            guard let media else { return }
            let result = await model.artwork(for:media)
            guard !Task.isCancelled else { return }
            artwork = result.flatMap { NSImage(data:$0.data) }; source = result?.source ?? source
        }
    }
}
