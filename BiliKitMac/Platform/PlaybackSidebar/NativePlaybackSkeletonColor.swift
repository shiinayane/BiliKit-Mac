import AppKit

enum NativePlaybackSkeletonColor {
    static var detailFill: NSColor {
        // Xcode 27 changes the Swift name imported for the same AppKit color.
        #if compiler(>=6.4)
            NSColor.quinaryLabelColor
        #else
            NSColor.quinaryLabel
        #endif
    }
}
