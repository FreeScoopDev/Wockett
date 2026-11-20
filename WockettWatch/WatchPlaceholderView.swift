import SwiftUI

/// The Watch app's only screen until the walk remote lands: the Wockett mark
/// and where to start a walk.
struct WatchPlaceholderView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                WockettMarkView()
                    .frame(width: 64, height: 64)
                    .padding(10)
                    .background(Color.brandForest, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityHidden(true)
                Label {
                    Text("Start a walk on your iPhone.")
                        .font(.wktBodyText)
                        .foregroundStyle(Color.earthCream)
                } icon: {
                    Image(systemName: WS.iPhone)
                        .foregroundStyle(Color.earthGreen)
                }
                .labelStyle(.titleAndIcon)
                .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Color.earthBg)
    }
}

#Preview {
    WatchPlaceholderView()
}
