# TV Box

基于 SwiftUI 的 iOS / tvOS 客户端，读取 Android Box 格式的 `tvbox.json` 配置。两个平台共用 API 和播放器模型。tvOS 与 iOS 横屏使用宽屏浏览布局；iPhone 竖屏会调整控件和内容排列，适配触控操作。tvOS 提供焦点分区、方向键焦点移动和播放器焦点样式。

## `tvbox.json` 支持的功能

- 从根节点 `sites` 或 `video.sites` 读取站点。
- 支持 type `0` XML API、type `1` JSON API 和 type `4` JSON HTTP API 站点；跳过 Spider 站点（`type: 3`）。
- 支持分类、分类筛选、分页列表、单站或全站搜索、延迟加载详情、多播放线路和剧集列表。全站搜索结果可按来源继续分页；详情页可切换到同名内容的其他来源。
- 支持 JSON 解析器（`type: 1`）和静态网页 URL 提取（`type: 0`）。tvOS 不支持动态 JavaScript 网页嗅探，因此不模拟此功能。媒体地址为直链时可直接播放。
- 支持配置内联 `lives` 频道及远程 TXT / M3U 频道列表，读取频道台标、M3U User-Agent / Referer / Cookie 元数据和密码保护分组。`livePlayHeaders` 规则按频道 URL 匹配。EPG 支持日期切换和回看 URL 模板，包括 PLTV `playseek` URL。
- 支持与 VLC 播放时间同步的 XML 弹幕，包含滚动、反向滚动、顶部、底部和基础定位弹幕。视频记录中的 `danmaku` / `vod_danmaku` 地址，以及 type=4 播放响应中的 `danmaku` 地址会直接加载；播放器也支持通过可配置的 DandanPlay 兼容 `danmu_api` 在线搜索作品和剧集。搜索结果会显示作品类型、年份和集数以区分同名条目；剧集会优先列出与当前集数匹配的候选，需手动确认后加载。定位弹幕的复杂动画效果尚未完整移植。
- 弹幕设置包括显示开关、速度、字号、可见行数、透明度和随机颜色。弹幕 API 地址及显示偏好保存在本机。
- 本机保存收藏、最近搜索、最近播放剧集和播放进度。首页壁纸从配置读取；搜索范围、自动连播、片头跳过和画面比例偏好保存在本机。

在 **设置 → tvbox.json 地址** 中粘贴 `tvbox.json` 文件地址。弹幕服务地址可在 **设置 → 弹幕源** 中配置。最小配置示例：

```json
{
  "sites": [
    {
      "key": "example",
      "name": "Example API",
      "type": 1,
      "api": "https://example.com/api.php/provide/vod/",
      "searchable": 1,
      "quickSearch": 1,
      "filterable": 1
    }
  ],
  "parses": [
    {
      "name": "JSON parser",
      "type": 1,
      "url": "https://example.com/parse?url="
    }
  ]
}
```

站点必须包含非空的 `key` 和 `api`。数值开关可写成数字或数字字符串。JSON API 播放记录使用常见的 `vod_play_from`（以 `$$$` 分隔线路）和 `vod_play_url`（以 `#` 分隔剧集，第一个 `$` 分隔剧集名称与地址）字段。收藏和历史记录会保存内容快照，因此来源暂时不可用时仍会显示。

## 播放器

播放器基于 VLC，并启用 VLC 硬件解码选项，必要时可回退到软件解码。功能包括暂停与继续、进度条、前后跳转 15 秒、上一集 / 下一集或频道、播放中切换线路、播放速度、画面比例、音轨与字幕选择、片头跳过设置、自动连播和续播。常见播放请求头会传给 VLC。直播流被 VLC 判定为不可 seek 时不显示进度跳转控件。

iOS 竖屏将播放、暂停和跳转按钮放在屏幕中央，进度条与播放选项放在底部；横屏和 tvOS 使用宽屏布局。播放画面单击可显示或隐藏控件；双击中央区域可暂停或继续，双击左右区域可前后跳转 15 秒；左右滑动调整进度，左侧上下滑动调整亮度，右侧上下滑动调整音量。

## 在 Xcode 中打开

1. 使用安装了 iOS 和 tvOS SDK 的完整 Xcode 打开 `TVBoxSwift.xcodeproj`。
2. 选择 `TVBox-iOS` 或 `TVBox-tvOS` scheme，在模拟器或设备上运行。
3. 等待 Swift Package Manager 获取 VideoLAN VLCKit `4.0.0-a25`。设备构建需要配置签名团队。

项目最低支持 iOS 26.0 和 tvOS 26.0。推送到 `main`、向 `main` 提交 Pull Request 或手动运行 GitHub Actions 时，工作流会分别构建 iOS 与 tvOS 设备版本，将未签名 `.app` 打包为 `.ipa` 并保留 7 天。安装到设备或发布前仍需进行签名；真实流媒体和弹幕播放也需后续在设备上验证。失败任务可从对应的 Actions 运行页面重新执行。

## 暂未移植的功能

当前不包含 Spider / QuickJS / Python 运行时、动态 JavaScript 网页嗅探、P2P、下载、Android 本地文件与网盘接入，以及 Android 本地 HTTP 控制服务。应用使用本机 `UserDefaults` 快照，不使用 Android Room 数据库，也不会在设备间同步数据。弹幕定位特效动画，以及覆盖层在真实设备上的时序与渲染表现，需要后续通过 GitHub Actions / Xcode 工作流配合设备验证。
