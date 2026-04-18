import SwiftUI

struct ToolbarRootView: View {
    @ObservedObject var viewModel: ToolbarViewModel

    var body: some View {
        ZStack {
            VisualEffectBackground()
            content
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .idle:
            ActionBar(viewModel: viewModel)
        case .loading:
            LoadingView()
        case let .preview(original, result):
            PreviewView(original: original, result: result, viewModel: viewModel)
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
                viewModel.onAction?(.correct, nil, viewModel.includeBroaderContext)
            }
            ActionButton(symbol: "arrow.up.left.and.arrow.down.right", label: "Estendi") {
                viewModel.onAction?(.extend, nil, viewModel.includeBroaderContext)
            }
            ActionButton(symbol: "arrow.down.right.and.arrow.up.left", label: "Riduci") {
                viewModel.onAction?(.reduce, nil, viewModel.includeBroaderContext)
            }
            Menu {
                ForEach(Tone.allCases) { tone in
                    Button(tone.label) { viewModel.onAction?(.tone, tone, viewModel.includeBroaderContext) }
                }
            } label: {
                Label("Tono", systemImage: "theatermasks")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 20)

            Toggle(isOn: $viewModel.includeBroaderContext) {
                Image(systemName: "text.viewfinder")
            }
            .toggleStyle(.button)
            .help("Includi contesto ampio circostante")

            Spacer(minLength: 0)
        }
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
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Generazione…").font(.system(size: 12))
            Spacer()
        }
    }
}

private struct PreviewView: View {
    let original: String
    let result: String
    @ObservedObject var viewModel: ToolbarViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Anteprima").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(result)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
            HStack {
                Button("Annulla") { viewModel.onCancel?() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Sostituisci") { viewModel.onAccept?(result) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ErrorView: View {
    let message: String
    @ObservedObject var viewModel: ToolbarViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 12)).lineLimit(2)
            Spacer()
            Button("Chiudi") { viewModel.onCancel?() }
        }
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
