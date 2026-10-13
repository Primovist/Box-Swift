import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var catalog: CatalogStore
    @AppStorage("tvbox.autoNext") private var autoNextEpisode = true
    @AppStorage("tvbox.skipOpeningSeconds") private var skipOpeningSeconds = 0
    @State private var endpoint = ""
    @State private var posterCacheSize: Int64 = 0
    @State private var cacheMessage: String?
    @State private var isConfirmingRestore = false
    @State private var isConfirmingCacheClear = false

    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= geometry.size.height
            ZStack {
                ScreenBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: wide ? 26 : 21) {
                        titleBlock
                        sourceSection
                        scopeSection
                        playerPreferencesSection
                        posterCacheSection
                    }
                    .frame(maxWidth: 1120, alignment: .leading)
                    .padding(.horizontal, wide ? 72 : 20)
                    .padding(.top, wide ? 28 : 16)
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity)
                }
            }
            .onAppear {
                endpoint = catalog.sourceURL
                Task { posterCacheSize = await PosterImageCache.cachedSize() }
            }
            .onChange(of: catalog.sourceURL) { _, value in
                endpoint = value
            }
            .confirmationDialog("恢复演示数据？", isPresented: $isConfirmingRestore, titleVisibility: .visible) {
                Button("恢复演示数据", role: .destructive) {
                    endpoint = ""
                    catalog.restoreSamples()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("当前片源和目录状态将切换为内置演示数据。已保存的片源地址仍会保留。")
            }
            .confirmationDialog("清除海报缓存？", isPresented: $isConfirmingCacheClear, titleVisibility: .visible) {
                Button("清除缓存", role: .destructive) {
                    Task {
                        await PosterImageCache.clear()
                        posterCacheSize = await PosterImageCache.cachedSize()
                        cacheMessage = "海报缓存已清理。"
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("已缓存的图片会在下次显示时重新下载。")
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionEyebrow(text: "片源配置")
            Text("连接 tvbox.json")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primary)
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
                .foregroundStyle(Color.primary)
            urlField("https://example.com/tvbox.json", text: $endpoint)
            HStack(spacing: 10) {
                Button {
                    Task { await catalog.loadConfiguration(from: endpoint, restoreRemovedSites: true) }
                } label: {
                    if catalog.isLoading {
                        ProgressView().tint(.white).frame(minWidth: 70, minHeight: 44)
                    } else {
                        Label("载入配置", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(PrimaryActionStyle())
                .disabled(catalog.isLoading || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("恢复演示") { isConfirmingRestore = true }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 15)
                .frame(minHeight: 44)
                .background(Color.tvboxSurface, in: Capsule())
                .buttonStyle(FocusAwareButtonStyle())
            }

            if let configuration = catalog.configuration {
                if !catalog.availableSites.isEmpty {
                    HStack(spacing: 10) {
                        Picker("当前站点", selection: Binding(
                            get: { catalog.selectedSiteKey },
                            set: { catalog.selectSite($0) }
                        )) {
                            ForEach(catalog.availableSites) { site in
                                Text(site.name).tag(site.key)
                            }
                        }
                        .pickerStyle(.menu)

                        Button(role: .destructive) {
                            catalog.removeSelectedSite()
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .disabled(catalog.selectedSite == nil)
                        .accessibilityLabel("删除当前所选视频源")
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.tvboxCyan)
                    Text("当前有 \(catalog.availableSites.count) 个可用站点、\(configuration.parsers.count) 个解析器、\(configuration.liveGroups.reduce(0) { $0 + $1.channels.count }) 个内置直播频道\(configuration.epgURL.isEmpty ? "" : "，已配置节目单")。")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.82))
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
        .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                .foregroundStyle(Color.primary)
            Toggle(isOn: $autoNextEpisode) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("播完自动播放下一集")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primary)
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
            .foregroundStyle(Color.primary)
            Text("断点续播优先于片头跳过。")
                .font(.system(size: 11))
                .foregroundStyle(Color.tvboxMuted)
        }
        .padding(20)
        .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private var posterCacheSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("海报缓存", systemImage: "photo.stack")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Color.primary)
            Text("已缓存 \(ByteCountFormatter.string(fromByteCount: posterCacheSize, countStyle: .file))。清理后，海报会在下次显示时重新下载。")
                .font(.system(size: 12))
                .foregroundStyle(Color.tvboxMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button(role: .destructive) { isConfirmingCacheClear = true } label: {
                Label("清理缓存", systemImage: "trash")
                    .frame(maxWidth: .infinity, minHeight: 42)
            }
            .buttonStyle(.bordered)
        }
        .padding(20)
        .background(Color.tvboxSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .alert("海报缓存", isPresented: Binding(
            get: { cacheMessage != nil },
            set: { if !$0 { cacheMessage = nil } }
        )) {
            Button("好", role: .cancel) { cacheMessage = nil }
        } message: {
            Text(cacheMessage ?? "")
        }
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

}
