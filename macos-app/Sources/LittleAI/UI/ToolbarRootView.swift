import SwiftUI

struct ToolbarRootView: View {
    @ObservedObject var viewModel: ToolbarViewModel

    var body: some View {
        content
            .padding(16)
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            ActionBar(viewModel: viewModel)
        case .compose:
            ComposeView(viewModel: viewModel)
        case .loading:
            LoadingView()
        case let .preview(result, isInsertion):
            PreviewView(result: result, isInsertion: isInsertion, viewModel: viewModel)
        case let .error(message):
            ErrorView(message: message, viewModel: viewModel)
        }
    }
}

private struct ActionBar: View {
    @ObservedObject var viewModel: ToolbarViewModel

    var body: some View {
        HStack(spacing: 4) {
            ActionButton(symbol: "checkmark.seal", label: "Correggi") {
                viewModel.onAction?(.correct, nil)
            }
            ActionButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Estendi") {
                viewModel.onAction?(.extend, nil)
            }
            ActionButton(symbol: "arrow.down.right.and.arrow.up.left", label: "Riduci") {
                viewModel.onAction?(.reduce, nil)
            }
            ActionButton(symbol: "globe", label: "Traduci") {
                viewModel.onAction?(.translate, nil)
            }
            Menu {
                ForEach(Tone.allCases) { tone in
                    Button(tone.label) { viewModel.onAction?(.tone, tone) }
                }
            } label: {
                Label("Tono", systemImage: "theatermasks")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer(minLength: 0)
        }
    }
}

private struct ComposeView: View {
    @ObservedObject var viewModel: ToolbarViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            TextField("Cosa vuoi scrivere?", text: $viewModel.composeText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit(submit)
            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)
            .disabled(viewModel.composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.defaultAction)
        }
        .onAppear { focused = true }
    }

    private func submit() {
        let text = viewModel.composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        viewModel.onGenerate?(text)
    }
}

private struct ActionButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

private struct LoadingView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Generazione…").font(.system(size: 13))
            Spacer()
        }
    }
}

private struct PreviewView: View {
    let result: String
    let isInsertion: Bool
    @ObservedObject var viewModel: ToolbarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Anteprima")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(result)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Annulla") { viewModel.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isInsertion ? "Inserisci" : "Sostituisci") {
                    viewModel.onAccept?(result, isInsertion)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

private struct ErrorView: View {
    let message: String
    @ObservedObject var viewModel: ToolbarViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 13)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Chiudi") { viewModel.onCancel?() }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
