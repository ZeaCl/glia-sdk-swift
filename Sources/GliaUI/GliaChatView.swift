#if canImport(SwiftUI) && canImport(Combine)
import SwiftUI
import GliaSDK

public struct GliaChatView: View {
    @ObservedObject private var viewModel: GliaChatViewModel
    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    private let title: String?
    private let welcomeMessage: String
    private let placeholder: String
    private let suggestedPrompts: [String]
    private let theme: GliaTheme
    private let systemPrompt: String?
    private let tools: [GliaToolDefinition]
    private let disconnectOnDisappear: Bool
    private var pendingPrompt: Binding<String?>?

    public init(
        viewModel: GliaChatViewModel,
        title: String? = "Asistente AI",
        welcomeMessage: String = "¡Hola! ¿En qué te puedo ayudar hoy?",
        placeholder: String = "Escribe un mensaje...",
        suggestedPrompts: [String] = [],
        theme: GliaTheme = GliaTheme(),
        systemPrompt: String? = nil,
        tools: [GliaToolDefinition] = [],
        disconnectOnDisappear: Bool = false,
        pendingPrompt: Binding<String?>? = nil
    ) {
        self.viewModel = viewModel
        self.title = title
        self.welcomeMessage = welcomeMessage
        self.placeholder = placeholder
        self.suggestedPrompts = suggestedPrompts
        self.theme = theme
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.disconnectOnDisappear = disconnectOnDisappear
        self.pendingPrompt = pendingPrompt
    }

    public var body: some View {
        VStack(spacing: 0) {
            if let title = title {
                headerBar(title: title)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if viewModel.messages.isEmpty && !viewModel.isStreaming {
                            welcomeView
                        }

                        ForEach(viewModel.messages) { msg in
                            messageBubble(for: msg)
                                .id(msg.id)
                        }

                        if viewModel.isStreaming {
                            liveStreamingView
                                .id("live_streaming_indicator")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: viewModel.messages.count) { _ in
                    if let last = viewModel.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                // Auto-scroll durante streaming continuo sin animaciones para evitar saturar el Main Thread
                .onChange(of: viewModel.currentText) { _ in
                    proxy.scrollTo("live_streaming_indicator", anchor: .bottom)
                }
            }

            if let err = viewModel.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(theme.errorColor)
                    Text(err)
                        .font(.caption)
                        .foregroundColor(theme.errorColor)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(theme.errorColor.opacity(0.12))
            }

            inputBar
        }
        .background(theme.backgroundColor.ignoresSafeArea())
        .onAppear {
            viewModel.connect()
            handlePendingPrompt()
        }
        .onDisappear {
            if disconnectOnDisappear {
                viewModel.disconnect()
            }
        }
        .onChange(of: pendingPrompt?.wrappedValue) { newValue in
            if let text = newValue, !text.isEmpty {
                viewModel.send(prompt: text, systemPrompt: systemPrompt, tools: tools)
                pendingPrompt?.wrappedValue = nil
            }
        }
    }

    private func headerBar(title: String) -> some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Estado de conexión")
                    .accessibilityValue(viewModel.isConnected ? "Conectado" : "Desconectado")
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(theme.textMutedColor)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.surfaceColor)
    }

    private var welcomeView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(welcomeMessage)
                .font(.body)
                .foregroundColor(theme.textColor)
                .padding(14)
                .background(theme.surfaceColor)
                .cornerRadius(16)

            if !suggestedPrompts.isEmpty {
                Text("Sugerencias:")
                    .font(.caption)
                    .foregroundColor(theme.textMutedColor)

                ForEach(suggestedPrompts, id: \.self) { prompt in
                    Button(action: {
                        viewModel.send(prompt: prompt, systemPrompt: systemPrompt, tools: tools)
                    }) {
                        Text(prompt)
                            .font(.subheadline)
                            .foregroundColor(theme.primaryColor)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.surfaceContainerHigh)
                            .cornerRadius(12)
                    }
                }
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private func messageBubble(for msg: GliaChatMessage) -> some View {
        if msg.role == .user {
            HStack {
                Spacer()
                Text(msg.content)
                    .font(.body)
                    .foregroundColor(theme.userBubbleTextColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(theme.userBubbleColor)
                    .cornerRadius(18)
                    .frame(maxWidth: 280, alignment: .trailing)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let thinking = msg.thinking, !thinking.isEmpty {
                    disclosureThinkingView(text: thinking)
                }

                if let tool = msg.toolName {
                    HStack(spacing: 6) {
                        Image(systemName: "bolt.fill")
                            .foregroundColor(.yellow)
                        Text("Acción: \(tool)")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(theme.textMutedColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(theme.surfaceContainerHigh)
                    .cornerRadius(8)
                }

                Text(msg.content)
                    .font(.body)
                    .foregroundColor(theme.agentBubbleTextColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(theme.agentBubbleColor)
                    .cornerRadius(18)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var liveStreamingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.currentThinking.isEmpty {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text(viewModel.currentThinking)
                        .font(.caption)
                        .italic()
                        .foregroundColor(theme.thinkingTextColor)
                }
                .padding(10)
                .background(theme.thinkingBgColor)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.thinkingBorderColor, lineWidth: 1)
                )
            }

            if let tool = viewModel.currentTool {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                        .foregroundColor(.yellow)
                    Text("Ejecutando: \(tool)...")
                        .font(.caption)
                        .foregroundColor(.yellow)
                }
                .padding(8)
                .background(Color.yellow.opacity(0.12))
                .cornerRadius(8)
            }

            if !viewModel.currentText.isEmpty {
                Text(viewModel.currentText)
                    .font(.body)
                    .foregroundColor(theme.agentBubbleTextColor)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(theme.agentBubbleColor)
                    .cornerRadius(18)
            }
        }
    }

    private func disclosureThinkingView(text: String) -> some View {
        DisclosureGroup(
            content: {
                Text(text)
                    .font(.caption)
                    .foregroundColor(theme.textMutedColor)
                    .padding(.top, 4)
            },
            label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.caption)
                    Text("Proceso de razonamiento")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                .foregroundColor(theme.thinkingTextColor)
            }
        )
        .padding(10)
        .background(theme.thinkingBgColor)
        .cornerRadius(10)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $inputText)
                .focused($isInputFocused)
                .foregroundColor(theme.textColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(theme.surfaceColor)
                .cornerRadius(20)
                .onSubmit {
                    sendAction()
                }

            Button(action: sendAction) {
                Image(systemName: "arrow.up.circle.fill")
                    .resizable()
                    .frame(width: 34, height: 34)
                    .foregroundColor(
                        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? theme.textMutedColor
                            : theme.primaryColor
                    )
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isStreaming)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.surfaceColor)
    }

    private func sendAction() {
        let text = inputText
        inputText = ""
        viewModel.send(prompt: text, systemPrompt: systemPrompt, tools: tools)
    }

    private func handlePendingPrompt() {
        if let text = pendingPrompt?.wrappedValue, !text.isEmpty {
            viewModel.send(prompt: text, systemPrompt: systemPrompt, tools: tools)
            pendingPrompt?.wrappedValue = nil
        }
    }
}
#endif
