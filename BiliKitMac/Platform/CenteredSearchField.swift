import AppKit
import SwiftUI

struct CenteredSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField()
        searchField.placeholderString = placeholder
        searchField.delegate = context.coordinator
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.submit(_:))
        searchField.setAccessibilityLabel(placeholder)
        searchField.setAccessibilityHelp("输入关键词并按 Return 搜索")
        searchField.setAccessibilityIdentifier("search.field")
        return searchField
    }

    func updateNSView(_ searchField: NSSearchField, context: Context) {
        context.coordinator.parent = self
        searchField.placeholderString = placeholder
        searchField.setAccessibilityLabel(placeholder)
        searchField.setAccessibilityHelp("输入关键词并按 Return 搜索")
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: CenteredSearchField

        init(parent: CenteredSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else {
                return
            }
            parent.text = searchField.stringValue
        }

        @objc
        func submit(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            parent.onSubmit()
        }
    }
}
