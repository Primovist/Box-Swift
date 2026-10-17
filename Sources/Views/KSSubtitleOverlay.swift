import KSPlayer
import SwiftUI
import UIKit

struct KSSubtitleOverlay: View {
    @ObservedObject var model: SubtitleModel

    var body: some View {
        VStack {
            Spacer()
            ForEach(model.parts) { part in
                if let image = part.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 520, maxHeight: 180)
                } else if let text = part.text {
                    Text(AttributedString(text))
                        .font(.system(size: SubtitleModel.textFontSize, weight: SubtitleModel.textBold ? .bold : .regular))
                        .foregroundStyle(SubtitleModel.textColor)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black.opacity(0.95), radius: 2, x: 1, y: 1)
                        .padding(.horizontal, 22)
                }
            }
            .padding(.bottom, 46)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
