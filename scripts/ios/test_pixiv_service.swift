// SPDX-License-Identifier: GPL-3.0-only
// Foundation-only regression harness for the production iOS Pixiv service.
// Synthetic data and injected transport only: no account, network or keychain.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private enum Fixtures {
    static let session = "31415926_Q7vX2mLp9KdR4tYw8NzB3cHs6FgJ1aUe"

    static func json(_ object: Any) -> Data {
        // All fixture values below are valid JSON values.
        try! JSONSerialization.data(withJSONObject: object)
    }

    static func thumbnail(_ id: Int) -> String {
        "https://i.pximg.net/c/480x960/img-master/img/2026/09/26/00/00/00/\(id)_p0_master1200.jpg"
    }

    // These shapes mirror Tests/Unit/Pixiv/PixivTestSupport.swift.
    static func rankingEntry(_ id: Int) -> [String: Any] {
        ["illust_id": id, "illust_type": "0", "title": "Work \(id)", "user_id": "1304",
         "user_name": "Artist", "url": thumbnail(id), "width": 1920, "height": 1080,
         "illust_page_count": "3", "rank": "4", "tags": ["風景", "sky"],
         "illust_content_type": ["sexual": 0, "grotesque": false], "is_masked": false]
    }

    static func ranking(_ rows: [[String: Any]]) -> Data {
        json(["contents": rows, "mode": "daily", "content": "illust", "page": "2",
              "prev": 1, "next": "3", "rank_total": "123"])
    }

    static func searchEntry(_ id: Int) -> [String: Any] {
        ["id": String(id), "illustType": 0, "title": "Work \(id)", "userId": "2401",
         "userName": "Artist", "url": thumbnail(id), "width": 3840, "height": 2160,
         "pageCount": 2, "xRestrict": 0, "sl": 2, "aiType": 1, "isMasked": false,
         "tags": ["風景", "sky"]]
    }

    static func search(_ rows: [[String: Any]], key: String = "illust") -> Data {
        json(["error": false, "body": [key: ["data": rows, "total": "1234", "lastPage": "10"]]])
    }

    static func pageEntry(_ index: Int) -> [String: Any] {
        let stem = "img/2026/09/26/19/04/18/77_p\(index)"
        return ["urls": ["thumb_mini": "https://i.pximg.net/c/128x128/img-master/\(stem)_square1200.jpg",
                         "small": "https://i.pximg.net/c/540x540_70/img-master/\(stem)_master1200.jpg",
                         "regular": "https://i.pximg.net/img-master/\(stem)_master1200.jpg",
                         "original": "https://i.pximg.net/img-original/\(stem).png"],
                "width": "1360", "height": 1920]
    }

    static func pages(_ rows: [[String: Any]]) -> Data {
        json(["error": false, "message": "", "body": rows])
    }

    static func status(_ loggedIn: Bool, includeName: Bool = true) -> Data {
        var user: [String: Any] = ["is_logged_in": loggedIn, "user_x_restrict": "1"]
        if loggedIn {
            user["user_id"] = "31415926"
            if includeName { user["user_name"] = "Tester" }
        }
        return json(["error": false, "body": ["user_status": user]])
    }
}

private struct RecordedRequest: Equatable {
    let url: URL
    let session: String?
    let limit: Int?
    let checkpoint: URL?
}

/// A mock implementing the production protocol. An oversized advertised length is
/// simulated without allocating 64 MiB or touching a server.
private actor FixtureTransport: PixivTransport {
    private let replies: [String: Data]
    private let failure: PixivFailure.Code?
    private let imageBytes: Data
    private let advertisedLength: Int?
    private(set) var requests: [RecordedRequest] = []

    init(replies: [String: Data] = [:], failure: PixivFailure.Code? = nil,
         imageBytes: Data = Data([0xFF, 0xD8, 0xFF]), advertisedLength: Int? = nil) {
        self.replies = replies
        self.failure = failure
        self.imageBytes = imageBytes
        self.advertisedLength = advertisedLength
    }

    func data(from url: URL, session: String?) async throws -> Data {
        requests.append(RecordedRequest(url: url, session: session, limit: nil, checkpoint: nil))
        if let failure { throw PixivFailure(code: failure) }
        guard let reply = replies[url.path] else { throw PixivFailure(code: .unreadable) }
        return reply
    }

    func image(from url: URL, limit: Int, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Data {
        try imageReply(url, limit: limit, checkpoint: nil, progress: progress)
    }

    func image(from url: URL, limit: Int, checkpoint: URL,
               progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> Data {
        try imageReply(url, limit: limit, checkpoint: checkpoint, progress: progress)
    }

    private func imageReply(_ url: URL, limit: Int, checkpoint: URL?,
                            progress: @escaping @Sendable (Int64, Int64?) -> Void) throws -> Data {
        requests.append(RecordedRequest(url: url, session: nil, limit: limit, checkpoint: checkpoint))
        if let failure { throw PixivFailure(code: failure) }
        let count = advertisedLength ?? imageBytes.count
        guard count <= limit, imageBytes.count <= limit else {
            throw PixivFailure(code: .tooLarge(megabytes: limit / 1_048_576))
        }
        progress(Int64(imageBytes.count), Int64(count))
        return imageBytes
    }
}

@main
private struct PixivServiceRegression {
    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    static func expectFailure<T>(_ code: PixivFailure.Code, _ operation: () throws -> T) throws {
        do {
            _ = try operation()
            throw Failure(message: "Expected PixivFailure \(code)")
        } catch let failure as PixivFailure {
            try require(failure.code == code, "Expected \(code), got \(failure.code)")
        }
    }

    static func expectAsyncFailure<T>(_ code: PixivFailure.Code, _ operation: () async throws -> T) async throws {
        do {
            _ = try await operation()
            throw Failure(message: "Expected PixivFailure \(code)")
        } catch let failure as PixivFailure {
            try require(failure.code == code, "Expected \(code), got \(failure.code)")
        }
    }

    static func queryItems(_ url: URL) -> [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    static func rankingLooseRows() throws {
        var sexual = Fixtures.rankingEntry(301)
        sexual["illust_content_type"] = [["sexual": "1"]]
        sexual["illust_type"] = 0
        sexual["illust_page_count"] = 2
        var sensitive = Fixtures.rankingEntry(305)
        sensitive["is_masked"] = true
        var unrated = Fixtures.rankingEntry(306)
        unrated["illust_content_type"] = [Any]()
        var withheld = Fixtures.rankingEntry(302)
        withheld["mask_reason"] = "login_only"
        var manga = Fixtures.rankingEntry(303)
        manga["illust_type"] = "1"
        var ugoira = Fixtures.rankingEntry(304)
        ugoira["illust_type"] = "2"
        var invalidID = Fixtures.rankingEntry(307)
        invalidID["illust_id"] = 0
        var invalidSize = Fixtures.rankingEntry(308)
        invalidSize["width"] = 0
        var invalidHost = Fixtures.rankingEntry(309)
        invalidHost["url"] = "https://example.com/309.jpg"
        let rows = [sexual, withheld, manga, ugoira, sensitive, unrated, invalidID, invalidSize,
                    invalidHost, Fixtures.rankingEntry(301)]
        let result = try PixivService.decodeRanking(Fixtures.ranking(rows), requestedPage: 7)
        try require(result.works.map(\.id) == ["301", "305", "306"], "ranking skips malformed, withheld, manga, ugoira and duplicates")
        try require(result.works.map(\.rating) == [.questionable, .questionable, .everyone], "ranking list/object/empty ratings and sensitive mask")
        try require(result.works[0].pageCount == 2 && result.works[0].rank == 4, "ranking mixed number and string fields")
        try require(result.works[0].tags == ["風景", "sky"] && result.works[0].aiGenerated == nil, "ranking tags and unknown AI flag")
        try require(result.page == 2 && result.totalPages == 3 && result.totalCount == 123, "ranking pagination")
        try expectFailure(.unreadable) { try PixivService.decodeRanking(Data("<html>".utf8), requestedPage: 1) }
    }

    static func rankingR18() throws {
        var grotesque = Fixtures.rankingEntry(502)
        grotesque["illust_content_type"] = ["sexual": 0, "grotesque": true]
        let works = try PixivService.decodeRanking(Fixtures.ranking([Fixtures.rankingEntry(501), grotesque]),
                                                   requestedPage: 1, r18: true).works
        try require(works.map(\.rating) == [.mature, .grotesque], "R18 ranking marks grotesque separately")
        let query = PixivQuery(ranking: .dailyR18, ratings: [.mature, .grotesque]).sanitized(signedIn: true)
        try require(works.filter(query.admits).map(\.id) == ["501"], "R18G never appears after query filtering")
    }

    static func searchLooseRows() throws {
        var ai = Fixtures.searchEntry(401)
        ai["id"] = 401
        ai["aiType"] = "2"
        var questionable = Fixtures.searchEntry(402)
        questionable["sl"] = "4"
        var mature = Fixtures.searchEntry(403)
        mature["xRestrict"] = "1"
        var grotesque = Fixtures.searchEntry(404)
        grotesque["xRestrict"] = 2
        var sensitive = Fixtures.searchEntry(405)
        sensitive["isMasked"] = true
        var manga = Fixtures.searchEntry(406)
        manga["illustType"] = 1
        var ugoira = Fixtures.searchEntry(407)
        ugoira["illustType"] = 2
        var malformed = Fixtures.searchEntry(408)
        malformed.removeValue(forKey: "id")
        var foreign = Fixtures.searchEntry(409)
        foreign["url"] = "http://i.pximg.net/a.jpg"
        let rows = [ai, questionable, mature, grotesque, sensitive, manga, ugoira, malformed, foreign, ai]
        let result = try PixivService.decodeSearch(Fixtures.search(rows), requestedPage: 3)
        try require(result.works.map(\.id) == ["401", "402", "403", "404", "405"], "search skips malformed, unsafe, manga, ugoira and duplicates")
        try require(result.works.map(\.rating) == [.everyone, .questionable, .mature, .grotesque, .questionable], "search restriction and masking ratings")
        try require(result.works.map(\.aiGenerated) == [true, false, false, false, false], "search AI flags")
        try require(result.page == 3 && result.totalPages == 10 && result.totalCount == 1234, "search pagination")
        let query = PixivQuery(ratings: [.everyone, .questionable, .mature, .grotesque]).sanitized(signedIn: true)
        try require(result.works.filter(query.admits).map(\.id) == ["401", "402", "403", "405"], "search R18G never admitted")
    }

    static func searchAlternateEnvelope() throws {
        let page = try PixivService.decodeSearch(Fixtures.search([Fixtures.searchEntry(7)], key: "illustManga"),
                                                 requestedPage: 1)
        try require(page.works.map(\.id) == ["7"], "alternate illustManga envelope")
        let refusal = Fixtures.json(["error": true, "message": "エラー", "body": [Any]()])
        try expectFailure(.unreadable) { try PixivService.decodeSearch(refusal, requestedPage: 1) }
    }

    static func pagesMultipage() throws {
        var second = Fixtures.pageEntry(1)
        var urls = second["urls"] as! [String: Any]
        urls["small"] = NSNull()
        second["urls"] = urls
        let pages = try PixivService.decodePages(Fixtures.pages([Fixtures.pageEntry(0), second, Fixtures.pageEntry(2)]))
        try require(pages.map(\.index) == [0, 1, 2], "all page indices retained")
        try require(pages.map { $0.originalURL.lastPathComponent } == ["77_p0.png", "77_p1.png", "77_p2.png"], "all page originals retained")
        try require(pages[0].previewURL?.absoluteString.contains("540x540") == true, "small preview preferred")
        try require(pages[1].previewURL?.absoluteString.contains("img-master") == true, "regular preview fallback")
        try require(pages.allSatisfy { $0.width == 1360 && $0.height == 1920 }, "mixed numeric dimensions")
    }

    static func pagesInvalid() throws {
        let restricted: [String: Any] = ["urls": ["small": NSNull(), "regular": NSNull(), "original": NSNull()],
                                          "width": 900, "height": 900]
        try expectFailure(.membersOnly) { try PixivService.decodePages(Fixtures.pages([restricted])) }
        var foreign = Fixtures.pageEntry(1)
        foreign["urls"] = ["original": "https://i.pximg.net.example.com/a.png"]
        try expectFailure(.membersOnly) { try PixivService.decodePages(Fixtures.pages([Fixtures.pageEntry(0), foreign])) }
        try expectFailure(.unreadable) { try PixivService.decodePages(Fixtures.pages([])) }
        try expectFailure(.unreadable) { try PixivService.decodePages(Data("<html>".utf8)) }
    }

    static func work(_ width: Int, _ height: Int, rating: PixivRating = .everyone, ai: Bool? = false) -> PixivWork {
        PixivWork(id: "1", title: "", authorID: "", authorName: "", thumbnailURL: nil, width: width,
                  height: height, pageCount: 1, rating: rating, aiGenerated: ai, tags: [], rank: nil)
    }

    static func queryFilters() throws {
        var query = PixivQuery(ratings: [.everyone, .questionable, .mature, .grotesque])
        try require(!query.admits(work(200, 200, rating: .grotesque)), "grotesque always excluded")
        query.orientation = .landscape
        try require(query.admits(work(200, 100)) && !query.admits(work(200, 200)), "landscape excludes square")
        query.orientation = .portrait
        try require(query.admits(work(100, 200)) && !query.admits(work(200, 100)), "portrait orientation")
        query.orientation = .any
        query.minimumSize = .quadHD
        try require(query.admits(work(1440, 2560)) && !query.admits(work(2560, 1439)) &&
                    !query.admits(work(2000, 2000)), "size requires both long and short sides")
        query.minimumSize = .any
        query.hidesAIGenerated = true
        try require(!query.admits(work(100, 200, ai: true)) && query.admits(work(100, 200, ai: nil)), "hide AI but retain unknown")
    }

    static func querySanitization() throws {
        let requested = PixivQuery(ranking: .dailyR18, ratings: [.everyone, .mature, .grotesque])
        let anonymous = requested.sanitized(signedIn: false)
        try require(anonymous.ranking == .daily && anonymous.ratings == [.everyone], "anonymous R18 falls back")
        let signedIn = requested.sanitized(signedIn: true)
        try require(signedIn.ranking == .dailyR18 && signedIn.ratings == [.everyone, .mature], "signed-in R18 remains, grotesque removed")
        try require(PixivQuery(ranking: .weeklyR18, ratings: [.everyone]).sanitized(signedIn: true).ranking == .weekly,
                    "unticked mature ranking falls back")
        try require(PixivQuery(text: " \n ", ranking: .weekly).listing == .ranking(.weekly), "blank text browses ranking")
        for (ratings, expected) in [([PixivRating.everyone], PixivSearchMode.safe),
                                    ([.mature], .r18), ([.questionable, .mature], .all)] {
            let listing = PixivQuery(text: "  a  b ", ratings: Set(ratings)).listing
            guard case .search(let text, _, _, _, _, let mode) = listing else { throw Failure(message: "Expected search") }
            try require(text == "a b" && mode == expected, "normalized text and search age mode")
        }
    }

    static func endpointEncoding() throws {
        let text = "夜空 a/b+c?&#%;x"
        let query = PixivQuery(text: "  \(text)  ", order: .oldest, orientation: .landscape,
                               minimumSize: .ultraHD, hidesAIGenerated: true)
        guard let url = PixivService.searchURL(query.listing, page: 2),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw Failure(message: "Search URL could not be built")
        }
        let items = queryItems(url)
        try require(url.host == "www.pixiv.net" && url.fragment == nil, "search remains on pixiv and has no fragment")
        try require(components.percentEncodedPath.contains("%2F") && components.percentEncodedPath.contains("%2B") &&
                    components.percentEncodedPath.contains("%3B"), "search is exactly one escaped path segment")
        try require(items["word"] == text && components.percentEncodedQuery?.contains("%2B") == true,
                    "special Unicode tag and plus round-trip in query")
        try require(items == ["word": text, "order": "date", "mode": "safe", "p": "2", "s_mode": "s_tag",
                              "type": "illust", "ratio": "0.5", "wlt": "3840", "hlt": "2160", "ai_type": "1"],
                    "search filters and query-injection boundary")
        let portrait = PixivService.searchURL(PixivQuery(text: "sky", orientation: .portrait, minimumSize: .fullHD).listing, page: 0)!
        try require(queryItems(portrait)["ratio"] == "-0.5" && queryItems(portrait)["wlt"] == "1080" &&
                    queryItems(portrait)["hlt"] == "1920" && queryItems(portrait)["p"] == "1", "portrait filters and page clamp")
        let any = PixivService.searchURL(PixivQuery(text: "sky", minimumSize: .fullHD).listing, page: 1)!
        try require(queryItems(any)["wlt"] == "1080" && queryItems(any)["hlt"] == "1080" && queryItems(any)["ratio"] == nil,
                    "any orientation uses short-side minimum")
        let ranking = PixivService.rankingURL(.rookie, page: 0)
        try require(ranking.path == "/ranking.php" && queryItems(ranking) ==
                    ["mode": "rookie", "content": "illust", "format": "json", "p": "1"], "ranking endpoint and clamp")
        try require(PixivService.searchURL(PixivQuery(text: String(repeating: "a", count: 257)).listing, page: 1) == nil,
                    "search length bound")
    }

    static func identityValidation() throws {
        for value in ["", "0", "000", "../1", "12a", "１２", String(repeating: "1", count: 13)] {
            try require(!PixivWork.isValidID(value), "invalid work ID accepted: \(value)")
        }
        try require(PixivWork.isValidID("1") && PixivWork.isValidID("123456789012"), "valid ID bounds")
        try require(PixivWork.libraryID(workID: "42", page: 3) == "pixiv-42-p3", "page library identity")
        try require(PixivService.isSessionValue(Fixtures.session) &&
                    PixivService.userID(fromSession: Fixtures.session) == "31415926", "valid session")
        for value in ["", "31415926_short", "0_abcdefghij", "31415926_abcdefghij;x=1",
                      "31415926_abc defghij", "31415926_abcdefghijé", "31_41_abcdefghij",
                      "31415926_" + String(repeating: "a", count: 129)] {
            try require(!PixivService.isSessionValue(value) && PixivService.userID(fromSession: value) == nil,
                        "invalid session accepted")
        }
    }

    static func cookieHosts() throws {
        func cookie(_ address: String, session: String? = Fixtures.session) -> String? {
            URLSessionPixivTransport.request(URL(string: address)!, accept: "application/json", session: session)
                .value(forHTTPHeaderField: "Cookie")
        }
        try require(cookie("https://www.pixiv.net/ajax/illust/1/pages") == "PHPSESSID=\(Fixtures.session)", "site receives valid session")
        for address in ["https://i.pximg.net/a.jpg", "http://www.pixiv.net/ranking.php",
                        "https://www.pixiv.net.example.com/", "https://accounts.pixiv.net/",
                        "https://www.pixiv.net:8443/", "https://user@www.pixiv.net/"] {
            try require(cookie(address) == nil, "session leaked to \(address)")
        }
        try require(cookie("https://www.pixiv.net/", session: "1_abcdefghij; admin=1") == nil, "malformed session omitted")
        let image = URLSessionPixivTransport.request(URL(string: "https://i.pximg.net/a.jpg")!, accept: "image/*")
        try require(image.value(forHTTPHeaderField: "Referer") == "https://www.pixiv.net/", "image referer")
    }

    static func redirectCookies() throws {
        var request = URLSessionPixivTransport.request(URL(string: "https://www.pixiv.net/ranking.php")!,
                                                       accept: "*/*", session: Fixtures.session)
        try require(URLSessionPixivTransport.redirected(request).value(forHTTPHeaderField: "Cookie") != nil,
                    "same-host redirect keeps cookie")
        for address in ["https://accounts.pixiv.net/login", "https://i.pximg.net/a.jpg",
                        "http://www.pixiv.net/", "https://www.pixiv.net:8443/"] {
            request.url = URL(string: address)
            try require(URLSessionPixivTransport.redirected(request).value(forHTTPHeaderField: "Cookie") == nil,
                        "redirect leaks cookie to \(address)")
        }
    }

    static func httpResponses() throws {
        let url = URL(string: "https://www.pixiv.net/ranking.php")!
        for status in [200, 204, 299] {
            try URLSessionPixivTransport.check(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        for status in [401, 403, 404, 429, 500, 503] {
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            try expectFailure(.status(status)) { try URLSessionPixivTransport.check(response) }
        }
        let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        try expectFailure(.unreadable) { try URLSessionPixivTransport.check(response) }
    }

    static func serviceRequests() async throws {
        let transport = FixtureTransport(replies: [
            "/ranking.php": Fixtures.ranking([Fixtures.rankingEntry(9)]),
            "/ajax/search/illustrations/sky": Fixtures.search([Fixtures.searchEntry(8)]),
            "/ajax/illust/77/pages": Fixtures.pages([Fixtures.pageEntry(0), Fixtures.pageEntry(1)]),
        ])
        let service = PixivService(transport: transport, minimumInterval: .zero)
        let ranking = try await service.page(0, of: .ranking(.weekly))
        let search = try await service.page(2, of: PixivQuery(text: "sky").listing, session: Fixtures.session)
        let pages = try await service.pages(ofWork: "77", session: Fixtures.session)
        try require(ranking.works.map(\.id) == ["9"] && search.works.map(\.id) == ["8"] && pages.count == 2,
                    "service decodes mock responses")
        let calls = await transport.requests
        try require(calls.map { $0.url.path } == ["/ranking.php", "/ajax/search/illustrations/sky", "/ajax/illust/77/pages"],
                    "service calls correct endpoints")
        try require(calls.map(\.session) == [nil, Fixtures.session, Fixtures.session], "session forwarded only to requested JSON calls")
        try require(queryItems(calls[0].url)["p"] == "1" && queryItems(calls[0].url)["mode"] == "weekly" &&
                    queryItems(calls[1].url)["p"] == "2", "service forwards requested listing and page")
        let before = calls.count
        try await expectAsyncFailure(.unreadable) { try await service.pages(ofWork: "../77", session: Fixtures.session) }
        let after = await transport.requests
        try require(after.count == before, "invalid ID causes no request")
    }

    static func serviceAccount() async throws {
        let transport = FixtureTransport(replies: [
            "/touch/ajax/user/self/status": Fixtures.status(true, includeName: false),
            "/ajax/user/31415926": Fixtures.json(["error": false, "body": ["name": "Painter"]]),
        ])
        let service = PixivService(transport: transport, minimumInterval: .zero)
        let invalid = try await service.account(session: "PHPSESSID=wrong")
        try require(invalid == nil, "malformed session rejected")
        let initial = await transport.requests
        try require(initial.isEmpty, "invalid session causes no request")
        let account = try await service.account(session: Fixtures.session)
        try require(account == PixivAccount(id: "31415926", name: "Painter", showsR18: true), "account fallback name")
        let calls = await transport.requests
        try require(calls.map { $0.url.path } == ["/touch/ajax/user/self/status", "/ajax/user/31415926"] &&
                    calls.allSatisfy { $0.session == Fixtures.session }, "account requests keep given session")
        let signedOut = FixtureTransport(replies: ["/touch/ajax/user/self/status": Fixtures.status(false)])
        let other = PixivService(transport: signedOut, minimumInterval: .zero)
        let noAccount = try await other.account(session: Fixtures.session)
        try require(noAccount == nil, "server signed-out status")
    }

    static func serviceFailures() async throws {
        let forbidden = FixtureTransport(failure: .status(403))
        let service = PixivService(transport: forbidden, minimumInterval: .zero)
        try await expectAsyncFailure(.signedOut) { try await service.page(1, of: .ranking(.dailyR18)) }
        try await expectAsyncFailure(.r18Hidden) { try await service.page(1, of: .ranking(.weeklyR18), session: Fixtures.session) }
        try await expectAsyncFailure(.status(403)) { try await service.page(1, of: .ranking(.daily)) }
        let limited = PixivService(transport: FixtureTransport(failure: .status(429)), minimumInterval: .zero)
        try await expectAsyncFailure(.status(429)) { try await limited.page(1, of: PixivQuery(text: "sky").listing) }
    }

    static func serviceOriginalLimit() async throws {
        let transport = FixtureTransport(imageBytes: Data([1, 2, 3]))
        let service = PixivService(transport: transport, minimumInterval: .zero)
        let page = PixivPage(index: 0, width: 10, height: 10, previewURL: nil,
                             originalURL: URL(string: "https://i.pximg.net/img-original/77_p0.png")!)
        let result = try await service.original(of: page) { _, _ in }
        try require(result == Data([1, 2, 3]), "original bytes returned intact")
        let calls = await transport.requests
        try require(calls.count == 1 && calls[0].url == page.originalURL && calls[0].session == nil &&
                    calls[0].limit == 64 * 1024 * 1024 && calls[0].limit == PixivService.originalByteLimit,
                    "original receives 64 MiB cap and no session")
        let foreign = PixivPage(index: 0, width: 10, height: 10, previewURL: nil,
                                originalURL: URL(string: "https://example.com/a.png")!)
        try await expectAsyncFailure(.unreadable) { try await service.original(of: foreign) { _, _ in } }
        let after = await transport.requests
        try require(after.count == 1, "unsafe image host causes no request")
        let oversized = FixtureTransport(advertisedLength: 64 * 1024 * 1024 + 1)
        let limited = PixivService(transport: oversized, minimumInterval: .zero)
        try await expectAsyncFailure(.tooLarge(megabytes: 64)) { try await limited.original(of: page) { _, _ in } }
        let oversizedCalls = await oversized.requests
        try require(oversizedCalls.first?.limit == 64 * 1024 * 1024, "oversized mock received production cap")
    }

    static func main() async throws {
        let cases: [(String, () async throws -> Void)] = [
            ("ranking-loose-rows", { try rankingLooseRows() }), ("ranking-r18", { try rankingR18() }),
            ("search-loose-rows", { try searchLooseRows() }), ("search-alternate-envelope", { try searchAlternateEnvelope() }),
            ("pages-multipage", { try pagesMultipage() }), ("pages-invalid", { try pagesInvalid() }),
            ("query-filters", { try queryFilters() }), ("query-sanitization", { try querySanitization() }),
            ("endpoint-encoding", { try endpointEncoding() }), ("identity-validation", { try identityValidation() }),
            ("cookie-hosts", { try cookieHosts() }), ("redirect-cookies", { try redirectCookies() }),
            ("http-responses", { try httpResponses() }), ("service-requests", { try await serviceRequests() }),
            ("service-account", { try await serviceAccount() }), ("service-failures", { try await serviceFailures() }),
            ("service-original-limit", { try await serviceOriginalLimit() }),
        ]
        for (name, test) in cases {
            do { try await test() } catch { throw Failure(message: "\(name): \(error)") }
            print("PASS \(name)")
        }
        print("PASS: PixivService \(cases.count) cases")
    }
}
