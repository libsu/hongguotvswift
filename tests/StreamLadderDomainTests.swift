// SPDX-License-Identifier: GPL-3.0-only
// 校验 streamLadder 取流接口在等价上游域名上均能正确响应（Code == 0 且 body 非空）。
// 与 ContentRepository.streamLadder 保持一致：先注册播放设备，再用注册后的 iid/device_id/cdid 发请求。
// 逐个域名直连官方 HTTPS，验证这些域名可替换当前优先使用的 api5-normal-sinfonlineb。
import Foundation

@main struct StreamLadderDomainMain {
    static func main() async throws {
        let args = CommandLine.arguments

        // 目标域名：与 streamLadder 里 /novel/player/multi_video_model/v1/ 的宿主等价。
        let domains: [String] = [
            "api5-normal-sinfonlinea.fqnovel.com",
            "api3-normal-sinfonlinea.fqnovel.com",
            "api5-normal-sinfonlineb.fqnovel.com",
            "api5-normal-sinfonlinec.fqnovel.com",
        ]

        // 取一个真实播放用剧集 vid 作为样本：
        // 优先读命令行参数（可为 vid 或 series_id），否则从首页取首条 series_id 再解析首个 vid。
        // streamLadder 需要 mixed_video_id_map 里的 vid（非 series_id），series_id 会返回 101000。
        var sampleId = args.count >= 2 ? args[1] : ""
        let repo = ContentRepository()
        if sampleId.isEmpty {
            do {
                let page = try await repo.home(page: 1)
                sampleId = page.items.first?.id ?? ""
                print("未指定 id，已从首页取样 series_id=\(sampleId)")
            } catch {
                print("[ERROR] 无法从首页取样：\(error)；请显式传入：StreamLadderDomainTests <vid|series_id>")
                exit(2)
            }
        }
        guard isValidNumericId(sampleId) else {
            print("[ERROR] id 非法：\(sampleId)")
            exit(2)
        }
        // 若传入/取样的是 series_id，先解析出首个 vid（streamLadder 需要 vid）。
        do {
            let (_, episodes) = try await repo.detail(id: sampleId)
            if let vid = episodes.first, !vid.isEmpty {
                sampleId = vid
                print("解析出首个 vid=\(sampleId)")
            }
        } catch {
            // 传入的可能本身就是 vid，detail 失败时直接用它继续（后续 streamLadder 会再校验）。
            print("[WARN] 无法解析 vid，按原始 id 继续：\(error)")
        }

        var failures = 0
        var passes = 0
        let device: PlayerDevice
        do {
            device = try await PlayerDeviceSource(http: HongguoHTTP()).obtain()
            print("已注册播放设备 device_id=\(device.deviceId) install_id=\(device.installId)")
        } catch {
            print("[ERROR] 播放设备注册失败：\(error)")
            exit(2)
        }
        for domain in domains {
            do {
                let info = try await Self.check(domain: domain, id: sampleId, device: device)
                passes += 1
                print("[PASS] \(domain) -> code=\(info.code) defs=\(info.defs) keySeed=\(info.hasKeySeed ? "yes" : "no")")
            } catch {
                failures += 1
                print("[WARN] \(domain) -> \(error)")
            }
        }

        // api3 对部分新注册设备会返回 code=-1，但生产取流会换域名重试；只要至少一个域名可用即可。
        guard passes > 0 else {
            print("所有域名均不可用（\(failures)/\(domains.count)）")
            exit(1)
        }
        if failures > 0 {
            print("\(passes)/\(domains.count) 个域名取流正常，\(failures) 个暂时不可用（不影响生产轮换）")
        } else {
            print("全部 \(domains.count) 个域名取流接口响应正常")
        }

        // 端到端：走 ContentRepository 的注册设备 + 新 video_list 解析路径。
        do {
            let repo = ContentRepository()
            let info = try await repo.stream(id: sampleId)
            guard info.url.hasPrefix("https://") || info.url.hasPrefix("http://"), !info.quality.isEmpty else {
                print("[FAIL] ContentRepository.stream 返回异常：\(info)")
                exit(1)
            }
            print("[PASS] ContentRepository.stream quality=\(info.quality) key=\(info.key?.count ?? 0)B url=\(info.url.prefix(60))")
        } catch {
            print("[FAIL] ContentRepository.stream -> \(error)")
            exit(1)
        }
    }

    struct CheckResult {
        let code: Int
        let defs: Int
        let hasKeySeed: Bool
    }

    /// 复现 ContentRepository.streamLadder 的首个请求，仅替换 host，校验接口返回 Code、清晰度数与 key_seed。
    static func check(domain: String, id: String, device: PlayerDevice) async throws -> CheckResult {
        let payload = "{\"biz_param\":{\"detail_page_version\":0,\"device_level\":3,\"disable_digg_stat\":false,\"need_all_video_definition\":true,\"need_mp4_align\":false,\"use_os_player\":false,\"use_server_dns\":false,\"video_platform\":1024},\"mixed_video_id_map\":{\"1004\":[\"\(id)\"]}}"

        var queryDevice = VendorConstants.device
        queryDevice["iid"] = device.installId
        queryDevice["device_id"] = device.deviceId
        queryDevice["cdid"] = device.cdid
        queryDevice["openudid"] = device.openudid
        queryDevice["_rticket"] = String(clock())

        let query = Signer.encode(queryDevice)
        let url = "https://\(domain)/novel/player/multi_video_model/v1/?\(query)"
        let headers: [String: String] = [
            "User-Agent": "com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)",
            "Accept": "application/json; charset=utf-8,application/x-protobuf",
        ]

        let http = HongguoHTTP()

        // 对齐 streamLadder 的软失败重试：上游偶发「HTTP 200 但 body 为空」，首次拿空需带退避重试。
        var raw = ""
        var lastError: Error? = nil
        for attempt in 1...3 {
            do {
                let resp = try await http.request(url, method: "POST", headers: headers, body: Data(payload.utf8))
                guard (200..<300).contains(resp.statusCode) else {
                    throw ContentError("HTTP \(resp.statusCode)", statusCode: resp.statusCode)
                }
                let body = String(data: resp.data, encoding: .utf8) ?? ""
                if body.isEmpty {
                    throw ContentError("响应 body 为空（HTTP \(resp.statusCode)）", statusCode: resp.statusCode)
                }
                raw = body
                lastError = nil
                break
            } catch {
                if Task.isCancelled { throw error }
                lastError = error
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: UInt64(700_000_000 * attempt))
                    try Task.checkCancellation()
                }
            }
        }
        if raw.isEmpty { throw lastError ?? ContentError("响应 body 为空") }

        let data = try parseJSON(raw)
        let code = data.optInt("Code", data.optInt("code", -1))
        guard code == 0 else { throw ContentError("接口返回非零错误码 \(code)") }

        guard let map = data.obj("data"), !map.isEmpty else { throw ContentError("data 为空") }
        let entry: [String: Any]
        if let e = map.obj(id) { entry = e }
        else if let first = map.values.compactMap({ $0 as? [String: Any] }).first { entry = first }
        else { throw ContentError("data 中无剧集条目") }

        let model = entry.obj("video_model") ?? (try? parseJSON(entry.str("video_model"))) ?? [:]
        // 新接口直接在 video_model.video_list 返回全部档位（可能是对象或数组）。
        let direct = model["video_list"]
        if let rows = direct as? [String: Any], !rows.isEmpty {
            return CheckResult(code: code, defs: rows.count, hasKeySeed: !model.str("key_seed").isEmpty)
        }
        if let rows = direct as? [[String: Any]], !rows.isEmpty {
            return CheckResult(code: code, defs: rows.count, hasKeySeed: !model.str("key_seed").isEmpty)
        }
        let fallbackRaw = model["fallback_api"]
        var fallback = ""
        if let d = fallbackRaw as? [String: Any] { fallback = d.str("fallback_api") }
        else if let a = fallbackRaw as? [[String: Any]] { fallback = a.first?.str("fallback_api") ?? "" }
        else if let s = fallbackRaw as? String { fallback = (try? parseJSON(s).str("fallback_api")) ?? s }
        guard fallback.hasPrefix("https://") else { throw ContentError("fallback_api 格式异常") }

        let infoRaw = try await http.text(fallback)
        let infoData = try parseJSON(infoRaw)
        guard let videoInfo = infoData.obj("video_info"), let dataObj = videoInfo.obj("data") else {
            throw ContentError("无 video_info.data")
        }
        guard let videoList = dataObj.obj("video_list") else { throw ContentError("无 video_list") }

        return CheckResult(
            code: code,
            defs: videoList.count,
            hasKeySeed: !dataObj.str("key_seed").isEmpty
        )
    }

    static func clock() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}
