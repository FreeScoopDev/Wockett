// Watch-local SF Symbol names. WktSymbol lives in the iPhone app target, so
// the Watch keeps its own short list, like the widget's `WS`. Views use these
// names; no `systemName:` literals.
enum WS {
    static let iPhone = "iphone"
}
