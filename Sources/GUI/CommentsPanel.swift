// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct CommentsPanel: View {
    @ObservedObject var model: Model
    @ObservedObject var comments: MacComments
    @ObservedObject var thread: MacCommentThread
    @State private var tab = "本集评论"
    @State private var order = "原顺序"
    @State private var filter = ""
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("评论与剧评").font(.title2.bold())
                Spacer()
                Button { model.loadComments(force: true) } label: { Image(systemName: "arrow.clockwise") }.help("刷新评论").disabled(loading)
            }
            Text(model.detail?.series.title ?? "").font(.headline).lineLimit(2)
            Text("第 \((model.episode ?? 0) + 1) 集").font(.caption).foregroundStyle(.secondary)
            Picker("内容", selection: $tab) { Text("本集评论").tag("本集评论"); Text("整剧剧评").tag("整剧剧评") }.pickerStyle(.segmented)
            if !loaded && loading { ProgressView("正在读取评论…").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if !loaded, let error {
                VStack(spacing: 14) { Text(error); Button("重新读取") { model.loadComments(force: true) } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loaded {
                HStack {
                    Text(tab == "本集评论" ? "已加载 \(thread.items.count) 条 / 共 \(thread.total) 条" : "\(items.count) 条节选 / 共 \(comments.result?.reviews.total ?? 0) 条").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if tab == "整剧剧评", let rating = comments.result?.rating, rating > 0 { Text("\(rating, specifier: "%.1f") 分").foregroundStyle(.orange) }
                }
                HStack {
                    TextField("筛选已加载的评论", text: $filter)
                    Picker("排序", selection: $order) { Text("原顺序").tag("原顺序"); Text("赞数").tag("赞数"); Text("时间").tag("时间") }.frame(width: 95)
                }
                if visible.isEmpty {
                    Text(filter.isEmpty ? "暂无可显示的评论" : "没有匹配的评论").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(visible) { comment in
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        AsyncImage(url: URL(string: comment.avatar)) { image in image.resizable().scaledToFill() } placeholder: { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.gray) }
                                            .frame(width: 30, height: 30).clipShape(Circle())
                                        Text(comment.author.isEmpty ? "红果用户" : comment.author).font(.headline).lineLimit(1)
                                        Spacer()
                                        Label("\(comment.likes)", systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Text(comment.content).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    if let date = comment.date { Text(date, style: .date).font(.caption).foregroundStyle(.secondary) }
                                    Divider()
                                }.contextMenu {
                                    Button("复制评论") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(comment.content, forType: .string) }
                                }
                            }
                            if tab == "本集评论" { continuation }
                        }
                    }
                }
                if visible.isEmpty && tab == "本集评论" { continuation }
                Text(tab == "本集评论" ? "下滑到底部可继续加载。筛选和排序仅作用于已加载内容；发送、回复尚未接入，赞数只读。" : "整剧剧评仅显示官网节选。发送、回复尚未接入，赞数只读。")
                    .font(.caption).foregroundStyle(.secondary)
                if let url = URL(string: comments.result?.sourceURL ?? officialURL), url.scheme == "https", url.host == "hongguoduanju.com" {
                    HStack {
                        Link("打开官方播放页", destination: url)
                        Spacer()
                        Button(copied ? "已复制" : "复制页面链接") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string); copied = true
                        }
                    }.font(.caption)
                }
            } else { Text("选择集数后可查看评论").foregroundStyle(.secondary); Spacer() }
        }.padding(20).frame(minWidth: 320).task(id: model.commentKey) { copied = false; filter = ""; model.loadComments() }
    }
    private var officialURL: String {
        guard let detail = model.detail, let episode = model.episode, detail.episodes.indices.contains(episode) else { return "" }
        return "https://hongguoduanju.com/player/\(detail.series.id)/\(detail.episodes[episode])"
    }
    private var loaded: Bool { tab == "本集评论" ? thread.loaded : comments.result != nil }
    private var loading: Bool { tab == "本集评论" ? thread.loading : comments.loading }
    private var error: String? { tab == "本集评论" ? thread.error : comments.error }
    private var items: [PublicComment] { tab == "本集评论" ? thread.items : comments.result?.reviews.items ?? [] }
    @ViewBuilder private var continuation: some View {
        if thread.loading { ProgressView("正在加载更多…").frame(maxWidth: .infinity) }
        else if let error = thread.error {
            VStack(spacing: 8) { Text(error).font(.caption).foregroundStyle(.secondary)
                Button("重试") { model.retryComments() }
            }.frame(maxWidth: .infinity)
        } else if thread.hasMore {
            Button("加载更多评论") { model.loadMoreComments() }
                .frame(maxWidth: .infinity)
                .onAppear { if filter.isEmpty && order == "原顺序" { model.loadMoreComments() } }
        } else { Text("已加载到末尾").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
    }
    private var visible: [PublicComment] {
        let values = items.filter { filter.isEmpty || $0.content.localizedCaseInsensitiveContains(filter) || $0.author.localizedCaseInsensitiveContains(filter) }
        if order == "赞数" { return values.sorted { $0.likes > $1.likes } }
        if order == "时间" { return values.sorted { $0.created > $1.created } }
        return values
    }
}
