// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AVFoundation

final class FeedFixture: URLProtocol {
    static var paths: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let url = request.url!, path = url.lastPathComponent
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let id = query.first(where: { $0.name == "id" })?.value ?? "a"
        Self.paths.append(path)
        func series(_ id: String) -> String { #"{"id":"\#(id)","title":"作品\#(id)","cover":"","description":"简介","badge":"全2集"}"# }
        let payload: String
        switch path {
        case "feed": payload = #"{"items":[\#(series("a")),\#(series("b"))],"hasMore":false,"topics":[]}"#
        case "detail", "warm": payload = #"{"series":\#(series(id)),"episodes":["\#(id)-1","\#(id)-2"]}"#
        case "play": payload = #"{"url":"http://127.0.0.1:9/video","quality":"1080P"}"#
        default: payload = #"{"items":[]}"#
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
}
@main struct HomeFeedTests {
    @MainActor static func main() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FeedFixture.self]
        let session = URLSession(configuration: config)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); session.invalidateAndCancel() }
        let model = Model(resourcesURL: nil, library: LocalLibrary(file: directory.appendingPathComponent("library.json")), restoreSession: false, bridgeURL: URL(string:"http://127.0.0.1:9/test/"), session: session)
        defer { model.shutdown() }
        func wait(_ ready: () -> Bool) async throws {
            for _ in 0..<300 { if ready() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            fatalError("Feed operation timed out")
        }
        try await wait { !model.busy }
        model.navigate("首页")
        try await wait { !model.busy && model.episode == 0 && model.homeWarmDetail != nil }
        assert(model.preview && model.catalogRows.count == 2 && model.detail?.series.id == "a")
        assert(model.library.contents.history.isEmpty)
        let detailCalls = FeedFixture.paths.filter { $0 == "detail" }.count
        model.moveRecommendation(1)
        try await wait { !model.busy && model.detail?.series.id == "b" }
        assert(FeedFixture.paths.filter { $0 == "detail" }.count == detailCalls, "Warm detail must be reused")
        assert(model.preview && model.library.contents.history.isEmpty)
        model.watchFull(); assert(!model.preview)
        model.navigate("我的"); assert(model.section == "我的" && !model.showDetail)
        print("Home automatic trial, bounded next preload, cached switching, trial isolation and My navigation: PASS")
    }
}
