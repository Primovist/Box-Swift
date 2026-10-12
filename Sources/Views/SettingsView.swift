import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var catalog: CatalogStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tvbox.autoNext") private var autoNextEpisode = true
    @AppStorage("tvbox.skipOpeningSeconds") private var skipOpeningSeconds = 0
    @State private var endpoint = ""
    @State private var directURL = ""
    @State private var userAgent = ""
    @State private var referer = ""
    @State private var validationMessage: String?
    @State private var playbackRequest: PlaybackRequest?

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= geometry.size.height
            ZStack {
                ScreenBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: wide ? 26 : 21) {
                        topBar
                        titleBlock
                        if wide {
                            HStack(alignment: .top, spacing: 20) {
                                sourceSection
                                    .frame(maxWidth: .infinity)
                                directPlaySection
                                    .frame(maxWidth: .infinity)
                            }
                        } else {
                            sourceSection
                            directPlaySection
                        }
                        scopeSection
                        playerPreferencesSection
                        danmakuPreferencesSection
                    }
                    .frame(maxWidth: 1120, alignment: .leading)
                    .padding(.horizontal, wide ? 72 : 20)
                    .padding(.top, wide ? 28 : 16)
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("设置")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
            .onAppear { endpoint = catalog.sourceURL }
        }
        .fullScreenCover(item: $playbackRequest) { request in
            PlayerScreen(request: request)
        }
    }

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Label("返回", systemImage: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            .buttonStyle(FocusAwareButtonStyle())
            Spacer()
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(text: "片源配置")
            Text("连接 tvbox.json")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("支持标准 XML API、JSON API 和 type=4 HTTP API 站点。配置中的 Spider（type=3）会跳过。")
                .font(.system(size: 14))
                .foregroundStyle(Color.tvboxMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("tvbox.json 地址", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            urlField("https://example.com/tvbox.json", text: $endpoint)
            HStack(spacing: 10) {
                Button {
                    Task { await catalog.loadConfiguration(from: endpoint) }
                } label: {
                    if catalog.isLoading {
                        ProgressView().tint(.white).frame(minWidth: 70, minHeight: 44)
                    } else {
                        Label("载入配置", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(PrimaryActionStyle())
                .disabled(catalog.isLoading || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("恢复演示") {
                    endpoint = ""
                    catalog.restoreSamples()
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 15)
                .frame(minHeight: 44)
                .background(.white.opacity(0.08), in: Capsule())
                .buttonStyle(FocusAwareButtonStyle())
            }

            if let configuration = catalog.configuration {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.tvboxCyan)
                    Text("已载入 \(configuration.sites.count) 个站点、\(configuration.parsers.count) 个解析器、\(configuration.liveGroups.reduce(0) { $0 + $1.channels.count }) 个内置直播频道\(configuration.epgURL.isEmpty ? "" : "，已配置节目单")。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let loadMessage = catalog.loadMessage {
                Text(loadMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(loadMessage.localizedCaseInsensitiveContains("失败") || loadMessage.localizedCaseInsensitiveContains("没有") ? .orange : Color.tvboxCyan)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("支持顶层 sites 或 video.sites；站点 type 0、1、4。支持静态网页媒体地址提取和 JSON 解析器。动态网页嗅探、Spider（type 3）不执行。")
                .font(.system(size: 11))
                .foregroundStyle(Color.tvboxMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private var directPlaySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("直接播放地址", systemImage: "play.rectangle")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            urlField("媒体 URL（HLS、MP4 等）", text: $directURL)
            plainField("User-Agent（可选）", text: $userAgent)
            urlField("Referer（可选）", text: $referer)
            HStack(spacing: 12) {
                Button(action: startDirectPlayback) {
                    Label("开始播放", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryActionStyle())
                if let validationMessage {
                    Text(validationMessage).font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
        }
        .padding(20)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private var scopeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectionEyebrow(text: "平台适配")
            Text("宽屏和 tvOS 使用同一横向布局；iPhone 竖屏改为上下排列。界面按钮同时支持触控点击与 tvOS 焦点选择。")
                .font(.system(size: 13))
                .foregroundStyle(Color.tvboxMuted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 3)
    }

    private var playerPreferencesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("播放偏好", systemImage: "play.rectangle.on.rectangle")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Toggle(isOn: $autoNextEpisode) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("播完自动播放下一集")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("只对影视剧集生效，不会自动切换直播频道。")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.tvboxMuted)
                }
            }
            .tint(Color.tvboxAccent)
            Picker("跳过片头", selection: $skipOpeningSeconds) {
                ForEach([0, 15, 30, 45, 60], id: \.self) { seconds in
                    Text(seconds == 0 ? "关闭" : "\(seconds) 秒").tag(seconds)
                }
            }
            .pickerStyle(.menu)
            .foregroundStyle(.white)
            Text("断点续播优先于片头跳过。")
                .font(.system(size: 11))
                .foregroundStyle(Color.tvboxMuted)
        }
        .padding(20)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private var danmakuPreferencesSection: some View {
        DanmakuPreferencesForm()
            .padding(20)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    @ViewBuilder
    private func urlField(_ title: String, text: Binding<String>) -> some View {
        #if os(iOS)
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        #else
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
        #endif
    }

    @ViewBuilder
    private func plainField(_ title: String, text: Binding<String>) -> some View {
        #if os(iOS)
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        TextField(title, text: text)
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
        #endif
    }

    private func startDirectPlayback() {
        let value = directURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), ["http", "https", "rtsp", "rtmp"].contains(url.scheme?.lowercased() ?? "") else {
            validationMessage = "请输入有效的 HTTP、HTTPS、RTSP 或 RTMP 地址。"
            return
        }
        var headers: [String: String] = [:]
        let trimmedUA = userAgent.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReferer = referer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedUA.isEmpty { headers["User-Agent"] = trimmedUA }
        if !trimmedReferer.isEmpty { headers["Referer"] = trimmedReferer }
        validationMessage = nil
        playbackRequest = PlaybackRequest(title: url.lastPathComponent.isEmpty ? "直接播放" : url.lastPathComponent, url: url, headers: headers)
    }
}
