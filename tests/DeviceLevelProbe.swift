// SPDX-License-Identifier: GPL-3.0-only
// 探针：device_level 2/1/3 对 multi_video_model 返回档位的影响。
// 每个级别请求 2 次，用于区分「参数影响」与「服务端随时间波动」。
//
// 用法：
//   bash scripts/probe-device-level.sh [剧集id] [次数]
import Foundation

let episodeID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "7695875832245390398"
let repeatCount = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 2 : 2

func post(_ url: String, body: Data, headers: [String: String]) async -> String {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = 30
    for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
    guard let (data, _) = try? await URLSession.shared.data(for: request) else { return "" }
    return String(data: data, encoding: .utf8) ?? ""
}

struct Result {
    let level: Int
    let code: Int
    let renditions: [String]
    let codecs: [String: Int]
    let mainKind: String

    var summary: String { renditions.joined(separator: " ") }
}

func probe(deviceLevel: Int, device: PlayerDevice) async -> Result {
    let payload = "{\"biz_param\":{\"detail_page_version\":0,\"device_level\":\(deviceLevel),\"disable_digg_stat\":false,\"need_all_video_definition\":true,\"need_mp4_align\":false,\"use_os_player\":false,\"use_server_dns\":false,\"video_platform\":1024},\"mixed_video_id_map\":{\"1004\":[\"\(episodeID)\"]}}"
    var values = VendorConstants.device
    values["iid"] = device.installId
    values["device_id"] = device.deviceId
    values["cdid"] = device.cdid
    values["openudid"] = device.openudid
    values["_rticket"] = String(Int64(Date().timeIntervalSince1970 * 1000))
    let url = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/?\(Signer.encode(values))"
    let headers = [
        "User-Agent": "com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)",
        "Accept": "application/json; charset=utf-8,application/x-protobuf",
    ]
    let raw = await post(url, body: Data(payload.utf8), headers: headers)
    guard let data = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] else {
        return Result(level: deviceLevel, code: -1, renditions: ["<非JSON>"], codecs: [:], mainKind: "-")
    }
    let code = (data["code"] as? Int) ?? (data["Code"] as? Int) ?? -999
    guard let root = data["data"] as? [String: Any],
          let container = root.values.first as? [String: Any] else {
        return Result(level: deviceLevel, code: code, renditions: [], codecs: [:], mainKind: "-")
    }
    var model: [String: Any]?
    if let dict = container["video_model"] as? [String: Any] {
        model = dict
    } else if let text = container["video_model"] as? String {
        model = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
    }
    guard let model else {
        return Result(level: deviceLevel, code: code, renditions: [], codecs: [:], mainKind: "-")
    }

    var out: [String] = []
    var counts: [String: Int] = [:]
    var kind = "-"
    func add(_ row: [String: Any], meta: [String: Any]) {
        let codec = (meta["codec_type"] as? String) ?? (row["codec_type"] as? String) ?? "?"
        let h = (meta["vheight"] as? Int) ?? (row["vheight"] as? Int) ?? 0
        out.append("\(codec)/\(h)p")
        counts[codec, default: 0] += 1
        if kind == "-" {
            let main = (row["main_url"] as? String) ?? ""
            kind = main.hasPrefix("http") ? "明文" : "密文"
        }
    }
    if let rows = model["video_list"] as? [[String: Any]] {
        for row in rows { add(row, meta: row["video_meta"] as? [String: Any] ?? [:]) }
    } else if let rows = model["video_list"] as? [String: Any] {
        for (_, v) in rows.sorted(by: { $0.key < $1.key }) {
            guard let row = v as? [String: Any] else { continue }
            add(row, meta: [:])
        }
    }
    return Result(level: deviceLevel, code: code, renditions: out, codecs: counts, mainKind: kind)
}

@main struct DeviceLevelProbeMain {
    static func main() async {
        print("探针：device_level 对比（episode=\(episodeID)，每级 \(repeatCount) 次）\n")
        let device: PlayerDevice
        do {
            device = try await PlayerDeviceSource(http: HongguoHTTP()).obtain()
            print("device_id=\(device.deviceId)\n")
        } catch {
            print("设备注册失败：\(error.localizedDescription)")
            exit(1)
        }

        var all: [Result] = []
        for level in [2, 1, 3] {
            for i in 1...repeatCount {
                let r = await probe(deviceLevel: level, device: device)
                all.append(r)
                let codecSummary = r.codecs.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
                print("device_level=\(level) 第\(i)次: code=\(r.code) \(codecSummary) | \(r.summary)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            print()
        }

        print("--- 汇总 ---")
        for level in [2, 1, 3] {
            let group = all.filter { $0.level == level }
            let uniq = Set(group.map { $0.summary })
            print("device_level=\(level): \(uniq.count) 种不同结果\(uniq.count > 1 ? "（同参数多次请求结果不稳定）" : "")")
            for u in uniq { print("    \(u.isEmpty ? "<空>" : u)") }
        }
        let allUniq = Set(all.map { $0.summary })
        print("\n全部 \(all.count) 次请求共 \(allUniq.count) 种结果")
        exit(0)
    }
}
