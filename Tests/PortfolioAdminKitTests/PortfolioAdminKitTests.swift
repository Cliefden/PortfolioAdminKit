import Foundation
import Testing
@testable import PortfolioAdminKit

// MARK: - Page math

struct PageMathTests {
    @Test func emptyListIsOnePageOfNothing() {
        let m = PageMath(page: 0, totalItems: 0, pageSize: 50)
        #expect(m.totalPages == 1)
        #expect(m.firstItem == 0 && m.lastItem == 0 && m.itemsOnPage == 0)
        #expect(!m.hasPrevious && !m.hasNext)
        #expect(m.range == PageRange(from: 0, to: 49))
    }

    @Test(arguments: [
        // total, size, page → pages, first, last
        (150, 50, 0, 3, 1, 50),
        (150, 50, 2, 3, 101, 150),
        (151, 50, 3, 4, 151, 151),
        (49, 50, 0, 1, 1, 49),
        (50, 50, 0, 1, 1, 50),
        (51, 50, 1, 2, 51, 51),
        (1, 1, 0, 1, 1, 1),
    ])
    func pages(_ total: Int, _ size: Int, _ page: Int, _ pages: Int, _ first: Int, _ last: Int) {
        let m = PageMath(page: page, totalItems: total, pageSize: size)
        #expect(m.totalPages == pages)
        #expect(m.firstItem == first)
        #expect(m.lastItem == last)
        #expect(m.itemsOnPage == last - first + 1)
    }

    @Test func navigationFlags() {
        let first = PageMath(page: 0, totalItems: 120, pageSize: 50)
        #expect(!first.hasPrevious && first.hasNext && first.isFirstPage && !first.isLastPage)
        let middle = first.moved(to: 1)
        #expect(middle.hasPrevious && middle.hasNext)
        let last = first.moved(to: 2)
        #expect(last.hasPrevious && !last.hasNext && last.isLastPage)
    }

    @Test func clamping() {
        #expect(PageMath(page: 9, totalItems: 120, pageSize: 50).page == 2)
        #expect(PageMath(page: -3, totalItems: 120, pageSize: 50).page == 0)
        #expect(PageMath(page: 4, totalItems: 0, pageSize: 50).page == 0)
        let zeroSize = PageMath(page: 0, totalItems: 3, pageSize: 0)
        #expect(zeroSize.pageSize == 1 && zeroSize.totalPages == 3)
        let negative = PageMath(page: 0, totalItems: -5, pageSize: 10)
        #expect(negative.totalItems == 0 && negative.totalPages == 1)
    }

    @Test func shrinkingTotalClampsToNewLastPage() {
        let m = PageMath(page: 2, totalItems: 150, pageSize: 50)
        let afterDelete = m.withTotal(100)
        #expect(afterDelete.page == 1)
        #expect(afterDelete.firstItem == 51 && afterDelete.lastItem == 100)
    }

    @Test func postgrestRanges() {
        #expect(PageMath(page: 0, totalItems: 500, pageSize: 50).range == PageRange(from: 0, to: 49))
        let r = PageMath(page: 3, totalItems: 500, pageSize: 50).range
        #expect(r == PageRange(from: 150, to: 199))
        #expect(r.offset == 150 && r.limit == 50)
    }

    @Test(arguments: [(0, 50, 0), (49, 50, 0), (50, 50, 1), (999, 100, 9), (-1, 50, 0)])
    func pageContainingIndex(_ index: Int, _ size: Int, _ expected: Int) {
        #expect(PageMath.page(containing: index, pageSize: size) == expected)
    }
}

// MARK: - fetchAllPages

struct FetchAllPagesTests {
    /// A fake table whose server caps every response at `maxRows`.
    struct Table {
        let rows: [Int]
        let maxRows: Int
        func fetch(_ r: PageRange) -> [Int] {
            guard r.from < rows.count else { return [] }
            let end = min(r.to, rows.count - 1, r.from + maxRows - 1)
            return Array(rows[r.from...end])
        }
    }

    @Test(arguments: [0, 1, 999, 1000, 1001, 2500])
    func fetchesEveryRow(_ count: Int) async throws {
        let table = Table(rows: Array(0..<count), maxRows: 1000)
        let all = try await fetchAllPages(pageSize: 1000) { table.fetch($0) }
        #expect(all == table.rows)
    }

    @Test func survivesServerCapBelowPageSize() async throws {
        // max-rows 300 < pageSize 1000: a stop-on-short-page loop would return 300.
        let table = Table(rows: Array(0..<1234), maxRows: 300)
        var requests: [PageRange] = []
        let all = try await fetchAllPages(pageSize: 1000) { range in
            requests.append(range)
            return table.fetch(range)
        }
        #expect(all == table.rows)
        #expect(requests.first == PageRange(from: 0, to: 999))
        #expect(requests[1] == PageRange(from: 300, to: 1299))
    }

    @Test func maxPagesStopsARunawayBackend() async throws {
        let all = try await fetchAllPages(pageSize: 10, maxPages: 3) { _ in [1, 2, 3] }
        #expect(all.count == 9)
    }

    @Test func errorsPropagate() async {
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            _ = try await fetchAllPages(pageSize: 10) { (_: PageRange) -> [Int] in throw Boom() }
        }
    }
}

// MARK: - PagedList

@MainActor
struct PagedListTests {
    final class Backend {
        var rows: [String]
        var requests: [PagedList<String>.Request] = []
        init(_ count: Int) { rows = (0..<count).map { "row\($0)" } }

        func load(_ request: PagedList<String>.Request) -> PageResult<String> {
            requests.append(request)
            let matching = request.query.isEmpty ? rows : rows.filter { $0.contains(request.query) }
            let slice = matching.indices.contains(request.range.from)
                ? Array(matching[request.range.from...min(request.range.to, matching.count - 1)]) : []
            return PageResult(items: slice, totalCount: matching.count)
        }
    }

    @Test func loadsAndPages() async {
        let backend = Backend(120)
        let list = PagedList<String>(pageSize: 50) { backend.load($0) }
        await list.reload()
        #expect(list.items.count == 50 && list.items.first == "row0")
        #expect(list.math.totalItems == 120 && list.math.totalPages == 3)
        await list.next()
        #expect(list.math.page == 1 && list.items.first == "row50")
        await list.go(to: 2)
        #expect(list.items.count == 20)
        await list.next()   // already last: no request
        #expect(backend.requests.count == 3)
        await list.previous()
        #expect(list.math.page == 1)
    }

    @Test func searchResetsToFirstPageAndPassesQuery() async {
        let backend = Backend(120)
        let list = PagedList<String>(pageSize: 10) { backend.load($0) }
        await list.go(to: 0)
        await list.go(to: 3)
        await list.search("  row1  ")
        #expect(backend.requests.last?.query == "row1")
        #expect(backend.requests.last?.page == 0)
        #expect(list.math.page == 0)
        #expect(list.math.totalItems == 31) // row1, row10–19, row100–119
    }

    @Test func pageThatVanishedReloadsLastPage() async {
        let backend = Backend(120)
        let list = PagedList<String>(pageSize: 50) { backend.load($0) }
        await list.reload()
        await list.go(to: 2)
        backend.rows.removeLast(80)       // 40 rows left: page 2 no longer exists
        await list.reload()
        #expect(list.math.page == 0)
        #expect(list.items.count == 40)
    }

    @Test func errorsAreKeptUntilNextSuccess() async {
        struct Offline: Error {}
        final class Flag { var fail = true }
        let flag = Flag()
        let list = PagedList<Int>(pageSize: 5) { _ in
            if flag.fail { throw Offline() }
            return PageResult(items: [1, 2], totalCount: 2)
        }
        await list.reload()
        #expect(list.error is Offline && !list.isLoading)
        flag.fail = false
        await list.reload()
        #expect(list.error == nil && list.items == [1, 2])
    }

    @Test func staleResponsesAreDiscarded() async {
        let list = PagedList<String>(pageSize: 5) { request in
            if request.query == "slow" {
                try await Task.sleep(for: .milliseconds(300))
                return PageResult(items: ["stale"], totalCount: 1)
            }
            return PageResult(items: ["fresh"], totalCount: 1)
        }
        let slow = Task { await list.search("slow") }
        try? await Task.sleep(for: .milliseconds(50))
        await list.search("fast")
        await slow.value
        #expect(list.items == ["fresh"])
        #expect(list.query == "fast")
    }
}

// MARK: - Country flags

struct CountryFlagTests {
    @Test(arguments: [
        ("SE", "🇸🇪"), ("se", "🇸🇪"), (" us ", "🇺🇸"), ("UK", "🇬🇧"), ("GB", "🇬🇧"),
        ("Sweden", "🇸🇪"), ("sweden", "🇸🇪"), ("Sverige", "🇸🇪"), ("Danmark", "🇩🇰"),
        ("Norway", "🇳🇴"), ("United States", "🇺🇸"), ("United Kingdom", "🇬🇧"),
        ("Scotland", "🇬🇧"), ("USA", "🇺🇸"), ("Germany", "🇩🇪"), ("Tyskland", "🇩🇪"),
        ("Switzerland", "🇨🇭"), ("Japan", "🇯🇵"), ("New Zealand", "🇳🇿"),
    ])
    func resolves(_ input: String, _ flag: String) {
        #expect(countryFlag(input) == flag)
    }

    @Test(arguments: ["", "   ", "ZZ", "12", "Atlantis", "S", "SWE"])
    func unknownFallsBack(_ input: String) {
        #expect(countryFlag(input) == unknownCountryFlag)
    }

    @Test func codes() {
        #expect(countryCode(for: "Finland") == "FI")
        #expect(countryCode(for: "fi") == "FI")
        #expect(countryCode(for: "Nowhere") == nil)
    }

    /// Nassau's hard-coded 17-entry map resolves to the same codes.
    @Test func coversNassausMap() {
        let nassau = [
            "Sweden": "SE", "Denmark": "DK", "Norway": "NO", "Finland": "FI",
            "United States": "US", "United Kingdom": "GB", "Germany": "DE", "Spain": "ES",
            "France": "FR", "Italy": "IT", "Portugal": "PT", "Ireland": "IE", "Scotland": "GB",
            "Netherlands": "NL", "Belgium": "BE", "Austria": "AT", "Switzerland": "CH",
        ]
        for (name, code) in nassau { #expect(countryCode(for: name) == code, "\(name)") }
    }

    @Test func flagEmojiRejectsNonLetters() {
        #expect(flagEmoji(isoCode: "se") == "🇸🇪")
        #expect(flagEmoji(isoCode: "S1") == nil)
        #expect(flagEmoji(isoCode: "SEX") == nil)
    }
}

// MARK: - Auth

func makeJWT(_ payload: [String: Any]) -> String {
    func b64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = b64(try! JSONSerialization.data(withJSONObject: ["alg": "HS256", "typ": "JWT"]))
    let body = b64(try! JSONSerialization.data(withJSONObject: payload))
    return "\(header).\(body).signature"
}

struct AuthTests {
    @Test func readsClaims() throws {
        let token = makeJWT([
            "sub": "u1", "email": "a@b.c", "role": "authenticated", "exp": 2_000_000_000,
            "app_metadata": ["role": "admin", "provider": "email"],
        ])
        let claims = try #require(JWTClaims(token: token))
        #expect(claims.subject == "u1" && claims.email == "a@b.c")
        #expect(claims.postgresRole == "authenticated" && !claims.isServiceRole)
        #expect(claims.appMetadataRole == "admin")
        #expect(claims.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
    }

    @Test func detectsServiceRoleKeys() throws {
        let key = makeJWT(["role": "service_role", "iss": "supabase"])
        #expect(try #require(JWTClaims(token: key)).isServiceRole)
    }

    @Test(arguments: ["", "abc", "a.b", "a.!!!.c", "a.b.c.d"])
    func rejectsMalformedTokens(_ token: String) {
        #expect(JWTClaims(token: token) == nil)
    }

    @Test func appMetadataRoleGate() async throws {
        let admin = makeJWT(["app_metadata": ["role": "admin"]])
        let staff = makeJWT(["app_metadata": ["role": "support"]])
        let user = makeJWT(["user_metadata": ["role": "admin"]]) // user-writable: must not count
        #expect(try await AppMetadataRoleGate { admin }.verifyAdmin())
        #expect(try await !AppMetadataRoleGate { staff }.verifyAdmin())
        #expect(try await AppMetadataRoleGate(roles: ["admin", "support"]) { staff }.verifyAdmin())
        #expect(try await !AppMetadataRoleGate { user }.verifyAdmin())
        #expect(try await !AppMetadataRoleGate { nil }.verifyAdmin())
    }

    @Test func gateStates() async {
        struct Down: LocalizedError { var errorDescription: String? { "server down" } }
        #expect(await evaluateAdminGate(ClosureAdminGate { true }) == .admin)
        #expect(await evaluateAdminGate(ClosureAdminGate { false }) == .notAdmin)
        #expect(await evaluateAdminGate(ClosureAdminGate { throw Down() }) == .failed("server down"))
        #expect(await evaluateAdminGate(ClosureAdminGate { throw CancellationError() }) == .checking)
    }
}

// MARK: - Shell grouping

struct ShellTests {
    @Test func groupsKeepFirstAppearanceOrder() {
        let items: [(String, String?)] = [("dash", "Overview"), ("users", "Data"), ("stats", "Overview"), ("misc", nil), ("wines", "Data")]
        let groups = AdminSectionGrouping.groups(items, key: \.1).map { $0.map(\.0) }
        #expect(groups == [["dash", "stats"], ["users", "wines"], ["misc"]])
    }
}
