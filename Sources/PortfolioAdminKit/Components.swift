import Charts
import SwiftUI

// Reusable admin components, lifted from Nassau's `Views/Components.swift`
// (MetricCard, ChartCard, ActivityStat, StatusBadge, SearchField,
// PaginationBar) and Stokked Wholesale's `PaginationBar`.

// MARK: - Metric card

/// A KPI tile: icon, big value, caption — optionally a secondary line
/// (e.g. "+12 this week").
public struct MetricCard: View {
    let title: LocalizedStringKey
    let value: String
    let systemImage: String
    let color: Color
    let detail: String?

    public init(_ title: LocalizedStringKey, value: String, systemImage: String, color: Color = .accentColor, detail: String? = nil) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.color = color
        self.detail = detail
    }

    /// Integer value, formatted with grouping separators.
    public init(_ title: LocalizedStringKey, value: Int, systemImage: String, color: Color = .accentColor, detail: String? = nil) {
        self.init(title, value: value.formatted(), systemImage: systemImage, color: color, detail: detail)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(verbatim: value)
                .font(.title)
                .fontWeight(.bold)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let detail {
                Text(verbatim: detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Activity stat

/// A centered count tile (Nassau's activity row).
public struct ActivityStat: View {
    let title: LocalizedStringKey
    let value: Int
    let systemImage: String

    public init(_ title: LocalizedStringKey, value: Int, systemImage: String) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(value, format: .number)
                .font(.title)
                .fontWeight(.bold)
                .monospacedDigit()
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Chart card

/// A titled card that hosts a Swift Charts chart (or any view) at a fixed height.
public struct ChartCard<Content: View>: View {
    let title: LocalizedStringKey
    let subtitle: String?
    let height: CGFloat
    let content: Content

    public init(_ title: LocalizedStringKey, subtitle: String? = nil, height: CGFloat = 200, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.height = height
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content.frame(height: height)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One point of a dated series (signups per day, rounds per week, …).
public struct TimeSeriesPoint: Identifiable, Sendable, Hashable {
    public var date: Date
    public var value: Double
    public var id: Date { date }

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

/// The common admin dashboard chart: one dated series as bars or a line.
public struct TimeSeriesChart: View {
    public enum Style: Sendable { case bar, line }

    let points: [TimeSeriesPoint]
    let style: Style
    let unit: Calendar.Component
    let valueLabel: LocalizedStringKey
    let color: Color

    public init(
        _ points: [TimeSeriesPoint],
        style: Style = .bar,
        unit: Calendar.Component = .day,
        valueLabel: LocalizedStringKey = "Count",
        color: Color = .accentColor
    ) {
        self.points = points
        self.style = style
        self.unit = unit
        self.valueLabel = valueLabel
        self.color = color
    }

    public var body: some View {
        if points.isEmpty {
            EmptyState("No data", systemImage: "chart.bar.xaxis")
        } else {
            Chart(points) { point in
                switch style {
                case .bar:
                    BarMark(x: .value("Date", point.date, unit: unit), y: .value(valueLabel, point.value))
                        .foregroundStyle(color)
                case .line:
                    LineMark(x: .value("Date", point.date, unit: unit), y: .value(valueLabel, point.value))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
            }
        }
    }
}

// MARK: - Status badge

/// A tinted capsule label ("Admin", "Active", "Expired").
public struct StatusBadge: View {
    let text: LocalizedStringKey
    let color: Color
    let systemImage: String?

    public init(_ text: LocalizedStringKey, color: Color, systemImage: String? = nil) {
        self.text = text
        self.color = color
        self.systemImage = systemImage
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.caption2)
            }
            Text(text)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}

// MARK: - Search field

/// An inline search box with a clear button. For a toolbar search use
/// `.searchable`; this is for a filter row above a table.
public struct SearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    let onSubmit: (() -> Void)?

    public init(text: Binding<String>, prompt: LocalizedStringKey = "Search", onSubmit: (() -> Void)? = nil) {
        self._text = text
        self.prompt = prompt
        self.onSubmit = onSubmit
    }

    public var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .onSubmit { onSubmit?() }
            if !text.isEmpty {
                Button {
                    text = ""
                    onSubmit?()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Pagination bar

/// "Showing 51–100 of 734 · ‹‹ ‹ Page 2 of 15 › ››", driven by `PageMath`.
public struct PaginationBar: View {
    let math: PageMath
    let onPageChange: (Int) -> Void

    public init(_ math: PageMath, onPageChange: @escaping (Int) -> Void) {
        self.math = math
        self.onPageChange = onPageChange
    }

    /// Drop-in for the Stokked / Nassau signature.
    public init(currentPage: Int, totalItems: Int, pageSize: Int, onPageChange: @escaping (Int) -> Void) {
        self.init(PageMath(page: currentPage, totalItems: totalItems, pageSize: pageSize), onPageChange: onPageChange)
    }

    public var body: some View {
        HStack {
            Text("Showing \(math.firstItem)–\(math.lastItem) of \(math.totalItems)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Spacer()

            HStack(spacing: 8) {
                pageButton("chevron.backward.2", "First page", to: 0, enabled: math.hasPrevious)
                pageButton("chevron.backward", "Previous page", to: math.page - 1, enabled: math.hasPrevious)
                Text("Page \(math.page + 1) of \(math.totalPages)")
                    .font(.caption)
                    .monospacedDigit()
                pageButton("chevron.forward", "Next page", to: math.page + 1, enabled: math.hasNext)
                pageButton("chevron.forward.2", "Last page", to: math.totalPages - 1, enabled: math.hasNext)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func pageButton(_ systemImage: String, _ label: LocalizedStringKey, to page: Int, enabled: Bool) -> some View {
        Button { onPageChange(page) } label: { Image(systemName: systemImage) }
            .disabled(!enabled)
            .accessibilityLabel(Text(label))
    }
}

extension PaginationBar {
    /// A bar bound to a `PagedList`.
    public init<Item>(_ list: PagedList<Item>) {
        self.init(list.math) { page in Task { await list.go(to: page) } }
    }
}

// MARK: - Empty state

/// "Nothing here" placeholder with an optional action, over `ContentUnavailableView`.
public struct EmptyState: View {
    let title: LocalizedStringKey
    let systemImage: String
    let message: Text?
    let actionTitle: LocalizedStringKey?
    let action: (() -> Void)?

    public init(
        _ title: LocalizedStringKey,
        systemImage: String,
        message: Text? = nil,
        actionTitle: LocalizedStringKey? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    /// A load failure with a Retry button.
    public static func error(_ error: Error, retry: (() -> Void)? = nil) -> EmptyState {
        EmptyState(
            "Couldn't load",
            systemImage: "exclamationmark.triangle",
            message: Text(verbatim: error.localizedDescription),
            actionTitle: retry == nil ? nil : "Retry",
            action: retry
        )
    }

    public var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { message }
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
    }
}
