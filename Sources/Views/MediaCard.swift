import SwiftUI
import CryptoKit
import UIKit

struct MediaArtwork: View {
    let item: MediaItem
    var wide = false
    var showsTitle = true

    private var colors: [Color] {
        let choices: [[Color]] = [
            [Color(red: 0.12, green: 0.25, blue: 0.43), Color(red: 0.35, green: 0.16, blue: 0.35)],
            [Color(red: 0.08, green: 0.38, blue: 0.39), Color(red: 0.12, green: 0.19, blue: 0.39)],
            [Color(red: 0.46, green: 0.18, blue: 0.19), Color(red: 0.22, green: 0.17, blue: 0.39)],
            [Color(red: 0.37, green: 0.30, blue: 0.11), Color(red: 0.15, green: 0.26, blue: 0.31)]
        ]
        let index = abs(item.id.unicodeScalars.reduce(0) { $0 + Int($1.value) }) % choices.count
        return choices[index]
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: proxy.size.width * 0.72)
                    .offset(x: proxy.size.width * 0.43, y: -proxy.size.height * 0.33)
                    .blur(radius: 3)

                if let posterURL = item.posterURL {
                    ZStack {
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                        CachedArtworkImage(url: posterURL)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }

                LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)
                if showsTitle {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.category)
                            .font(.system(size: TVBoxTypography.readable(wide ? 12 : 10, minimum: 23), weight: .bold, design: .rounded))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.75))
                        Text(item.title)
                            .font(.system(size: TVBoxTypography.readable(wide ? 30 : 17), weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(TVBoxTypography.minimumScaleFactor)
                        if wide && !item.subtitle.isEmpty {
                            Text(item.subtitle)
                                .font(.system(size: TVBoxTypography.readable(14, minimum: 23), weight: .medium))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .padding(wide ? 26 : 14)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: wide ? 24 : 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: wide ? 24 : 17, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
        }
        .accessibilityLabel(showsTitle ? "\(item.title)，\(item.category)" : "\(item.category)封面图片")
    }
}

@MainActor
enum ArtworkImageCache {
    private static let memory: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    private static var inFlight: [URL: (UUID, Task<UIImage?, Never>)] = [:]
    private static var generation = 0

    static func image(for url: URL) async -> UIImage? {
        if let cached = memory.object(forKey: url as NSURL) { return cached }
        if let (_, task) = inFlight[url] { return await task.value }

        let token = UUID()
        let currentGeneration = generation
        let key = cacheKey(for: url)
        let task = Task<UIImage?, Never> {
            if let data = await ArtworkDiskStore.shared.data(for: key), let image = UIImage(data: data) {
                await store(image, data: data, for: url, key: key, token: token, generation: currentGeneration)
                return image
            }

            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue("image/jpeg,image/png,image/gif,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
            if let scheme = url.scheme, let host = url.host {
                request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                  let image = UIImage(data: data) else { return nil }
            await store(image, data: data, for: url, key: key, token: token, generation: currentGeneration)
            return image
        }
        inFlight[url] = (token, task)
        let image = await task.value
        if inFlight[url]?.0 == token { inFlight[url] = nil }
        return image
    }

    static func clear() async {
        generation += 1
        inFlight.values.forEach { $0.1.cancel() }
        inFlight.removeAll()
        memory.removeAllObjects()
        await ArtworkDiskStore.shared.clear()
    }

    static func cachedSize() async -> Int64 {
        await ArtworkDiskStore.shared.cachedSize()
    }

    private static func store(_ image: UIImage, data: Data, for url: URL, key: String, token: UUID, generation taskGeneration: Int) async {
        guard generation == taskGeneration else { return }
        let decodedCost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        memory.setObject(image, forKey: url as NSURL, cost: decodedCost)
        await ArtworkDiskStore.shared.write(data, for: key, generation: taskGeneration)
        if inFlight[url]?.0 == token { inFlight[url] = nil }
    }

    private static func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return digest
    }
}

private actor ArtworkDiskStore {
    static let shared = ArtworkDiskStore()
    private var generation = 0

    private var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TVBoxPosterImages", isDirectory: true)
    }

    func data(for key: String) -> Data? {
        try? Data(contentsOf: fileURL(for: key))
    }

    func write(_ data: Data, for key: String, generation expectedGeneration: Int) {
        guard generation == expectedGeneration else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: key), options: .atomic)
    }

    func clear() {
        generation += 1
        try? FileManager.default.removeItem(at: directory)
    }

    func cachedSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return enumerator.compactMap { $0 as? URL }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(Int64(0)) { $0 + Int64($1) }
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent(key).appendingPathExtension("image")
    }
}

struct CachedArtworkImage: View {
    let url: URL
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Color.clear
            }
        }
        .task(id: url) {
            let requestedURL = url
            let loadedImage = await ArtworkImageCache.image(for: requestedURL)
            guard !Task.isCancelled, requestedURL == url else { return }
            image = loadedImage
        }
    }
}

struct MediaCard: View {
    let item: MediaItem

    var body: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 8) {
                MediaArtwork(item: item, showsTitle: false)
                    .aspectRatio(0.72, contentMode: .fit)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(.system(size: TVBoxTypography.readable(15), weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                    let metadata = item.subtitle.isEmpty ? item.category : item.subtitle
                    Text(metadata.isEmpty ? " " : metadata)
                        .font(.system(size: TVBoxTypography.readable(12, minimum: 23), weight: .medium))
                        .foregroundStyle(Color.tvboxMuted)
                        .lineLimit(1)
                        .frame(minHeight: TVBoxTypography.readable(15, minimum: 25), alignment: .topLeading)
                        .accessibilityHidden(metadata.isEmpty)
                }
                .padding(.horizontal, 9)
                .padding(.bottom, 8)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .platformFocusableButtonStyle()
        .accessibilityHint("打开详情和选集")
    }
}
