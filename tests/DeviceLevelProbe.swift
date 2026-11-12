// SPDX-License-Identifier: GPL-3.0-only
// 探针：device_level 3 与 1 对不同剧集的档位影响。
// 走与生产一致的分支（Argus 签名 + gzip + 播放 aid/版本），只是把 level 提出来对比。
//
// 用法：
//   bash scripts/probe-device-level.sh [剧集id...]
import Foundation

@main struct DeviceLevelProbe {
static func main() async {
    let seriesIDs = CommandLine.arguments.count > 1 ? Array(CommandLine.arguments.dropFirst()) : ["7143038691944959011"]
    let http = HongguoHTTP()
    let repo = ContentRepository(http: http)
    let device = try! await PlayerDeviceSource(http: http).obtain()
    print("device_id=\(device.deviceId)\n")

    for seriesID in seriesIDs {
        guard let (series, episodes) = try? await repo.detail(id: seriesID) else {
            print("\(seriesID): 详情获取失败")
            continue
        }
        print("== \(series.title) (\(seriesID)) 共 \(episodes.count) 集")
        for episode in episodes.prefix(2) {
            print("  集 \(episode)")
            for level in [3, 1] {
                let summary = await describe(episode: episode, device: device, level: level)
                print("    device_level=\(level): \(summary)")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        print("")
    }
    exit(0)
}

static func describe(episode: String, device: PlayerDevice, level: Int) async -> String {
    do {
        let ladder = try await ladder(episode: episode, device: device, level: level)
        guard !ladder.renditions.isEmpty else { return "无档位" }
        return ladder.renditions
            .sorted { $0.quality > $1.quality }
            .map { "\($0.quality)p/\($0.codec)\(CodecCapabilities.supports($0) ? "*" : "")" }
            .joined(separator: " ")
    } catch {
        return "错误：\(error.localizedDescription)"
    }
}

/// 与 ContentRepository.fetchLadder 保持同一套参数与签名，只把 device_level 提出来。
static func ladder(episode: String, device: PlayerDevice, level: Int) async throws -> StreamLadder {
    let payload = "{\"biz_param\":{\"detail_page_version\":0,\"device_level\":\(level),\"disable_digg_stat\":false,\"need_all_video_definition\":true,\"need_mp4_align\":false,\"use_os_player\":false,\"use_server_dns\":false,\"video_platform\":1024},\"mixed_video_id_map\":{\"1004\":[\"\(episode)\"]}}"
    let body = Gzip.compress(Array(payload.utf8))
    var values = VendorConstants.device
    values["device_id"] = device.deviceId
    values["iid"] = device.installId
    values["cdid"] = device.cdid
    values["openudid"] = device.openudid
    for (key, value) in playbackOverrides { values[key] = value }
    values["_rticket"] = String(Int64(Date().timeIntervalSince1970 * 1000))
    let query = Signer.encode(values)
    let ts = Int64(Date().timeIntervalSince1970)
    let signature = Argus.headers(
        query: query, body: body, ts: ts, aid: 1967,
        deviceId: device.deviceId, installId: device.installId
    )
    var headers: [String: String] = [
        "User-Agent": VendorConstants.PLAYBACK_UA,
        "Accept": "application/json; charset=utf-8,application/x-protobuf",
        "Content-Type": "application/json; charset=UTF-8",
        "Content-Encoding": "gzip",
        "x-ss-dp": "8662",
    ]
    for (key, value) in signature { headers[key] = value }
    let url = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/?\(query)"
    let resp = try await HongguoHTTP().request(url, method: "POST", headers: headers, body: Data(body))
    let raw = String(data: resp.data, encoding: .utf8) ?? ""
    if raw.isEmpty { throw ContentError("播放接口返回空响应", retryable: true) }
    let data = try parseJSON(raw)
    guard let map = data.obj("data"),
          let container = map[episode] as? [String: Any]
            ?? map.values.compactMap({ $0 as? [String: Any] }).first else {
        throw ContentError("播放信息为空")
    }
    let model: [String: Any]? = {
        if let dict = container["video_model"] as? [String: Any] { return dict }
        if let text = container["video_model"] as? String { return try? parseJSON(text) }
        return nil
    }()
    guard let model else { throw ContentError("播放信息格式异常") }
    let seed = (model["key_seed"] as? String).flatMap { Data(base64Encoded: $0).map { Array($0) } }
    var seen = Set<String>()
    let renditions = ContentRepository.renditions(from: model["video_list"], seed: seed, seen: &seen)
    return StreamLadder(renditions: renditions)
}

static let playbackOverrides = [
    "aid": "1967",
    "app_name": "novelapp",
    "version_code": "74332",
    "version_name": "7.4.3.32",
    "manifest_version_code": "74332",
    "update_version_code": "74332",
    "pv_player": "74332",
]
}
