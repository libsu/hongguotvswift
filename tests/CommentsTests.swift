// SPDX-License-Identifier: GPL-3.0-only
import Foundation

@main struct CommentsTests {
    @MainActor static func main() async throws {
        func result(_ series: String, _ episode: String) throws -> PublicSocial {
            let value: [String:Any] = ["seriesID":series,"episodeID":episode,"rating":9.1,"ratingCount":42,"sourceURL":"https://hongguoduanju.com/player/123456/234567","limited":true,"reviews":["total":100,"items":[]],"comments":["total":12,"items":[["id":"id","author":"测试作者","avatar":"","content":"真实公开评论","created":1700000000,"likes":2,"rating":0]]]]
            return try JSONDecoder().decode(PublicSocial.self, from: JSONSerialization.data(withJSONObject:value))
        }
        let store = MacComments { series,episode in
            if episode == "slow" { try? await Task.sleep(nanoseconds: 180_000_000) }
            if episode == "error" { throw URLError(.timedOut) }
            if episode == "wrong" { return try result(series,"other") }
            return try result(series,episode)
        }
        func wait() async throws {
            for _ in 0..<100 { if !store.loading { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            fatalError("Comments timed out")
        }
        store.load(series:"123456",episode:"234567"); try await wait()
        assert(store.result?.comments.items.count == 1 && store.result?.comments.total == 12)
        assert(store.result?.comments.items[0].date != nil)
        store.load(series:"123456",episode:"slow")
        store.load(series:"123456",episode:"new"); try await wait()
        try await Task.sleep(nanoseconds: 250_000_000)
        assert(store.result?.episodeID == "new", "Stale comments must not cross episodes")
        store.load(series:"123456",episode:"wrong"); try await wait(); assert(store.result == nil && store.error != nil)
        store.load(series:"123456",episode:"error"); try await wait(); assert(store.error != nil)
        store.load(series:"123456",episode:"234567",force:true); try await wait(); assert(store.result != nil && store.error == nil)
        store.clear(); assert(store.result == nil && !store.loading)
        print("Comment identity, stale request isolation, errors, retry and date parsing: PASS")
    }
}
