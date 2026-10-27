import Foundation
import SwiftUI

// MARK: - Gate protocol

/// Decides whether the signed-in user may use the admin app. UI gating only —
/// every privileged call must be re-checked server-side (RLS `is_admin()` /
/// role policies, or an admin-bearer check in the API), as ThenCam does.
public protocol AdminGate: Sendable {
    /// `true` if the current session belongs to an admin. Throw for "couldn't
    /// tell" (network, expired session) so the gate can offer Retry rather
    /// than a misleading "not authorized".
    func verifyAdmin() async throws -> Bool
}

/// An `AdminGate` from a closure — e.g. Nassau / Stokked / Carpe Vitem
/// reading `profiles.is_admin`, Contrarian reading `profiles.role`, Ariman
/// querying `staff_roles`.
public struct ClosureAdminGate: AdminGate {
    private let check: @Sendable () async throws -> Bool

    public init(_ check: @escaping @Sendable () async throws -> Bool) {
        self.check = check
    }

    public func verifyAdmin() async throws -> Bool { try await check() }
}

/// The recommended model (see README): admin = `app_metadata.role` in the
/// user's access token. `app_metadata` is writable only with the service
/// role, so a user can't grant it to themselves, and the claim travels in
/// every JWT, so neither the client nor RLS needs a table lookup
/// (`(auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'`).
///
/// The token is decoded, **not verified** — fine for gating UI, since the
/// server verifies the same token on every request.
public struct AppMetadataRoleGate: AdminGate {
    private let accessToken: @Sendable () async throws -> String?
    public let roles: Set<String>

    /// - Parameters:
    ///   - roles: accepted `app_metadata.role` values. Default `["admin"]`.
    ///   - accessToken: the current session's access token (`nil` = signed out).
    public init(roles: Set<String> = ["admin"], accessToken: @escaping @Sendable () async throws -> String?) {
        self.roles = roles
        self.accessToken = accessToken
    }

    public func verifyAdmin() async throws -> Bool {
        guard let token = try await accessToken(), let role = JWTClaims(token: token)?.appMetadataRole else {
            return false
        }
        return roles.contains(role)
    }
}

/// Minimal, unverified JWT payload reader (base64url JSON).
public struct JWTClaims: Sendable {
    public let payload: [String: any Sendable]

    public init?(token: String) {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let data = Self.base64URLDecode(String(parts[1])),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        payload = object.mapValues { Self.sendable($0) }
    }

    /// Top-level `role` — the Postgres role (`authenticated`, `service_role`, `anon`).
    public var postgresRole: String? { payload["role"] as? String }
    /// `app_metadata.role` — the app-level role set with the service key.
    public var appMetadataRole: String? { (payload["app_metadata"] as? [String: any Sendable])?["role"] as? String }
    public var subject: String? { payload["sub"] as? String }
    public var email: String? { payload["email"] as? String }
    public var expiresAt: Date? { (payload["exp"] as? Double).map(Date.init(timeIntervalSince1970:)) }

    /// `true` for a `service_role` key — which must never ship in an app.
    public var isServiceRole: Bool { postgresRole == "service_role" }

    static func base64URLDecode(_ string: String) -> Data? {
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }

    private static func sendable(_ value: Any) -> any Sendable {
        switch value {
        case let dict as [String: Any]: return dict.mapValues { sendable($0) }
        case let array as [Any]: return array.map { sendable($0) }
        case let number as NSNumber:
            // JSONSerialization booleans are NSNumber too.
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? number.boolValue as any Sendable : number.doubleValue
        case let string as String: return string
        default: return String(describing: value)
        }
    }
}

// MARK: - Login view

/// Email + password sign-in for an admin app (Nassau's `AdminLoginView`,
/// generalized): the app supplies the backend call; a thrown error's
/// `localizedDescription` is shown under the form.
public struct AdminLoginView: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let onSignIn: @MainActor (_ email: String, _ password: String) async throws -> Void

    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    public init(
        _ title: LocalizedStringKey = "Admin",
        subtitle: LocalizedStringKey = "Sign in with your admin account",
        systemImage: String = "lock.shield",
        tint: Color = .accentColor,
        onSignIn: @escaping @MainActor (_ email: String, _ password: String) async throws -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.onSignIn = onSignIn
    }

    public var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 56))
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title).font(.largeTitle).fontWeight(.bold)
                Text(subtitle).foregroundStyle(.secondary)
            }
            VStack(spacing: 14) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.password)
                if let errorMessage {
                    Text(verbatim: errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
                Button(action: signIn) {
                    ZStack {
                        Text("Sign In").fontWeight(.semibold).opacity(isLoading ? 0 : 1)
                        if isLoading { ProgressView().controlSize(.small) }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit)
            }
            .frame(maxWidth: 300)
            Spacer()
            Spacer()
        }
        .padding()
        .frame(minWidth: 420, minHeight: 500)
        .onSubmit(signIn)
    }

    /// One guard for the button and Return, so Return can't bypass it.
    private var canSubmit: Bool {
        !email.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty && !isLoading
    }

    private func signIn() {
        guard canSubmit else { return }
        isLoading = true
        errorMessage = nil
        let email = email.trimmingCharacters(in: .whitespaces)
        let password = password
        Task {
            do {
                try await onSignIn(email, password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

// MARK: - Gate view

/// The outcome of an `AdminGate` check.
public enum AdminGateState: Equatable, Sendable {
    case checking
    case admin
    case notAdmin
    case failed(String)
}

/// Shows `content` only once `gate.verifyAdmin()` returns `true`; otherwise a
/// "not authorized" screen (with Sign Out) or a Retry on failure. Re-checks
/// whenever `sessionID` changes (pass the user ID / access token).
///
/// ```swift
/// if session.isSignedIn {
///     AdminGateView(gate: AppMetadataRoleGate { session.accessToken },
///                   sessionID: session.userID, onSignOut: { await session.signOut() }) {
///         AdminShell(…)
///     }
/// } else {
///     AdminLoginView("Nassau Admin") { try await session.signIn(email: $0, password: $1) }
/// }
/// ```
public struct AdminGateView<Content: View>: View {
    let gate: any AdminGate
    let sessionID: AnyHashable?
    let onSignOut: (@MainActor () async -> Void)?
    let content: Content

    @State private var state: AdminGateState = .checking

    public init(
        gate: any AdminGate,
        sessionID: AnyHashable? = nil,
        onSignOut: (@MainActor () async -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.gate = gate
        self.sessionID = sessionID
        self.onSignOut = onSignOut
        self.content = content()
    }

    public var body: some View {
        Group {
            switch state {
            case .checking:
                ProgressView("Checking access…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .admin:
                content
            case .notAdmin:
                EmptyState(
                    "Not authorized",
                    systemImage: "lock.slash",
                    message: Text("This account doesn't have admin access."),
                    actionTitle: onSignOut == nil ? nil : "Sign Out",
                    action: onSignOut.map { signOut in { Task { await signOut() } } }
                )
            case .failed(let message):
                EmptyState(
                    "Couldn't verify access",
                    systemImage: "exclamationmark.triangle",
                    message: Text(verbatim: message),
                    actionTitle: "Retry",
                    action: { Task { await check() } }
                )
            }
        }
        .task(id: sessionID) { await check() }
    }

    private func check() async {
        state = .checking
        state = await Self.evaluate(gate)
    }

    /// The gate's verdict as a state (exposed for tests).
    static func evaluate(_ gate: any AdminGate) async -> AdminGateState {
        do {
            return try await gate.verifyAdmin() ? .admin : .notAdmin
        } catch is CancellationError {
            return .checking
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Public entry to the same evaluation the gate view uses.
public func evaluateAdminGate(_ gate: any AdminGate) async -> AdminGateState {
    await AdminGateView<EmptyView>.evaluate(gate)
}
