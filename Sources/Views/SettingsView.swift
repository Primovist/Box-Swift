import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var catalog: CatalogStore
    @AppStorage("tvbox.autoNext") private var autoNextEpisode = true
    @AppStorage("tvbox.skipOpeningSeconds") private var skipOpeningSeconds = 0
    @State private var endpoint = ""
    @State private var imageCacheSize: Int64 = 0
    @State private var cacheMessage: String?
    @State private var isConfirmingRestore = false
    @State private var isConfirmingCacheClear = false

    private var liveChannelCountText: String {
        if catalog.isLoadingLive { return "载入中…" }
        guard catalog.hasLoadedLive || catalog.configuration?.liveURLs.isEmpty == true else {
            return "未载入"
        }
        return "\(catalog.liveGroups.reduce(0) { $0 + $1.channels.count })"
    }

    var body: some View {
        Form {
            Section {
                urlField("https://example.com/tvbox.json", text: $endpoint)

                Button {
                    Task { await catalog.loadConfiguration(from: endpoint, restoreRemovedSites: true) }
                } label: {
                    HStack {
                        Spacer(minLength: 0)
                        if catalog.isLoading {
                            ProgressView()
                        } else {
                            Label("载入配置", systemImage: "arrow.down.circle")
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(catalog.isLoading || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("恢复演示数据…", role: .destructive) {
                    isConfirmingRestore = true
                }
            } header: {
                Text("片源配置")
            } footer: {
                Text("支持顶层 sites 或 video.sites；站点 type 0、1、4。支持静态网页媒体地址提取和 JSON 解析器。动态网页嗅探、Spider（type 3）不执行。")
            }

            if let configuration = catalog.configuration, !catalog.availableSites.isEmpty {
                Section("当前视频源") {
                    Picker("站点", selection: Binding(
                        get: { catalog.selectedSiteKey },
                        set: { catalog.selectSite($0) }
                    )) {
                        ForEach(catalog.availableSites) { site in
                            Text(site.name).tag(site.key)
                        }
                    }

                    Button(role: .destructive) {
                        catalog.removeSelectedSite()
                    } label: {
                        Label("删除当前视频源", systemImage: "trash")
                    }
                    .disabled(catalog.selectedSite == nil)

                    LabeledContent("可用站点", value: "\(catalog.availableSites.count)")
                    LabeledContent("可用解析器", value: "\(configuration.parsers.filter { [0, 1].contains($0.type) }.count)")
                    LabeledContent("直播频道", value: liveChannelCountText)
                    if !configuration.epgURL.isEmpty {
                        Label("已配置节目单", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let loadMessage = catalog.loadMessage, !loadMessage.contains("个条目") {
                Section("配置状态") {
                    Text(loadMessage)
                        .foregroundStyle(loadMessage.localizedCaseInsensitiveContains("失败") || loadMessage.localizedCaseInsensitiveContains("没有") ? Color.orange : Color.secondary)
                }
            }

            Section("播放偏好") {
                Toggle("播完自动播放下一集", isOn: $autoNextEpisode)
                Text("只对影视剧集生效，不会自动切换直播频道。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("跳过片头", selection: $skipOpeningSeconds) {
                    ForEach([0, 15, 30, 45, 60], id: \.self) { seconds in
                        Text(seconds == 0 ? "关闭" : "\(seconds) 秒").tag(seconds)
                    }
                }
                Text("断点续播优先于片头跳过。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("图片缓存") {
                LabeledContent("已缓存", value: ByteCountFormatter.string(fromByteCount: imageCacheSize, countStyle: .file))
                Text("包括影视海报和直播台标。清理后会在下次显示时重新下载。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    isConfirmingCacheClear = true
                } label: {
                    Label("清理缓存", systemImage: "trash")
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 1120)
        .frame(maxWidth: .infinity)
        .onAppear {
            endpoint = catalog.sourceURL
            Task { imageCacheSize = await ArtworkImageCache.cachedSize() }
            catalog.loadLive()
        }
        .onChange(of: catalog.configuration) { _, configuration in
            guard configuration != nil else { return }
            catalog.loadLive()
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
        .confirmationDialog("清除图片缓存？", isPresented: $isConfirmingCacheClear, titleVisibility: .visible) {
            Button("清除缓存", role: .destructive) {
                Task {
                    await ArtworkImageCache.clear()
                    imageCacheSize = await ArtworkImageCache.cachedSize()
                    cacheMessage = "图片缓存已清理。"
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已缓存的图片会在下次显示时重新下载。")
        }
        .alert("图片缓存", isPresented: Binding(
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
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        #else
        TextField(title, text: text)
            .autocorrectionDisabled()
        #endif
    }
}
