import Foundation
import Observation

/// An inclusive row range in PostgREST's `.range(from:to:)` convention
/// (`Range: 0-49` = the first 50 rows).
public struct PageRange: Sendable, Equatable, Hashable {
    /// First row index (0-based, inclusive).
    public let from: Int
    /// Last row index (inclusive).
    public let to: Int

    public init(from: Int, to: Int) {
        self.from = from
        self.to = to
    }

    /// `from` as an SQL-style offset.
    public var offset: Int { from }
    /// Number of rows requested.
    public var limit: Int { to - from + 1 }
}

/// Page arithmetic for a list of `totalItems` rows shown `pageSize` at a time,
/// with a 0-based `page`. Replaces the inline math in Stokked's and Nassau's
/// `PaginationBar`, fixing their edge cases: an empty list is "page 1 of 1"
/// showing "0–0 of 0" (Stokked said "page 1 of 0" and "1–0 of 0"), and a page
/// beyond the end is clamped to the last page (e.g. after deleting rows).
public struct PageMath: Sendable, Equatable, Hashable {
    public let totalItems: Int
    public let pageSize: Int
    /// The current page, 0-based, always within `0..<totalPages`.
    public let page: Int

    /// - Parameters:
    ///   - page: requested 0-based page; clamped into range.
    ///   - totalItems: total row count (negative → 0).
    ///   - pageSize: rows per page (< 1 → 1).
    public init(page: Int, totalItems: Int, pageSize: Int) {
        let size = max(1, pageSize)
        let total = max(0, totalItems)
        let pages = max(1, (total + size - 1) / size)
        self.pageSize = size
        self.totalItems = total
        self.page = min(max(0, page), pages - 1)
    }

    /// At least 1, so an empty list still has one (empty) page.
    public var totalPages: Int { max(1, (totalItems + pageSize - 1) / pageSize) }

    /// 1-based index of the first row on this page, or 0 when the list is empty.
    public var firstItem: Int { totalItems == 0 ? 0 : page * pageSize + 1 }

    /// 1-based index of the last row on this page, or 0 when the list is empty.
    public var lastItem: Int { min((page + 1) * pageSize, totalItems) }

    /// Rows on this page.
    public var itemsOnPage: Int { totalItems == 0 ? 0 : lastItem - firstItem + 1 }

    public var hasPrevious: Bool { page > 0 }
    public var hasNext: Bool { page < totalPages - 1 }
    public var isFirstPage: Bool { !hasPrevious }
    public var isLastPage: Bool { !hasNext }

    /// The PostgREST range to request for this page (always `pageSize` wide;
    /// the server returns fewer rows on the last page).
    public var range: PageRange { PageRange(from: page * pageSize, to: (page + 1) * pageSize - 1) }

    /// The same list on another page (clamped).
    public func moved(to page: Int) -> PageMath {
        PageMath(page: page, totalItems: totalItems, pageSize: pageSize)
    }

    /// The same page position with a new total (clamped) — e.g. after a delete.
    public func withTotal(_ totalItems: Int) -> PageMath {
        PageMath(page: page, totalItems: totalItems, pageSize: pageSize)
    }

    /// The page that contains a 0-based row index.
    public static func page(containing index: Int, pageSize: Int) -> Int {
        max(0, index) / max(1, pageSize)
    }
}

/// One page of results from the app's backend.
public struct PageResult<Item> {
    public var items: [Item]
    /// Total matching rows (e.g. PostgREST `count: .exact`).
    public var totalCount: Int

    public init(items: [Item], totalCount: Int) {
        self.items = items
        self.totalCount = totalCount
    }
}

extension PageResult: Sendable where Item: Sendable {}

/// A paged, searchable list backed by a closure — the model behind a
/// users / records table with a `SearchField` and a `PaginationBar`.
///
/// ```swift
/// @State private var users = PagedList<AdminUser>(pageSize: 50) { request in
///     let response: PostgrestResponse<[AdminUser]> = try await client.from("profiles")
///         .select("*", count: .exact)
///         .ilike("email", pattern: "%\(request.query)%")
///         .order("created_at", ascending: false).order("id")
///         .range(from: request.range.from, to: request.range.to)
///         .execute()
///     return PageResult(items: response.value, totalCount: response.count ?? 0)
/// }
/// ```
///
/// Responses that arrive after a newer request (fast typing, quick paging)
/// are discarded, so the list never shows a stale page.
@MainActor
@Observable
public final class PagedList<Item> {
    /// What the loader is asked for.
    public struct Request: Sendable, Equatable {
        public let range: PageRange
        public let page: Int
        public let pageSize: Int
        /// The current search text, trimmed.
        public let query: String
    }

    public typealias Loader = @MainActor (Request) async throws -> PageResult<Item>

    public private(set) var items: [Item] = []
    public private(set) var math: PageMath
    public private(set) var isLoading = false
    public private(set) var error: Error?
    /// Search text; call `search(_:)` to change it and reload from page 1.
    public private(set) var query = ""

    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private var generation = 0

    public init(pageSize: Int = 50, loader: @escaping Loader) {
        self.math = PageMath(page: 0, totalItems: 0, pageSize: pageSize)
        self.loader = loader
    }

    /// Reload the current page.
    public func reload() async { await load(page: math.page) }

    /// Go to a page (clamped to the last known page) and load it.
    public func go(to page: Int) async { await load(page: math.moved(to: page).page) }

    public func next() async { if math.hasNext { await go(to: math.page + 1) } }
    public func previous() async { if math.hasPrevious { await go(to: math.page - 1) } }

    /// Set the search text and load page 1.
    public func search(_ text: String) async {
        query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        await load(page: 0)
    }

    private func load(page: Int) async {
        generation += 1
        let token = generation
        let size = math.pageSize
        let request = Request(
            range: PageRange(from: page * size, to: (page + 1) * size - 1),
            page: page, pageSize: size, query: query
        )
        isLoading = true
        do {
            let result = try await loader(request)
            guard token == generation else { return }
            let landed = PageMath(page: page, totalItems: result.totalCount, pageSize: size)
            math = landed
            items = result.items
            error = nil
            isLoading = false
            // The page vanished (rows deleted since the count): show the new last page.
            if landed.page != page { await load(page: landed.page) }
        } catch {
            guard token == generation else { return }
            self.error = error
            isLoading = false
        }
    }
}

/// Fetch every row by paging until the backend returns an empty page.
///
/// PostgREST silently caps un-ranged selects at the server's max-rows (1000 by
/// default), so exports and analytics must page. This is Stokked Wholesale's
/// `fetchAllRows` semantics: it advances by the number of rows *actually
/// returned*, so it stays correct when max-rows is below `pageSize` (Nassau's
/// stop-on-short-page variant would silently truncate there).
///
/// `fetchPage` must build a fresh query per call (the Supabase builders mutate
/// in place) with a deterministic order including a unique tiebreaker (`id`),
/// and apply `.range(from: range.from, to: range.to)`.
///
/// - Parameter maxPages: safety stop against a backend that ignores the range.
public func fetchAllPages<T>(
    pageSize: Int = 1000,
    maxPages: Int = 10_000,
    isolation: isolated (any Actor)? = #isolation,
    _ fetchPage: (_ range: PageRange) async throws -> [T]
) async throws -> [T] {
    let size = max(1, pageSize)
    var all: [T] = []
    var offset = 0
    for _ in 0..<max(1, maxPages) {
        let page = try await fetchPage(PageRange(from: offset, to: offset + size - 1))
        if page.isEmpty { break }
        all.append(contentsOf: page)
        offset += page.count
    }
    return all
}
