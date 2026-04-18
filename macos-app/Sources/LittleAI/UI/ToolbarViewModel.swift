import SwiftUI

@MainActor
final class ToolbarViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case preview(original: String, result: String)
        case error(String)
    }

    @Published var state: State = .idle
    @Published var selection: String = ""
    @Published var includeBroaderContext: Bool = true

    var onAction: ((ActionType, Tone?, Bool) -> Void)?
    var onAccept: ((String) -> Void)?
    var onCancel: (() -> Void)?

    func reset(selection: String) {
        self.selection = selection
        state = .idle
    }
}
