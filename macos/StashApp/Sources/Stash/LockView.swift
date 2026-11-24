import SwiftUI

/// A centered card on the canvas, shared by the lock and create screens.
private struct GateCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack {
            Spacer()
            Card(padding: 36) {
                VStack(spacing: 22) { content }
                    .frame(width: 340)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
    }
}

private struct Brand: View {
    var body: some View {
        VStack(spacing: 14) {
            StashMark(size: 64)
            Wordmark(size: 34)
        }
    }
}

struct LockView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GateCard {
            Brand()
            Text("Unlock your vault")
                .font(.plex(14))
                .foregroundStyle(Color.inkSecondary)

            UnlockForm()

            Text(model.status?.vaultPath ?? "")
                .font(.mono(11))
                .foregroundStyle(Color.inkTertiary)
        }
    }
}

struct UnlockForm: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var password = ""
    @FocusState private var passwordFocused: Bool

    private var touchIDFirst: Bool {
        model.effectiveUnlockMethod == .touchID
    }

    var body: some View {
        VStack(spacing: 14) {
            if touchIDFirst {
                touchIDButton
                    .buttonStyle(PrimaryButtonStyle(wide: true))
                    .keyboardShortcut(password.isEmpty ? .defaultAction : nil)
            }

            HStack(spacing: 8) {
                FieldBox(icon: "lock", mono: false) {
                    SecureField("Master password", text: $password,
                                prompt: Text("Master password").foregroundStyle(Color.inkTertiary))
                        .labelsHidden()
                        .focused($passwordFocused)
                        .onSubmit(submitDefault)
                }
                if touchIDFirst {
                    passwordButton
                        .buttonStyle(SecondaryButtonStyle())
                        .opacity(password.isEmpty ? 0.5 : 1)
                } else {
                    passwordButton.buttonStyle(PrimaryButtonStyle())
                }
            }

            if model.canUseTouchID && !touchIDFirst {
                touchIDButton.buttonStyle(SecondaryButtonStyle())
            }

            if let error = model.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.plex(12.5))
                    .foregroundStyle(Color.danger)
                    .multilineTextAlignment(.center)
            }
        }
        .disabled(model.busy)
        .task { passwordFocused = !model.busy }
        .onChange(of: model.busy) { _, busy in
            if !busy { passwordFocused = true }
        }
    }

    private var touchIDButton: some View {
        Button(action: submitTouchID) {
            Label("Unlock with Touch ID", systemImage: "touchid")
        }
    }

    private var passwordButton: some View {
        Button("Unlock", action: submitPassword)
            .keyboardShortcut(password.isEmpty ? nil : .defaultAction)
            .disabled(password.isEmpty)
    }

    private func submitDefault() {
        if password.isEmpty && touchIDFirst {
            submitTouchID()
        } else {
            submitPassword()
        }
    }

    private func submitTouchID() {
        Task { await model.unlockWithTouchID() }
    }

    private func submitPassword() {
        guard !password.isEmpty, !model.busy else { return }
        let pw = password
        password = ""
        Task { await model.unlock(password: pw) }
    }
}

struct CreateVaultView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var password = ""
    @ViewState private var confirm = ""

    private var problem: String? {
        if password.count < 8 { return String(localized: "Use at least 8 characters. A long passphrase is best.") }
        if password != confirm { return String(localized: "The passwords don't match.") }
        return nil
    }

    var body: some View {
        GateCard {
            Brand()
            VStack(spacing: 6) {
                Text("Create your vault")
                    .font(.plex(18, weight: .semibold))
                    .foregroundStyle(Color.ink)
                Text("Your master password is the one thing stash can't recover, so make it long and memorable.")
                    .font(.plex(13))
                    .foregroundStyle(Color.inkSecondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 10) {
                FieldBox(icon: "lock", mono: false) {
                    SecureField("", text: $password, prompt: Text("Master password").font(.plex(13.5)).foregroundStyle(Color.inkTertiary))
                }
                FieldBox(icon: "lock", mono: false) {
                    SecureField("", text: $confirm, prompt: Text("Confirm master password").font(.plex(13.5)).foregroundStyle(Color.inkTertiary))
                }
            }
            Button("Create Vault") {
                let pw = password
                password = ""
                confirm = ""
                Task { await model.createVault(password: pw) }
            }
            .buttonStyle(PrimaryButtonStyle(wide: true))
            .disabled(problem != nil)
            Text(model.error ?? problem ?? " ")
                .font(.plex(12))
                .foregroundStyle(model.error != nil ? Color.danger : Color.inkTertiary)
                .multilineTextAlignment(.center)
        }
    }
}
