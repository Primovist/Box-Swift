import SwiftUI

struct MediaArtwork: View {
    let item: MediaItem
    var wide = false

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
                    AsyncImage(url: posterURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
                }

                LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.category)
                        .font(.system(size: wide ? 12 : 10, weight: .bold, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(item.title)
                        .font(.system(size: wide ? 30 : 17, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    if wide && !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                .padding(wide ? 26 : 14)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipShape(RoundedRectangle(cornerRadius: wide ? 24 : 17, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: wide ? 24 : 17, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
        }
        .accessibilityLabel("\(item.title)，\(item.category)")
    }
}

struct MediaCard: View {
    let item: MediaItem

    var body: some View {
        NavigationLink(value: item) {
            VStack(alignment: .leading, spacing: 9) {
                MediaArtwork(item: item)
                    .aspectRatio(0.72, contentMode: .fit)
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(item.sourceName) · \(item.subtitle.isEmpty ? item.category : item.subtitle)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.tvboxMuted)
                    .lineLimit(1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(FocusAwareButtonStyle())
        .accessibilityHint("打开详情和选集")
    }
}
