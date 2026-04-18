import SwiftUI

@MainActor
final class ToolbarViewModel: ObservableObject {
    enum State {
        case idle              // selezione presente → mostra ActionBar
        case compose           // nessuna selezione → mostra campo prompt
        case loading
        case preview(result: String, isInsertion: Bool)
        case error(String)
    }

    @Published var state: State = .idle
    @Published var selection: String = ""
    @Published var composeText: String = ""

    var onAction: ((ActionType, Tone?) -> Void)?
    var onGenerate: ((String) -> Void)?
    var onAccept: ((String, Bool) -> Void)?   // (result, isInsertion)
    var onCancel: (() -> Void)?

    func reset(selection: String) {
        self.selection = selection
        self.composeText = ""
        state = selection.isEmpty ? .compose : .idle
    }
}
