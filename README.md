# PortfolioAdminKit

Shared SwiftUI building blocks for the portfolio's internal **macOS admin
apps** — Stokked Wholesale, Nassau Admin, MacJeroboamAdmin, Carpe Vitem
`cd_internal`, ThenCam Admin, Contrarian MacAdmin (and Otta's). Each of them
had re-implemented the same pagination bar, metric cards, login form, admin
check and sidebar.

- macOS 14+, Swift 6 (swift-tools 6.0), SwiftUI + Swift Charts.
- **No external dependencies and no backend.** Data arrives through closures
  (`PagedList`, `fetchAllPages`, `AdminLoginView(onSignIn:)`) and the
  `AdminGate` protocol, so each app keeps its own Supabase client / API and its
  own role model.

## API

### Scaffold

```swift
enum Section: String, AdminSection, CaseIterable {
    case dashboard, users, wines, analytics
    var title: LocalizedStringKey { LocalizedStringKey(rawValue.capitalized) }
    var systemImage: String { … }
    var group: String? { self == .dashboard || self == .analytics ? "Overview" : "Data" }
}

@State private var section: Section? = .dashboard

var body: some View {
    if session.isSignedIn {
        AdminGateView(gate: AppMetadataRoleGate { await session.accessToken },
                      sessionID: session.userID,
                      onSignOut: { await session.signOut() }) {
            AdminShell("Nassau Admin", sections: Section.allCases, selection: $section,
                       account: AdminAccount(email: session.email, role: "admin"),
                       onSignOut: { await session.signOut() }) { section in
                switch section {
                case .dashboard: DashboardView()
                …
                }
            }
        }
    } else {
        AdminLoginView("Nassau Admin", systemImage: "flag.fill", tint: .green) { email, password in
            try await session.signIn(email: email, password: password)
        }
    }
}
```

| Type | What it is | Replaces |
|---|---|---|
| `AdminShell(sections:selection:account:onSignOut:detail:)` | `NavigationSplitView` with a grouped sidebar of app-supplied `AdminSection`s, detail column, account footer with Sign Out | Jeroboam `AdminMainView` + `AdminSidebarView`, Carpe Vitem `AdminSidebarView` |
| `AdminLoginView(_:subtitle:systemImage:tint:onSignIn:)` | Email + password form; shows the thrown error; Return and the button share one guard | Nassau `AdminLoginView`, Stokked/Carpe Vitem login screens |
| `AdminGate` (`verifyAdmin() async throws -> Bool`) | The admin check, app-supplied | Nassau `AdminService.verifyAdmin`, Stokked/Carpe Vitem `checkAdminStatus` |
| `ClosureAdminGate { … }` | Any check (`is_admin` column, `role` column, `staff_roles` row) | |
| `AppMetadataRoleGate(roles:accessToken:)` | Reads `app_metadata.role` from the access token — the recommended model below | ThenCam `AdminSession.isAdmin` |
| `AdminGateView(gate:sessionID:onSignOut:content:)` | Checking → content / "Not authorized" + Sign Out / "Couldn't verify" + Retry; re-checks when `sessionID` changes | ad-hoc `if isAdmin` branches |
| `JWTClaims(token:)` | Unverified JWT payload reader: `appMetadataRole`, `postgresRole`, `isServiceRole`, `subject`, `email`, `expiresAt` | |

### Components

| View | Notes |
|---|---|
| `MetricCard(_:value:systemImage:color:detail:)` | KPI tile; `value` may be `String` or `Int` (formatted) |
| `ActivityStat(_:value:systemImage:)` | Centered count tile (Nassau) |
| `ChartCard(_:subtitle:height:content:)` | Titled card hosting a chart (default height 200) |
| `TimeSeriesChart(_:style:unit:valueLabel:color:)` | Swift Charts bar/line for `[TimeSeriesPoint]`; empty → `EmptyState` |
| `StatusBadge(_:color:systemImage:)` | Tinted capsule |
| `SearchField(text:prompt:onSubmit:)` | Inline filter box with clear button |
| `PaginationBar(_ math:onPageChange:)` / `PaginationBar(currentPage:totalItems:pageSize:onPageChange:)` / `PaginationBar(list)` | Drop-in for the Stokked/Nassau bar, driven by `PageMath` |
| `EmptyState(_:systemImage:message:actionTitle:action:)`, `EmptyState.error(_:retry:)` | Over `ContentUnavailableView` |

### Paging

```swift
// Page math (pure, tested)
let m = PageMath(page: 2, totalItems: 734, pageSize: 50)
m.totalPages   // 15
m.firstItem    // 101   (0 when the list is empty)
m.lastItem     // 150
m.range        // PageRange(from: 100, to: 149) → .range(from: m.range.from, to: m.range.to)

// A paged, searchable list model
@State private var users = PagedList<AdminUser>(pageSize: 50) { request in
    // request.range, request.page, request.query (trimmed)
    let response: PostgrestResponse<[AdminUser]> = try await client.from("profiles")
        .select("*", count: .exact)
        .order("created_at", ascending: false).order("id")
        .range(from: request.range.from, to: request.range.to)
        .execute()
    return PageResult(items: response.value, totalCount: response.count ?? 0)
}
// .task { await users.reload() }, SearchField(…, onSubmit: { Task { await users.search(text) } }),
// PaginationBar(users)

// Every row, past PostgREST's max-rows cap
let all: [Row] = try await fetchAllPages(pageSize: 1000) { range in
    try await client.from("rounds").select().order("id")
        .range(from: range.from, to: range.to).execute().value
}
```

- `PageMath` fixes the old bars' edge cases: an empty list is "page 1 of 1,
  0–0 of 0" (Stokked's showed "page 1 of 0" and "1–0 of 0"), and a page past
  the end (after deletes) is clamped.
- `PagedList` discards responses that arrive after a newer request (fast
  typing) and, if the current page vanished, reloads the new last page.
- `fetchAllPages` advances by the rows **actually returned** and stops on an
  empty page (Stokked's semantics), so it stays correct when the server's
  max-rows is below `pageSize`; Nassau's stop-on-short-page loop would
  silently truncate there.

### Country flags

```swift
countryFlag("SE")        // 🇸🇪
countryFlag("Sverige")   // 🇸🇪  — English or Swedish names, any region Locale knows
countryFlag("Scotland")  // 🇬🇧  — aliases: UK, USA, England, Holland, …
countryFlag("Atlantis")  // 🌍  (unknownCountryFlag)
countryCode(for: "Finland")  // "FI"
```

Replaces Nassau's `countryFlagEmoji(for:)` (17 hard-coded names).

## Admin role model — recommendation

Common models for "who is an admin":

| Model | Where it's checked |
|---|---|
| `profiles.is_admin` boolean column | client reads the row; RLS calls `is_admin()` (a table lookup per policy) |
| `profiles.role = 'admin'` | client fetches the role; RLS/RPCs look it up |
| `app_metadata.role` JWT claim | in the token; RLS reads `auth.jwt()` |
| separate `staff_roles` table | table lookup |
| **service_role key in the app, no admin check** | nowhere — the key bypasses RLS |

**Recommendation: `auth.users.raw_app_meta_data.role` (`app_metadata.role`),
plus the admin's own user JWT for every request — no service_role key in any
Mac app.**

- **Not user-writable.** `app_metadata` can only be changed with the service
  role (Studio, SQL, an admin edge function). `user_metadata` *is*
  user-writable — never gate on it. A `profiles` column is only safe while a
  trigger blocks self-promotion.
- **In every JWT.** The client can gate the UI without a query
  (`AppMetadataRoleGate`), and policies can check
  `(auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'` without a table lookup
  or a SECURITY DEFINER `is_admin()` helper (no RLS recursion, cheaper).
- **One shape everywhere.** Edge functions/APIs verify the same claim from the
  bearer token.
- Caveat: a role change takes effect on the next token refresh (≤ JWT expiry,
  1 h by default) — revoke by also signing the user out
  (`auth.admin.signOut`) when it matters.

Grant: `update auth.users set raw_app_meta_data = raw_app_meta_data || '{"role":"admin"}' where email = '…';`

### Stop shipping service_role keys in Mac apps

A service_role key bypasses all RLS; anyone who gets the binary (or its
Keychain item) owns the database, and it can't be revoked without rotating
the JWT secret for the whole stack.

Migration path: sign in with the admin's own account → check
`app_metadata.role` (`AppMetadataRoleGate`) → read/write tables through RLS
policies that test the claim → move the few genuinely service-role operations
(`auth.admin.createUser/deleteUser`, cross-user cleanup) into an edge function
that verifies the caller's admin claim, so the key stays on the server.

## Development

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift test --package-path .
```

Consume by git URL + version (`from: "0.1.0"`), never a local path, so Xcode
Cloud can resolve it.

## Changelog

### 0.1.0 (2026-10-27)

Initial release: `AdminShell`, `AdminLoginView`, `AdminGate` /
`ClosureAdminGate` / `AppMetadataRoleGate` / `AdminGateView`, `JWTClaims`,
`MetricCard`, `ActivityStat`, `ChartCard`, `TimeSeriesChart`, `StatusBadge`,
`SearchField`, `PaginationBar`, `EmptyState`, `PageMath`, `PagedList`,
`fetchAllPages`, `countryFlag` / `countryCode`.
