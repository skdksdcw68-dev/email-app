import SwiftUI
import Supabase
import UIKit

/// Email and password, through Supabase Auth.
///
/// The project requires email confirmation, so signing up does not return a
/// session -- there is nothing to sign in with until the link is opened. That
/// case shows a "check your inbox" state rather than pretending it worked.
struct EmailAuthView: View {
    let mode: AccountView.Mode

    @Environment(UserStore.self) private var user
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var awaitingConfirmation = false

    private var canSubmit: Bool {
        email.contains("@") && !email.hasSuffix("@") && password.count >= 6 && !isWorking
    }

    var body: some View {
        NavigationStack {
            Form {
                if awaitingConfirmation {
                    confirmation
                } else {
                    fields
                }
            }
            .navigationTitle(mode == .create ? "Create account" : "Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(awaitingConfirmation ? "Done" : "Cancel") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        Section {
            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            SecureField("Password", text: $password)
                .textContentType(mode == .create ? .newPassword : .password)
        } footer: {
            if let error {
                Text(error).foregroundStyle(.red)
            } else if mode == .create {
                Text("At least 6 characters.")
            }
        }

        Section {
            Button {
                submit()
            } label: {
                Group {
                    if isWorking {
                        ProgressView()
                    } else {
                        Text(mode == .create ? "Create account" : "Sign in")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 26)
            }
            .disabled(!canSubmit)
        }
    }

    private var confirmation: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("Check your inbox")
                    .font(.headline)
                Text("We sent a confirmation link to \(email). Open it, then sign in.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }

    private func submit() {
        error = nil
        isWorking = true
        Task {
            do {
                if mode == .create {
                    if let supabaseUser = try await AuthService.signUpWithEmail(email, password: password) {
                        finish(supabaseUser)
                    } else {
                        awaitingConfirmation = true
                    }
                } else {
                    finish(try await AuthService.signInWithEmail(email, password: password))
                }
            } catch {
                self.error = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func finish(_ supabaseUser: User) {
        user.completeSignIn(
            userID: supabaseUser.id.uuidString,
            email: supabaseUser.email ?? email,
            displayName: supabaseUser.displayNameFromMetadata,
            provider: .email
        )
        dismiss()
    }
}

#Preview {
    EmailAuthView(mode: .create)
        .environment(UserStore(defaults: .previews, startAt: .createAccount))
}
