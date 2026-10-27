import SwiftUI

/// A sidebar destination. Typically an app-side enum:
///
/// ```swift
/// enum Section: String, AdminSection, CaseIterable {
///     case dashboard, users, wines, analytics
///     var title: LocalizedStringKey { … }
///     var systemImage: String { … }
///     var group: String? { self == .dashboard || self == .analytics ? "Overview" : "Data" }
/// }
/// ```
public protocol AdminSection: Hashable, Identifiable {
    var title: LocalizedStringKey { get }
    var systemImage: String { get }
    /// Sidebar group heading (a localization key). Sections are grouped in
    /// first-appearance order; `nil` puts a section in an unnamed group.
    var group: String? { get }
}

extension AdminSection {
    public var group: String? { nil }
}

extension AdminSection where Self: RawRepresentable, RawValue == String {
    public var id: String { rawValue }
}

/// The signed-in admin shown at the bottom of the sidebar.
public struct AdminAccount: Sendable, Equatable {
    public var email: String?
    public var role: String?

    public init(email: String?, role: String? = nil) {
        self.email = email
        self.role = role
    }
}

/// `NavigationSplitView` scaffold shared by the admin apps (the structure of
/// Jeroboam's `AdminMainView`/`AdminSidebarView` and Carpe Vitem's
/// `AdminSidebarView`): grouped sidebar of app-supplied sections, the selected
/// section's view in the detail column, and an account footer with Sign Out.
///
/// ```swift
/// AdminShell(sections: Section.allCases, selection: $section,
///            account: AdminAccount(email: session.email), onSignOut: { await session.signOut() }) { section in
///     switch section { case .dashboard: DashboardView() … }
/// }
/// ```
///
/// A section that needs its own list/detail split can host a nested
/// `NavigationSplitView` or `HSplitView` in its view.
public struct AdminShell<Destination: AdminSection, Detail: View>: View {
    let title: LocalizedStringKey
    let sections: [Destination]
    @Binding var selection: Destination?
    let account: AdminAccount?
    let onSignOut: (@MainActor () async -> Void)?
    let detail: (Destination) -> Detail

    @State private var signingOut = false

    public init(
        _ title: LocalizedStringKey = "Admin",
        sections: [Destination],
        selection: Binding<Destination?>,
        account: AdminAccount? = nil,
        onSignOut: (@MainActor () async -> Void)? = nil,
        @ViewBuilder detail: @escaping (Destination) -> Detail
    ) {
        self.title = title
        self.sections = sections
        self._selection = selection
        self.account = account
        self.onSignOut = onSignOut
        self.detail = detail
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Array(AdminSectionGrouping.groups(sections, key: \.group).enumerated()), id: \.offset) { _, group in
                    if let heading = group.first?.group {
                        SwiftUI.Section(LocalizedStringKey(heading)) { rows(group) }
                    } else {
                        rows(group)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .navigationTitle(title)
            .safeAreaInset(edge: .bottom) { footer }
        } detail: {
            if let selection {
                detail(selection)
            } else {
                EmptyState("Select a section", systemImage: "sidebar.left")
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            if selection == nil { selection = sections.first }
        }
    }

    private func rows(_ group: [Destination]) -> some View {
        ForEach(group) { section in
            Label(section.title, systemImage: section.systemImage).tag(section)
        }
    }

    @ViewBuilder
    private var footer: some View {
        if account != nil || onSignOut != nil {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        if let email = account?.email {
                            Text(verbatim: email).font(.caption).lineLimit(1).truncationMode(.middle)
                        }
                        if let role = account?.role {
                            Text(verbatim: role).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if let onSignOut {
                        Button {
                            signingOut = true
                            Task {
                                await onSignOut()
                                signingOut = false
                            }
                        } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                        }
                        .buttonStyle(.borderless)
                        .disabled(signingOut)
                        .help(Text("Sign Out"))
                        .accessibilityLabel(Text("Sign Out"))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
        }
    }
}

enum AdminSectionGrouping {
    /// Groups in first-appearance order, preserving order within a group.
    static func groups<Item, Key: Hashable>(_ items: [Item], key: (Item) -> Key) -> [[Item]] {
        var order: [Key] = []
        var buckets: [Key: [Item]] = [:]
        for item in items {
            let k = key(item)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append(item)
        }
        return order.compactMap { buckets[$0] }
    }
}
