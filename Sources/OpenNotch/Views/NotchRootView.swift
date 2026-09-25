import SwiftUI

private struct ExpandedSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    /// Sibling views that don't measure anything report `.zero`; they must not overwrite the real size.
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

/// One black shape that morphs between the notch (plus optional "ears") and the expanded panel.
struct NotchRootView: View {
    let model: NotchViewModel

    var body: some View {
        let expanded = model.isExpanded
        let topRadius = expanded ? Layout.expandedTopRadius : Layout.collapsedTopRadius
        let bottomRadius = expanded ? Layout.expandedBottomRadius : Layout.collapsedBottomRadius
        let body = model.bodySize
        let shape = NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Always laid out so its size is known before the first open — the shape can then
                // animate straight to the right height.
                ExpandedView(model: model)
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: ExpandedSizeKey.self, value: proxy.size)
                    })
                    .opacity(expanded ? 1 : 0)
                    .scaleEffect(expanded ? 1 : 0.94, anchor: .top)
                    .blur(radius: expanded ? 0 : 6)
                    .allowsHitTesting(expanded)
                    .animation(expanded ? .easeOut(duration: 0.24).delay(0.05) : .easeIn(duration: 0.1), value: expanded)

                CollapsedView(model: model)
                    .opacity(expanded ? 0 : 1)
                    .allowsHitTesting(!expanded)
                    .animation(.easeInOut(duration: 0.14), value: expanded)
            }
            .frame(width: body.width, height: body.height, alignment: .top)
            .padding(.horizontal, topRadius)
            .background(shape.fill(Color.black))
            .clipShape(shape)
            .shadow(color: .black.opacity(expanded ? 0.55 : 0), radius: 18, y: 8)
            .onPreferenceChange(ExpandedSizeKey.self) { size in
                model.measuredExpandedSize = size
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}
