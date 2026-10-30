import CGtk
import Dispatch
import Foundation
import GitEnough

/// Preferences: the LLM behind the ✨ Generate button.
///
/// Until this existed the GTK build had Generate wired to a provider it had no
/// way to configure, so the one feature that is not plain git was unreachable on
/// Linux short of writing the key into the keyring by hand with `secret-tool`.
/// "No API key configured" is the default state of a fresh install, so that was
/// also the first thing a new user met.
///
/// The settings themselves are the macOS Settings → AI tab's, read and written
/// through the same `LLMConfiguration`, so neither front end can disagree about
/// where a base URL lives or what a provider's defaults are.
final class SettingsDialog {

    private let window: UnsafeMutablePointer<GtkWindow>

    private let providerDropDown: UnsafeMutablePointer<GtkWidget>
    private let baseURLEntry = require(gtk_entry_new(), "entry")
    private let apiKeyEntry = require(gtk_password_entry_new(), "password entry")
    private let modelEntry = require(gtk_entry_new(), "entry")
    /// Appears under the model field once a model list has been fetched.
    /// The entry stays the field of record, so a model the provider does not
    /// list — a local llama.cpp name, a legacy deployment — stays typeable.
    private let modelChoices: UnsafeMutablePointer<GtkWidget>
    private let modelChoicesRow = UI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private let modelList = require(gtk_string_list_new(nil), "string list")

    private let saveButton: UnsafeMutablePointer<GtkWidget>
    private let loadModelsButton: UnsafeMutablePointer<GtkWidget>
    private let testButton: UnsafeMutablePointer<GtkWidget>
    private let spinner = require(gtk_spinner_new(), "spinner")
    private let statusLabel = UI.label("", xalign: 0)
    private let keyringWarning = UI.label("", xalign: 0)

    /// The last values written to (or read from) storage. Everything the user
    /// has typed since is unsaved, which the status line says out loud —
    /// nothing here writes the keyring behind the user's back.
    private var savedConfiguration = LLMConfiguration.default
    private var savedAPIKey = ""
    /// Set once `savedAPIKey` is known to match the keyring, by either the
    /// opening read or a successful save. A save beats a slow read to it, and
    /// the read must then not overwrite what the save just established.
    private var keyIsKnown = false
    /// Suppresses the dirty check while the dialog is filling its own fields.
    private var isPopulating = false
    /// Which showing this is, whether the key was touched, and whether an
    /// operation is out — every lifecycle question, in a type that can be
    /// tested without a window. See `SettingsEditStateTests`.
    private var edit = SettingsEditState()

    /// `secret-tool` is a process, and so is every `which` probe in front of it.
    /// One serial queue keeps a save and a re-read from interleaving, and keeps
    /// both off the main loop — a keyring prompt on the GTK thread would freeze
    /// the window until the user answered it.
    private static let keyring = DispatchQueue(label: "dev.gitenough.settings.keyring")

    init(parent: UnsafeMutablePointer<GtkWindow>) {
        providerDropDown = Self.dropDown(LLMConfiguration.Provider.allCases.map(\.rawValue))
        // `gtk_drop_down_new` takes the model's reference. This dialog keeps a
        // pointer to the list so it can refill it, so it takes one of its own
        // rather than reading through the drop-down's.
        g_object_ref(modelList.rawObject)
        modelChoices = require(gtk_drop_down_new(opaque(modelList), nil), "drop down")

        saveButton = require(gtk_button_new_with_label("Save"), "button")
        UI.addClass(saveButton, "suggested-action")
        loadModelsButton = require(gtk_button_new_with_label("Load Models"), "button")
        testButton = require(gtk_button_new_with_label("Test Connection"), "button")

        window = cast(require(gtk_window_new(), "window"))
        gtk_window_set_title(window, "Settings")
        gtk_window_set_transient_for(window, parent)
        gtk_window_set_modal(window, 1)
        gtk_window_set_default_size(window, 540, -1)
        // Destroying the window would take the widgets with it while this object
        // still holds their pointers, and the gear button can be clicked again.
        gtk_window_set_hide_on_close(window, 1)

        gtk_entry_set_placeholder_text(cast(baseURLEntry, to: GtkEntry.self), "https://…")
        gtk_entry_set_placeholder_text(cast(modelEntry, to: GtkEntry.self), "Model name")
        Properties.set(apiKeyEntry, "placeholder-text", "Not set")
        gtk_password_entry_set_show_peek_icon(opaque(apiKeyEntry), 1)
        UI.expand(baseURLEntry, vertical: false)
        UI.expand(apiKeyEntry, vertical: false)
        UI.expand(modelEntry, vertical: false)

        gtk_widget_set_tooltip_text(baseURLEntry,
                                    "An OpenAI-compatible endpoint; /chat/completions is appended.")
        gtk_widget_set_tooltip_text(apiKeyEntry,
                                    "Stored in the system keyring, never in a file.")
        gtk_widget_set_tooltip_text(loadModelsButton,
                                    "Ask the provider which models it offers")
        gtk_widget_set_tooltip_text(testButton,
                                    "Write a commit message for a sample diff, to prove "
                                        + "the endpoint, key and model all work")

        gtk_window_set_child(window, buildContent())
        wireActions()
    }

    deinit {
        // Releases the reference taken in `init`; the drop-down keeps its own
        // until the window goes. The window is a toplevel, so GTK holds it
        // whether or not anything else does — without this it would outlive the
        // object that is the only way to open it again.
        g_object_unref(modelList.rawObject)
        gtk_window_destroy(window)
    }

    /// Shows the dialog, re-reading what is stored first: the keyring is shared
    /// with `secret-tool` and with any other GitEnough window, so what was in
    /// the fields last time is not evidence of what is stored now.
    func present() {
        edit.present()
        // The state clears its own busy flag, but the controls an abandoned
        // operation disabled are still disabled until something says so.
        syncButtons()
        reload()
        gtk_window_present(window)
    }

    // MARK: - Layout

    private func buildContent() -> UnsafeMutablePointer<GtkWidget> {
        let grid = require(gtk_grid_new(), "grid")
        let form = cast(grid, to: GtkGrid.self)
        gtk_grid_set_row_spacing(form, 8)
        gtk_grid_set_column_spacing(form, 12)

        var row: Int32 = 0
        func field(_ caption: String, _ control: UnsafeMutablePointer<GtkWidget>) {
            let label = UI.label(caption, xalign: 1)
            gtk_grid_attach(form, label, 0, row, 1, 1)
            gtk_grid_attach(form, control, 1, row, 1, 1)
            row += 1
        }

        field("Provider", providerDropDown)
        field("Base URL", baseURLEntry)
        field("API key", apiKeyEntry)
        field("Model", modelEntry)

        UI.append(modelChoicesRow, UI.label("or pick one:", dim: true), modelChoices)
        UI.setVisible(modelChoicesRow, false)
        gtk_grid_attach(form, modelChoicesRow, 1, row, 1, 1)
        row += 1

        let buttons = UI.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        UI.append(buttons, saveButton, loadModelsButton, testButton, spinner)
        gtk_grid_attach(form, buttons, 1, row, 1, 1)
        row += 1

        // Wrapping rather than ellipsizing: a provider's refusal arrives as an
        // HTTP body, and the part that names the cause is usually at the end.
        for label in [statusLabel, keyringWarning] {
            let text = opaque(label)
            gtk_label_set_wrap(text, 1)
            gtk_label_set_lines(text, 4)
            gtk_label_set_ellipsize(text, PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(text, 1)
            UI.expand(label, vertical: false)
        }
        UI.setVisible(keyringWarning, false)
        gtk_grid_attach(form, statusLabel, 1, row, 1, 1)
        row += 1
        gtk_grid_attach(form, keyringWarning, 1, row, 1, 1)
        row += 1

        let notes = UI.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        for caption in [
            "Used by the ✨ Generate button in the commit box to write commit "
                + "messages from your staged diff.",
            "Opening Settings never contacts the provider. Only Generate, Load "
                + "Models and Test Connection make requests, and only Save writes "
                + "anything down.",
        ] {
            let label = UI.label(caption, dim: true)
            // A label asks for its whole text on one line unless told otherwise,
            // and these are long enough to set the dialog's width on their own.
            gtk_label_set_wrap(opaque(label), 1)
            gtk_label_set_max_width_chars(opaque(label), 52)
            UI.append(notes, label)
        }
        gtk_grid_attach(form, notes, 1, row, 1, 1)

        let content = UI.box(GTK_ORIENTATION_VERTICAL, spacing: 12, margin: 16)
        UI.append(content, grid)
        return content
    }

    // MARK: - Actions

    private func wireActions() {
        // The provider's defaults replace the endpoint and model, the way the
        // macOS picker does — switching provider and keeping the old provider's
        // base URL is never what was meant.
        connect(providerDropDown, "notify::selected") { [weak self] _ in
            guard let self, !isPopulating else { return }
            let provider = selectedProvider()
            setText(baseURLEntry, provider.defaultBaseURL)
            setText(modelEntry, provider.defaultModel)
            clearModelChoices()
            refreshStatus()
        }

        for entry in [baseURLEntry, apiKeyEntry, modelEntry] {
            connect(entry, "changed") { [weak self] in
                guard let self, !isPopulating else { return }
                refreshStatus()
            }
        }
        connect(apiKeyEntry, "changed") { [weak self] in
            guard let self, !isPopulating else { return }
            edit.editKey()
        }

        connect(modelChoices, "notify::selected") { [weak self] _ in
            guard let self, !isPopulating else { return }
            let index = Int(gtk_drop_down_get_selected(opaque(modelChoices)))
            guard let name = gtk_string_list_get_string(modelList, UInt32(index)) else { return }
            setText(modelEntry, String(cString: name))
        }

        connect(saveButton, "clicked") { [weak self] in self?.save() }
        connect(loadModelsButton, "clicked") { [weak self] in self?.loadModels() }
        connect(testButton, "clicked") { [weak self] in self?.testConnection() }
    }

    private func save() {
        let configuration = currentConfiguration()
        // Only a key the user actually typed is written. Sending the field's
        // current value unconditionally would hand `saveAPIKey` an empty string
        // whenever the opening read failed, and that deletes — losing a stored
        // key because someone changed the model. An explicit clear still
        // reaches here, because clearing the field is editing it.
        let key = edit.keyPayload(displayed: currentAPIKey())
        let request = edit.request(for: configuration)
        // The non-secret half is UserDefaults and lands immediately; only the
        // key has to go out to a process.
        configuration.save()
        setBusy(true)
        show(status: "Saving…", kind: .plain)
        Self.keyring.async { [weak self] in
            // nil key means "leave the stored one alone", so no write and no
            // failure to report.
            let failure: String? = key.flatMap { pending in
                do {
                    try LLMConfiguration.saveAPIKey(pending)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }
            DispatchQueue.main.async { [weak self] in
                // A completion only touches the showing that started it. An
                // earlier one owns none of this dialog's state: clearing busy
                // would cancel the spinner of an operation this showing
                // started, and `finish` would record the old showing's values
                // as saved — including `keyIsKnown`, which makes this
                // showing's own opening lookup return without filling its
                // field.
                //
                // Nothing is lost by dropping it. The keyring queue is serial,
                // so this showing's lookup is enqueued behind that write and
                // observes it; the fields get the stored truth from their own
                // read rather than from a dialog the user has closed.
                guard let self, edit.isFromCurrentPresentation(request) else { return }
                setBusy(false)
                finish(save: request, key: key, failure: failure)
            }
        }
    }

    /// Records what reached storage and says so without overclaiming.
    ///
    /// The fields stay editable while the write is out — it can take the full
    /// keyring timeout — so what is on screen now may be newer than what was
    /// written. The snapshot still becomes `saved…`, because it is what is
    /// stored; `refreshStatus` then compares it against the live fields and
    /// says "Unsaved changes" on its own. Reporting a flat "Saved." here would
    /// claim the newer values had landed, and they would be gone on reopening.
    private func finish(save request: SettingsRequest, key: String?, failure: String?) {
        savedConfiguration = request.configuration
        if failure == nil, let key {
            savedAPIKey = key
            keyIsKnown = true
        }

        // Asks the state, so the key side is checked even when this save
        // carried no key: a key typed while the write was out was never
        // stored, and a flat "Saved" would say otherwise.
        let moved = edit.moved(since: request, configuration: currentConfiguration())

        if let failure {
            show(status: "Saved the provider settings. The API key was not stored: "
                     + failure, kind: .failure)
            return
        }
        if moved {
            show(status: "Saved what was on screen when you pressed Save. "
                     + "Your later edits are not saved yet.", kind: .plain)
            return
        }
        show(status: key == nil
                ? "Saved. The stored API key was left as it is."
                : "Saved.",
             kind: .success)
    }

    /// Fetches the provider's model list into the picker under the model field.
    /// Uses the fields as typed rather than what is stored, so a key can be
    /// tried before it is committed to the keyring.
    private func loadModels() {
        let request = edit.request(for: currentConfiguration())
        let generator = currentGenerator()
        setBusy(true)
        show(status: "Loading models…", kind: .plain)
        Task { [weak self] in
            do {
                let models = try await generator.fetchModels()
                await MainActor.run { [weak self] in
                    guard let self, accepts(request) else { return }
                    setBusy(false)
                    // `fetchModels` turns an empty list into an error, so there
                    // is no empty-but-successful case to handle here.
                    fill(modelChoices: models)
                    show(status: "\(models.count) models available.", kind: .success)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, accepts(request) else { return }
                    setBusy(false)
                    show(status: "Couldn't load the model list (\(error.localizedDescription)) "
                             + "— type the model name instead.", kind: .failure)
                }
            }
        }
    }

    /// Whether a result for `request` still
    /// describes what is on screen.
    ///
    /// A models list or a test verdict is only about the provider and endpoint
    /// it was fetched for. Switch provider while one is in flight, or close and
    /// reopen the dialog, and applying it would label the new configuration
    /// with the old one's answer. The busy state is cleared either way so the
    /// buttons do not stay dead.
    private func accepts(_ request: SettingsRequest) -> Bool {
        guard edit.accepts(request, configuration: currentConfiguration()) else {
            // A result from a previous showing is simply dropped: that dialog
            // is gone and the new one has its own busy state. A result for
            // settings the user has since changed is worth saying out loud,
            // because they are looking at the fields that invalidated it.
            if edit.isFromCurrentPresentation(request) {
                setBusy(false)
                show(status: "The provider or key changed while that was loading, so "
                         + "the result was discarded. Try again.", kind: .plain)
            }
            return false
        }
        return true
    }

    /// One real round trip proves endpoint, key and model together, which three
    /// separate validations could not.
    private func testConnection() {
        let request = edit.request(for: currentConfiguration())
        let generator = currentGenerator()
        setBusy(true)
        show(status: "Testing…", kind: .plain)
        Task { [weak self] in
            do {
                let message = try await generator.generateCommitMessage(
                    diffStat: Self.sampleDiffStat,
                    diff: Self.sampleDiff,
                    branch: "main")
                let subject = message.components(separatedBy: "\n").first ?? ""
                await MainActor.run { [weak self] in
                    guard let self, accepts(request) else { return }
                    setBusy(false)
                    show(status: "Connection works — sample message: “\(subject)”",
                         kind: .success)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, accepts(request) else { return }
                    setBusy(false)
                    show(status: error.localizedDescription, kind: .failure)
                }
            }
        }
    }

    // MARK: - Reading and writing the fields

    private func reload() {
        let configuration = LLMConfiguration.load()
        savedConfiguration = configuration
        isPopulating = true
        if let index = LLMConfiguration.Provider.allCases.firstIndex(of: configuration.provider) {
            gtk_drop_down_set_selected(opaque(providerDropDown), UInt32(index))
        }
        setText(baseURLEntry, configuration.baseURL)
        setText(modelEntry, configuration.model)
        setText(apiKeyEntry, "")
        clearModelChoices()
        isPopulating = false

        // Nothing waits on the keyring. The read can take the full
        // `SecretService.operationTimeout` on a session with a locked keyring
        // and no prompter, and a minute of dead controls is worst for the one
        // user who most needs to fix their configuration. Save is safe to leave
        // live because it writes the key only when the user has edited it —
        // see `userEditedKey`.
        keyIsKnown = false
        let request = edit.request(for: configuration)
        show(status: "Reading the keyring…", kind: .plain)
        Self.keyring.async { [weak self] in
            let lookup = LLMConfiguration.apiKeyLookup
            let available = KeychainStore.isAvailable
            DispatchQueue.main.async { [weak self] in
                guard let self, edit.isFromCurrentPresentation(request) else { return }
                // Said before a save fails rather than after, since the remedy
                // is to install a package and the field looks ordinary.
                UI.setVisible(keyringWarning, !available)
                if !available {
                    UI.setText(keyringWarning,
                               "No system keyring is reachable, so the API key cannot be "
                                   + "stored. On Ubuntu: sudo apt install libsecret-tools")
                    UI.addClass(keyringWarning, "error")
                }
                apply(lookup: lookup)
            }
        }
    }

    /// Takes what the keyring said about the stored key.
    ///
    /// The three answers are not interchangeable. `absent` is evidence that
    /// nothing is stored, so an empty field is the truth. `unavailable` is the
    /// absence of evidence: the field stays empty because there is nothing to
    /// show, but the dialog must not conclude the key is empty — doing so is
    /// what let a Save for an unrelated model change delete a perfectly good
    /// key.
    private func apply(lookup: SecretLookup) {
        // A save that beat the read to it already knows better.
        guard !keyIsKnown else { return }

        switch lookup {
        case .found(let key):
            keyIsKnown = true
            savedAPIKey = key
            // Anything the user typed while the read was out is theirs, and the
            // stored value must not land on top of it.
            if !edit.userEditedKey {
                isPopulating = true
                setText(apiKeyEntry, key)
                isPopulating = false
            }
            refreshStatus()

        case .absent:
            keyIsKnown = true
            savedAPIKey = ""
            refreshStatus()

        case .unavailable:
            // Deliberately leaves `keyIsKnown` false, so Save still refuses to
            // touch the key unless the user edits it.
            show(status: "Couldn't read the stored API key, so it is not shown. "
                     + "Saving will leave it as it is unless you type a new one.",
                 kind: .failure)
        }
    }

    private func currentConfiguration() -> LLMConfiguration {
        LLMConfiguration(provider: selectedProvider(),
                         baseURL: text(of: baseURLEntry),
                         model: text(of: modelEntry))
    }

    private func currentAPIKey() -> String { text(of: apiKeyEntry) }

    /// A generator over the fields as typed. The key is handed over directly
    /// rather than read back from the keyring, so Test and Load Models say
    /// something about what is on screen.
    private func currentGenerator() -> CommitMessageGenerator {
        let key = currentAPIKey()
        return CommitMessageGenerator(configuration: currentConfiguration(),
                                      apiKeyProvider: { key.isEmpty ? nil : key })
    }

    private func selectedProvider() -> LLMConfiguration.Provider {
        let index = Int(gtk_drop_down_get_selected(opaque(providerDropDown)))
        let providers = LLMConfiguration.Provider.allCases
        return providers.indices.contains(index) ? providers[index] : .zai
    }

    private func fill(modelChoices models: [String]) {
        isPopulating = true
        gtk_string_list_splice(modelList, 0,
                               g_list_model_get_n_items(opaque(modelList)), nil)
        for model in models { gtk_string_list_append(modelList, model) }
        // Point the picker at the model already in the field when the provider
        // lists it. When it does not — a custom name, or a provider just
        // switched — the picker shows nothing rather than defaulting to the
        // first row, which would claim a model the user never chose.
        let current = text(of: modelEntry)
        let selection = models.firstIndex(of: current).map(UInt32.init) ?? Self.noSelection
        gtk_drop_down_set_selected(opaque(self.modelChoices), selection)
        UI.setVisible(modelChoicesRow, true)
        isPopulating = false
    }

    /// `GTK_INVALID_LIST_POSITION`, which is a macro and so does not reach
    /// Swift: the "no row is selected" value for a `GtkDropDown`.
    private static let noSelection = UInt32.max

    private func clearModelChoices() {
        gtk_string_list_splice(modelList, 0,
                               g_list_model_get_n_items(opaque(modelList)), nil)
        UI.setVisible(modelChoicesRow, false)
    }

    // MARK: - Status

    private enum StatusKind { case plain, success, failure }

    private func show(status: String, kind: StatusKind) {
        UI.setText(statusLabel, status)
        gtk_widget_remove_css_class(statusLabel, "error")
        gtk_widget_remove_css_class(statusLabel, "success")
        switch kind {
        case .plain: break
        case .success: UI.addClass(statusLabel, "success")
        case .failure: UI.addClass(statusLabel, "error")
        }
        UI.setVisible(statusLabel, !status.isEmpty)
    }

    /// The idle status: whether what is on screen has been written down. A
    /// dialog whose Test button succeeded and whose Save button was never
    /// pressed should not look like it is configured.
    private func refreshStatus() {
        guard !edit.isBusy else { return }
        let dirty = currentConfiguration() != savedConfiguration
            || currentAPIKey() != savedAPIKey
        show(status: dirty ? "Unsaved changes." : "", kind: .plain)
    }

    private func setBusy(_ busy: Bool) {
        if busy { edit.beginOperation() } else { edit.endOperation() }
        syncButtons()
    }

    /// Mirrors the busy flag onto the controls. Separate from `setBusy` so a
    /// new presentation, which clears the flag itself, can re-enable buttons
    /// that an abandoned operation left disabled.
    private func syncButtons() {
        let busy = edit.isBusy
        for button in [saveButton, loadModelsButton, testButton] {
            gtk_widget_set_sensitive(button, busy ? 0 : 1)
        }
        UI.setVisible(spinner, busy)
        if busy {
            gtk_spinner_start(opaque(spinner))
        } else {
            gtk_spinner_stop(opaque(spinner))
        }
    }

    // MARK: - Editable helpers

    private func text(of editable: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let value = gtk_editable_get_text(opaque(editable)) else {
            return ""
        }
        return String(cString: value)
    }

    private func setText(_ editable: UnsafeMutablePointer<GtkWidget>, _ value: String) {
        gtk_editable_set_text(opaque(editable), value)
    }

    /// A `GtkDropDown` over a fixed list of strings. The `_from_strings`
    /// constructor wants a NULL-terminated `char **`, which Swift will not hand
    /// over from a `[String]`; building the string list explicitly avoids the
    /// manual `strdup` dance and reads as what it is.
    private static func dropDown(_ items: [String]) -> UnsafeMutablePointer<GtkWidget> {
        let list = require(gtk_string_list_new(nil), "string list")
        for item in items { gtk_string_list_append(list, item) }
        return require(gtk_drop_down_new(opaque(list), nil), "drop down")
    }

    // MARK: - Test fixture

    private static let sampleDiffStat = """
         Sources/App.swift | 2 +-
         1 file changed, 1 insertion(+), 1 deletion(-)
        """

    private static let sampleDiff = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1 +1 @@
        -let version = 1
        +let version = 2
        """
}
