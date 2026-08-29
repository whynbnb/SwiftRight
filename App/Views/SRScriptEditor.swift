import AppKit
import SwiftUI

/// 脚本编辑框。
///
/// 没有直接用 `TextEditor`：它默认开着智能引号和破折号替换，
/// 敲出来的 `"` 会变成 `"`，脚本一跑就语法错误，而且不好排查。
struct SRScriptEditor: NSViewRepresentable {

    @Binding var text: String
    /// 外部想在光标处插入占位符时，把 token 塞进来。
    @Binding var pendingInsertion: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.string = text

        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.usesFindBar = true

        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true

        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // 只在外部真的改了内容时回写，否则会打断输入法和撤销栈。
        if textView.string != text, !context.coordinator.isEditing {
            textView.string = text
        }

        if let token = pendingInsertion {
            textView.insertText(token, replacementRange: textView.selectedRange())
            DispatchQueue.main.async {
                self.text = textView.string
                self.pendingInsertion = nil
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: SRScriptEditor
        weak var textView: NSTextView?
        var isEditing = false

        init(_ parent: SRScriptEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
