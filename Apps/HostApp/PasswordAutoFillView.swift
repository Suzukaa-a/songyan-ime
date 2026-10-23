import AuthenticationServices
import SwiftUI

// MARK: - Settings request mirror

@MainActor
final class PasswordAutoFillModel: ObservableObject {
    typealias Completion = @Sendable (Error?) -> Void
    typealias OpenSettings = @MainActor (@escaping Completion) -> Void

    @Published private(set) var isBusy = false
    @Published var error: String?

    private let openSettings: OpenSettings
    private var isActive = false
    private var generation = 0
    private var pendingRequest: Task<Void, Never>?

    init(openSettings: @escaping OpenSettings) {
        self.openSettings = openSettings
    }

    func activate() { isActive = true }

    func deactivate() {
        isActive = false
        generation += 1
        // This cancels result publication, not a navigation already sent to iOS.
        pendingRequest?.cancel()
        pendingRequest = nil
        isBusy = false
        error = nil
    }

    @discardableResult
    func openAutoFillSettings() -> Task<Void, Never>? {
        guard isActive, !isBusy else { return nil }
        isBusy = true
        error = nil
        generation += 1
        let generation = self.generation
        let openSettings = self.openSettings
        let task = Task { [weak self] in
            guard !Task.isCancelled, self?.isActive == true,
                self?.generation == generation
            else { return }
            let result: Error? = await withCheckedContinuation { continuation in
                openSettings { continuation.resume(returning: $0) }
            }
            guard !Task.isCancelled, let self, self.isActive,
                self.generation == generation
            else { return }
            self.pendingRequest = nil
            self.isBusy = false
            if let result { self.error = "无法打开密码自动填充设置：\(result.localizedDescription)" }
        }
        pendingRequest = task
        return task
    }
}

// MARK: - Native AutoFill view

@MainActor
struct PasswordAutoFillView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = PasswordAutoFillModel { completion in
        ASSettingsHelper.openCredentialProviderAppSettings(completionHandler: completion)
    }
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        List {
            Section {
                Button {
                    model.openAutoFillSettings()
                } label: {
                    HStack {
                        Label("密码自动填充设置", systemImage: "key")
                        Spacer()
                        if model.isBusy { ProgressView() }
                    }
                }
                .disabled(model.isBusy)
            }
            Section("临时填写") {
                TextField("用户名", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
                    .textContentType(.password)
            }
            Section("官方帮助") {
                Link(destination: URL(string: "https://support.1password.com/ios-autofill/")!) {
                    Label("1Password", systemImage: "arrow.up.right.square")
                }
                Link(destination: URL(string: "https://bitwarden.com/help/auto-fill-ios/")!) {
                    Label("Bitwarden", systemImage: "arrow.up.right.square")
                }
            }
        }
        .navigationTitle("密码自动填充")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    clearFields()
                } label: {
                    Label("清空填写内容", systemImage: "trash")
                }
                .disabled(username.isEmpty && password.isEmpty)
            }
        }
        .onAppear { model.activate() }
        .onDisappear {
            clearFields()
            model.deactivate()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.activate()
            } else if phase == .background {
                clearFields()
                model.deactivate()
            }
        }
        .alert("密码自动填充", isPresented: errorBinding) {
            Button("好", role: .cancel) { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
    }

    private func clearFields() {
        username = ""
        password = ""
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
    }
}
