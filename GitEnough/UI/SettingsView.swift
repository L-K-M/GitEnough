import SwiftUI
import AppKit

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
        .frame(width: 480, height: 360)
    }
}

// MARK: - General

private struct GeneralSettingsView: View {

    @AppStorage("pullRebase") private var pullRebase = false
    @AppStorage(AppState.discoveryFolderKey) private var discoveryFolder = ""
    @EnvironmentObject var appState: AppState

    /// `git --version` shells out synchronously — computing it in `body` spawned a
    /// process on every Settings render. Fetched once per Settings appearance
    /// instead, so it also picks up a CLT install without relaunching (matching
    /// the git-missing alert's reprobe flow).
    @State private var gitVersion: String?

    var body: some View {
        Form {
            Picker("When pulling:", selection: $pullRebase) {
                Text("Merge the fetched changes").tag(false)
                Text("Rebase the current branch").tag(true)
            }
            .pickerStyle(.radioGroup)

            Section("Repository discovery") {
                HStack {
                    Label {
                        Text(discoveryFolder.isEmpty ? "No watch folder" : abbreviate(discoveryFolder))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    Spacer()
                    Button("Choose…") { chooseDiscoveryFolder() }
                    Button("Scan Now") { appState.scanDiscoveryFolder() }
                    Button("Clear") { discoveryFolder = "" }
                        .disabled(discoveryFolder.isEmpty)
                }
                Text("Repositories found directly inside the watch folder — or one folder deep — are added to the sidebar automatically, about once a minute. Repositories you remove from the sidebar stay removed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("git") {
                Text(gitVersion ?? "Checking…")
                    .foregroundStyle(.secondary)
                    .task {
                        // Off the main thread: even one synchronous process
                        // spawn would beachball Settings briefly.
                        gitVersion = await Task.detached {
                            GitClient.version() ?? "not found"
                        }.value
                    }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseDiscoveryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Watch"
        if panel.runModal() == .OK, let url = panel.url {
            discoveryFolder = url.path
            // Pick up whatever is in there right away rather than on the next tick.
            appState.scanDiscoveryFolder()
        }
    }

    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
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
    @State private var models: [String] = []
    @State private var isLoadingModels = false
    @State private var modelsError: String?

    init() {
        let config = LLMConfiguration.load()
        _provider = State(initialValue: config.provider)
        _baseURL = State(initialValue: config.baseURL)
        _model = State(initialValue: config.model)
        _apiKey = State(initialValue: LLMConfiguration.apiKey ?? "")
    }

    /// The fetched models, with the current value pinned in case the provider's
    /// list doesn't contain it (custom/legacy model names stay selectable).
    private var modelChoices: [String] {
        var choices = models
        if !model.isEmpty && !choices.contains(model) {
            choices.insert(model, at: 0)
        }
        return choices
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
                models = []
                modelsError = nil
            }

            TextField("Base URL", text: $baseURL)
                .help("An OpenAI-compatible endpoint; /chat/completions is appended.")

            SecureField("API key", text: $apiKey)
                .help("Stored in the macOS Keychain, never in plain text.")

            if models.isEmpty {
                TextField("Model", text: $model)
                if let modelsError {
                    Text("Couldn't load the model list (\(modelsError)) — enter the model name manually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Enter an API key and choose “Load Models” to pick from the provider's list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("Model", selection: $model) {
                    ForEach(modelChoices, id: \.self) { choice in
                        Text(choice).tag(choice)
                    }
                }
            }

            HStack {
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                Button("Load Models") { loadModels() }
                    .disabled(isLoadingModels || apiKey.isEmpty)
                Button("Test Connection") { testConnection() }
                    .disabled(isTesting || apiKey.isEmpty)
                if isTesting || isLoadingModels {
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
        .onAppear {
            if models.isEmpty && !apiKey.isEmpty && !baseURL.isEmpty {
                loadModels()
            }
        }
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

    /// Fetches the provider's model list; switches the model field to a picker
    /// on success, leaves the text field (with a note) on failure.
    private func loadModels() {
        save()
        isLoadingModels = true
        modelsError = nil
        let config = LLMConfiguration(provider: provider, baseURL: baseURL, model: model)
        let generator = CommitMessageGenerator(configuration: config,
                                               apiKeyProvider: { self.apiKey })
        Task {
            do {
                let fetched = try await generator.fetchModels()
                await MainActor.run {
                    models = fetched
                    isLoadingModels = false
                    if model.isEmpty, let first = fetched.first {
                        model = first
                    }
                }
            } catch {
                await MainActor.run {
                    modelsError = error.localizedDescription
                    isLoadingModels = false
                }
            }
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
