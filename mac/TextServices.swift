// Right-click › Services › … in any app. macOS hands us the selected text
// directly (no ⌘C), and the Rewrite window opens with it, so Replace and Copy
// work just as they do from the shortcut. The menu items themselves are
// declared under NSServices in Info.plist (see build.sh).
import AppKit

@MainActor
final class TextServices: NSObject {
    /// NSApp.servicesProvider doesn't retain its object.
    static let shared = TextServices()

    @objc(rewrite:userData:error:)
    func rewrite(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(pb, error: error, action: nil)
    }

    @objc(fixGrammar:userData:error:)
    func fixGrammar(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(pb, error: error, action: .instruction(RewriteState.presets[0].instruction))
    }

    @objc(translate:userData:error:)
    func translate(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        open(pb, error: error, action: .translate(RewriteController.shared.state.translateTo))
    }

    private func open(
        _ pb: NSPasteboard, error: AutoreleasingUnsafeMutablePointer<NSString?>,
        action: RewriteController.Action?
    ) {
        guard let text = pb.string(forType: .string), !text.isEmpty else {
            error.pointee = "No text was selected." as NSString
            return
        }
        // Replace pastes back with ⌘V, which needs Accessibility; this asks
        // only if it isn't granted yet. Copy works either way.
        _ = Keys.requestTrust()
        RewriteController.shared.open(
            selection: text, from: NSWorkspace.shared.frontmostApplication, action: action)
    }
}
