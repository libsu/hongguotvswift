// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import AVFoundation

final class AccountFixture: URLProtocol {
    static let lock = NSLock()
    static var mode = "history"
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock(); let mode = Self.mode; Self.requests += 1; Self.lock.unlock()
        let payload: String
        let code: Int
        if mode == "error" { code = 502; payload = #"{"error":"测试网络失败"}"# }
        else if mode == "empty" { code = 200; payload = #"{"items":[]}"# }
        else {
            code = 200
            payload = #"{"items":[{"series":{"id":"123","title":"云端历史作品","cover":"","description":"","badge":"全20集"},"episodeID":"456","episodeIndex":2,"position":12.5,"duration":90}]}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    static func change(_ mode: String) { lock.lock(); Self.mode = mode; lock.unlock() }
}

@main struct CloudHistoryTests {
    @MainActor static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AccountFixture.self]
        let session = URLSession(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); session.invalidateAndCancel() }
        let model = Model(resourcesURL: nil, library: LocalLibrary(file: directory.appendingPathComponent("library.json")), restoreSession: false, bridgeURL: URL(string: "http://127.0.0.1:9/test/"), session: session)
        defer { model.shutdown() }
        func settled() async throws {
            for _ in 0..<100 {
                if !model.cloudLoading { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            fatalError("Cloud loading did not settle")
        }
        model.navigate("账户历史")
        assert(model.cloudRows.isEmpty && !model.cloudLoading)
        // Both QR confirmation and restored sessions use this acceptance path.
        model.acceptAccount(AccountResult(loggedIn: true, id: "fixture-user", nickname: "测试用户", credentials: nil))
        assert(model.cloudLoading)
        try await settled()
        assert(model.cloudRows.count == 1 && model.cloudRows[0].episodeIndex == 2)
        assert(model.cloudLoadedKey != nil && model.cloudError == nil)
        AccountFixture.change("empty"); model.navigate("账户收藏"); try await settled()
        assert(model.cloudRows.isEmpty && model.cloudLoadedKey != nil && model.cloudError == nil)
        AccountFixture.change("error"); model.navigate("账户历史"); try await settled()
        assert(model.cloudError != nil && model.cloudLoadedKey == nil && !model.cloudLoading)
        AccountFixture.change("history"); model.loadCloud(); try await settled()
        assert(model.cloudRows.count == 1 && model.cloudError == nil)
        assert(!model.showDetail && model.navigation == "账户历史")
        print("Login-triggered cloud history, navigation, empty/error distinction and retry: PASS")
    }
}
