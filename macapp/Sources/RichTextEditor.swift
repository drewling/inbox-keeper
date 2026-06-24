// RichTextEditor.swift — a native rich-text reply editor: an NSTextView wrapped for
// SwiftUI, with a controller the formatting toolbar drives (bold / italic / bulleted
// list / link). On send it serializes to HTML so the reply keeps its formatting,
// matching what the old web composer's contenteditable produced.

import SwiftUI
import AppKit

private enum InkNS {
    static let text   = NSColor(srgbRed: 0.227, green: 0.196, blue: 0.165, alpha: 1)
    static let accent = NSColor(srgbRed: 0.102, green: 0.451, blue: 0.910, alpha: 1)  // Google blue links
    static let font   = NSFont.systemFont(ofSize: 13)
}

@MainActor
final class RichTextController: ObservableObject {
    weak var textView: NSTextView?

    private var defaultAttrs: [NSAttributedString.Key: Any] {
        [.font: InkNS.font, .foregroundColor: InkNS.text]
    }

    /// Seed the editor from a freshly generated plain-text draft.
    func setPlainText(_ s: String) {
        guard let tv = textView else { return }
        tv.textStorage?.setAttributedString(NSAttributedString(string: s, attributes: defaultAttrs))
        tv.typingAttributes = defaultAttrs
        tv.setSelectedRange(NSRange(location: (s as NSString).length, length: 0))
    }

    func toggleBold() { toggleTrait(.boldFontMask) }
    func toggleItalic() { toggleTrait(.italicFontMask) }

    private func toggleTrait(_ trait: NSFontTraitMask) {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let fm = NSFontManager.shared
        let sel = tv.selectedRange()
        if sel.length == 0 {
            var f = (tv.typingAttributes[.font] as? NSFont) ?? InkNS.font
            let has = fm.traits(of: f).contains(trait)
            f = has ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait)
            tv.typingAttributes[.font] = f
            return
        }
        let firstFont = (ts.attribute(.font, at: sel.location, effectiveRange: nil) as? NSFont) ?? InkNS.font
        let has = fm.traits(of: firstFont).contains(trait)
        ts.beginEditing()
        ts.enumerateAttribute(.font, in: sel, options: []) { val, r, _ in
            let f = (val as? NSFont) ?? InkNS.font
            ts.addAttribute(.font, value: has ? fm.convert(f, toNotHaveTrait: trait) : fm.convert(f, toHaveTrait: trait), range: r)
        }
        ts.endEditing()
        tv.didChangeText()
    }

    /// Toggle a bulleted list on the paragraph(s) covering the selection. The
    /// NSTextList serializes to <ul><li> in the exported HTML.
    func toggleBullet() {
        guard let tv = textView, let ts = tv.textStorage, ts.length > 0 else { return }
        let loc = min(tv.selectedRange().location, ts.length - 1)
        let pr = (ts.string as NSString).paragraphRange(for: NSRange(location: loc, length: max(tv.selectedRange().length, 0)))
        let base = ts.attribute(.paragraphStyle, at: pr.location, effectiveRange: nil) as? NSParagraphStyle
        let style = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        if style.textLists.isEmpty {
            style.textLists = [NSTextList(markerFormat: .disc, options: 0)]
            style.headIndent = 18; style.firstLineHeadIndent = 2
        } else {
            style.textLists = []; style.headIndent = 0; style.firstLineHeadIndent = 0
        }
        ts.addAttribute(.paragraphStyle, value: style, range: pr)
        tv.didChangeText()
    }

    /// Prompt for a URL and link the current selection.
    func addLink() {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let sel = tv.selectedRange()
        guard sel.length > 0 else { NSSound.beep(); return }   // select the text to link first
        let alert = NSAlert()
        alert.messageText = "Add link"
        alert.informativeText = "Link the selected text to:"
        alert.addButton(withTitle: "Add"); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "https://…"
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var s = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        if !(s.hasPrefix("http://") || s.hasPrefix("https://") || s.hasPrefix("mailto:")) { s = "https://" + s }
        ts.addAttribute(.link, value: s, range: sel)
        ts.addAttribute(.foregroundColor, value: InkNS.accent, range: sel)
        ts.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: sel)
        tv.didChangeText()
    }

    func plainText() -> String { textView?.string ?? "" }

    /// HTML for the message body (preserves bold/italic/lists/links).
    func html() -> String {
        guard let ts = textView?.textStorage, ts.length > 0 else { return "" }
        let range = NSRange(location: 0, length: ts.length)
        guard let data = try? ts.data(from: range, documentAttributes: [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue,
        ]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

struct RichTextEditor: NSViewRepresentable {
    @ObservedObject var controller: RichTextController
    var initialText: String = ""

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = true
        tv.isEditable = true
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.font = InkNS.font
        tv.textColor = InkNS.text
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.typingAttributes = [.font: InkNS.font, .foregroundColor: InkNS.text]
        tv.linkTextAttributes = [
            .foregroundColor: InkNS.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        controller.textView = tv     // plain weak ref; not @Published, so no update-cycle warning
        if !initialText.isEmpty { controller.setPlainText(initialText) }   // seed the generated draft
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
