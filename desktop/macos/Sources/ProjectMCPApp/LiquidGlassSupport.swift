import SwiftUI

enum LiquidGlassSupport {
    /// True only on macOS 26+ builds; callers combine this with the
    /// accessibility "reduce transparency" setting before applying glass.
    static var isAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

extension View {
    /// Applies the native Liquid Glass material when the OS and accessibility
    /// settings allow it; otherwise leaves the existing macOS 15 styling intact.
    @ViewBuilder
    func liquidGlass<S: Shape>(available: Bool, interactive: Bool, in shape: S) -> some View {
        if #available(macOS 26.0, *), available {
            self.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            self
        }
    }

    /// Uses the native glass button styles on macOS 26+ and the existing plain
    /// style on earlier systems. The primary action keeps its explicit frame.
    @ViewBuilder
    func liquidGlassButton(available: Bool, prominent: Bool) -> some View {
        if #available(macOS 26.0, *), available {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            self
        }
    }
}
