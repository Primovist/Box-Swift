import Foundation

enum SampleCatalog {
    static let streamURL = URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!

    static let items: [MediaItem] = [
        MediaItem(
            id: "demo-live",
            title: "网络视频演示",
            category: "推荐",
            subtitle: "HLS 播放测试",
            summary: "内置演示条目。选择“演示流”可测试 VLC 播放器；也可以在设置页载入 TVBox JSON 目录查看视频源。",
            posterURL: nil,
            episodes: [
                Episode(id: "demo-hls", title: "演示流 · HLS", url: streamURL, headers: [:])
            ]
        ),
        MediaItem(
            id: "demo-movie",
            title: "示例影片",
            category: "电影",
            subtitle: "播放链路示例",
            summary: "这是界面和播放链路的演示数据，不对应任何片源服务。可从设置页加载符合 TVBox-Swift JSON 约定的目录。",
            posterURL: nil,
            episodes: [
                Episode(id: "demo-movie-play", title: "正片 · HLS 演示流", url: streamURL, headers: [:])
            ]
        ),
        MediaItem(
            id: "demo-series",
            title: "示例剧集",
            category: "电视剧",
            subtitle: "第 1 集 · 第 2 集",
            summary: "剧集页面和选集列表示例。演示数据中的两集共用同一测试流。",
            posterURL: nil,
            episodes: [
                Episode(id: "demo-episode-1", title: "第 1 集", url: streamURL, headers: [:]),
                Episode(id: "demo-episode-2", title: "第 2 集", url: streamURL, headers: [:])
            ]
        )
    ]
}
