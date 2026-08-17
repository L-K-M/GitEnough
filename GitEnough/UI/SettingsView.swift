import SwiftUI

/// Settings (⌘,): general git behavior, the AI commit-message provider, and the
/// detected external merge tools.
struct SettingsView: View {

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gear") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
            ToolsSettingsView()
                .tabItem { Label("Merge Tools", systemImage: "wrench.and.screwdriver") }
        }
        .frame(width: 480, height: 320)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {

    @AppStorage("pullRebase") private var pullRebase = false

    var body: some View {
        Form {
            Picker("When pulling:", selection: $pullRebase) {
                Text("Merge the fetched changes").tag(false)
                Text("Rebase the current branch").tag(true)
            }
            .pickerStyle(.radioGroup)

            LabeledContent("git") {
                Text(GitClient.version() ?? "not found")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - AI

private struct AISettingsView: View {

    @State private var provider: LLMConfiguration.Provider
    @State private var baseURL: String
    @State private var model: String
    @State private var apiKey: String = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isTesting = false

    init() {
        let config = LLMConfiguration.load()
        _provider = State(initialValue: config.provider)
        _baseURL = State(initialValue: config.baseURL)
        _model = State(initialValue: config.model)
        _apiKey = State(initialValue: LLMConfiguration.apiKey ?? "")
    }

    var body: some View {
        Form {
            Picker("Provider", selection: $provider) {
                ForEach(LLMConfiguration.Provider.allCases) { provider in
                    Text(provider.rawValue).tag(provider)
                }
            }
            .onChange(of: provider) { _, newProvider in
                baseURL = newProvider.defaultBaseURL
                model = newProvider.defaultModel
            }

            TextField("Base URL", text: $baseURL)
                .help("An OpenAI-compatible endpoint; /chat/completions is appended.")

            TextField("Model", text: $model)

            SecureField("API key", text: $apiKey)
                .help("Stored in the macOS Keychain, never in plain text.")

            HStack {
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                Button("Test Connection") { testConnection() }
                    .disabled(isTesting || apiKey.isEmpty)
                if isTesting {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusIsError ? .red : .green)
                    .lineLimit(4)
            }

            Text("Used by the ✨ Generate button in the commit box to write commit messages from your staged diff.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .padding()
    }

    private func save() {
        LLMConfiguration(provider: provider, baseURL: baseURL, model: model).save()
        do {
            try LLMConfiguration.saveAPIKey(apiKey)
            statusIsError = false
            statusMessage = "Saved."
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    /// A round-trip with a trivial diff proves endpoint, key and model in one go.
    private func testConnection() {
        save()
        isTesting = true
        statusMessage = nil
        let config = LLMConfiguration(provider: provider, baseURL: baseURL, model: model)
        let generator = CommitMessageGenerator(configuration: config,
                                               apiKeyProvider: { self.apiKey })
        Task {
            do {
                let message = try await generator.generateCommitMessage(
                    diffStat: " Sources/App.swift | 2 +-\n 1 file changed, 1 insertion(+), 1 deletion(-)",
                    diff: "diff --git a/Sources/App.swift b/Sources/App.swift\n--- a/Sources/App.swift\n+++ b/Sources/App.swift\n@@ -1 +1 @@\n-let version = 1\n+let version = 2",
                    branch: "main")
                await MainActor.run {
                    isTesting = false
                    statusIsError = false
                    statusMessage = "Connection works — sample message: “\(message.components(separatedBy: "\n").first ?? "")”"
                }
            } catch {
                await MainActor.run {
                    isTesting = false
                    statusIsError = true
                    statusMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Merge tools

private struct ToolsSettingsView: View {

    @State private var tools: [MergeTool] = MergeTool.detectInstalled()

    var body: some View {
        Form {
            Section("Detected merge tools") {
                if tools.isEmpty {
                    Text("No external merge tools found. FileMerge ships with Xcode — it should always be here; check your Xcode Command Line Tools.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(tools) { tool in
                        Label(tool.name, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.primary)
                    }
                }
            }
            Section {
                Text("Conflicted files in the Changes tab can be opened in any detected tool via “Merge Tool”. GitEnough invokes `git mergetool`, which stages the file once the tool reports it resolved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Rescan") {
                    tools = MergeTool.detectInstalled()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
