import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var catalog: CatalogStore
    @AppStorage("tvbox.autoNext") private var autoNextEpisode = true
    @AppStorage("tvbox.skipOpeningSeconds") private var skipOpeningSeconds = 0
    @AppStorage("tvbox.vlc.hardwareDecoding") private var vlcHardwareDecoding = true
    @AppStorage("tvbox.vlc.networkCachingMilliseconds") private var vlcNetworkCachingMilliseconds = 3000
    @AppStorage("tvbox.vlc.deinterlace") private var vlcDeinterlace = 0
    @State private var endpoint = ""
    @FocusState private var isEndpointFocused: Bool
    @State private var imageCacheSize: Int64 = 0
    @State private var cacheMessage: String?
    @State private var isConfirmingServerRemoval = false
    @State private var isConfirmingCacheClear = false

    private var liveChannelCountText: String {
        if catalog.isLoadingLive { return "载入中…" }
        if catalog.hasLoadedLive {
            return "\(catalog.liveGroups.reduce(0) { $0 + $1.channels.count })"
        }
        return "未载入"
    }

    var body: some View {
        Form {
            Section {
                urlField("https://example.com/tvbox.json", text: $endpoint)
                #if os(iOS)
                .listRowSeparator(.hidden)
                #endif

                Button {
                    isEndpointFocused = false
                    Task { await catalog.loadConfiguration(from: endpoint, restoreRemovedSites: true) }
                } label: {
                    Group {
                        if catalog.isLoading {
                            ProgressView()
                        } else {
                            Text("载入配置")
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .center)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(catalog.isLoading ? "正在载入配置" : "载入配置")
                .disabled(catalog.isLoading || endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #if os(iOS)
                .listRowSeparator(.hidden)
                #endif

                if !catalog.savedSourceURLs.isEmpty {
                    Menu {
                        ForEach(catalog.savedSourceURLs, id: \.self) { address in
                            Button {
                                isEndpointFocused = false
                                endpoint = address
                                Task { await catalog.loadConfiguration(from: address) }
                            } label: {
                                Text(address)
                                    .fontWeight(address == catalog.sourceURL ? .semibold : .regular)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text("已登记服务器")
                            Spacer(minLength: 12)
                            Text("\(catalog.savedSourceURLs.count)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Button("删除当前登记服务器…", role: .destructive) {
                    isConfirmingServerRemoval = true
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(catalog.sourceURL.isEmpty)
            } header: {
                Text("片源配置")
            } footer: {
                Text("支持顶层 sites 或 video.sites；站点 type 0、1、4。支持静态网页媒体地址提取和 JSON 解析器。动态网页嗅探、Spider（type 3）不执行。")
            }

            if let configuration = catalog.configuration {
                Section("当前视频源") {
                    if !catalog.availableSites.isEmpty {
                        Picker("站点", selection: Binding(
                            get: { catalog.selectedSite?.key ?? "" },
                            set: { catalog.selectSite($0) }
                        )) {
                            ForEach(catalog.availableSites) { site in
                                Text(site.name).tag(site.key)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Text(configuration.sites.isEmpty
                             ? "此配置没有可用的视频站点。"
                             : "所有视频站点均已移除；重新载入配置可恢复。")
                            .foregroundStyle(.secondary)
                    }

                    statisticRow("可用站点", value: "\(catalog.availableSites.count)")
                    statisticRow("可用解析器", value: "\(configuration.parsers.filter { [0, 1].contains($0.type) }.count)")
                    statisticRow("直播频道", value: liveChannelCountText)
                    if !configuration.epgURL.isEmpty {
                        Text("已配置节目单")
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
                .pickerStyle(.menu)
                Text("断点续播优先于片头跳过。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("VLC 高级设置") {
                Toggle("硬件解码", isOn: $vlcHardwareDecoding)
                Text("默认开启。修改后重新打开播放页生效。关闭后由软件解码，设备负载可能增加。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("网络缓存", selection: $vlcNetworkCachingMilliseconds) {
                    Text("1 秒").tag(1000)
                    Text("3 秒（推荐）").tag(3000)
                    Text("5 秒").tag(5000)
                    Text("10 秒").tag(10000)
                }
                .pickerStyle(.menu)
                Text("较长缓存可能减少网络波动导致的卡顿，也会增加开播和直播延迟。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Picker("隔行视频处理", selection: $vlcDeinterlace) {
                    Text("关闭").tag(0)
                    Text("自动检测").tag(-1)
                    Text("强制开启").tag(1)
                }
                .pickerStyle(.menu)
                Text("默认关闭。自动检测和强制开启会启用 VLC 的去隔行滤镜，效果与稳定性取决于设备和视频。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("图片缓存") {
                statisticRow("已缓存", value: ByteCountFormatter.string(fromByteCount: imageCacheSize, countStyle: .file))
                Text("包括影视海报和直播台标。清理后会在下次显示时重新下载。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    isConfirmingCacheClear = true
                } label: {
                    Text("清理缓存")
                }
            }
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
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
        .confirmationDialog("删除当前登记服务器？", isPresented: $isConfirmingServerRemoval, titleVisibility: .visible) {
            Button("删除服务器", role: .destructive) {
                catalog.removeCurrentServer()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将从已登记服务器列表中删除当前地址，并清除该服务器保存的配置和目录状态。")
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
            .focused($isEndpointFocused)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
        #else
        TextField(title, text: text)
            .focused($isEndpointFocused)
            .autocorrectionDisabled()
        #endif
    }

    private func statisticRow(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}
