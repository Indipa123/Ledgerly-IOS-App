import SwiftUI

struct ReceiptCaptureFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var imageData: [Data]?
    let onError: (String) -> Void
    let onUse: (ReviewedReceipt) -> Void

    init(initialImageData: Data?, onError: @escaping (String) -> Void,
         onUse: @escaping (ReviewedReceipt) -> Void) {
        _imageData = State(initialValue: initialImageData.map { [$0] })
        self.onError = onError
        self.onUse = onUse
    }

    var body: some View {
        Group {
            if let imageData {
                ReceiptReviewScreen(imagePages: imageData, onCancel: { dismiss() }) { receipt in
                    onUse(receipt)
                    dismiss()
                }
            } else {
                ReceiptCamera(onImages: { imageData = $0 }, onError: { message in
                    onError(message)
                    dismiss()
                }, onCancel: { dismiss() })
                .ignoresSafeArea()
            }
        }
    }
}
