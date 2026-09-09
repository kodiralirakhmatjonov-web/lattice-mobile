import SwiftUI
import UIKit

struct BusinessPrivateImage<Placeholder: View>: View {
    let path: String
    let contentMode: ContentMode
    private let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var failed = false

    init(
        path: String,
        contentMode: ContentMode = .fill,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.path = path
        self.contentMode = contentMode
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
                    .overlay {
                        if !failed {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
        }
        .task(id: path) {
            await load()
        }
    }

    @MainActor
    private func load() async {
        image = nil
        failed = false
        do {
            let data = try await APIClient.shared.privateMedia(path: path)
            guard let resolved = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
            image = resolved
        } catch {
            failed = true
        }
    }
}
