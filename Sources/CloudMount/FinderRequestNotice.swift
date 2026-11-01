import SwiftUI

struct FinderRequestNotice: View {
    @ObservedObject var opener: FinderOpener
    var body: some View {
        if let message = opener.message {
            HStack(alignment: .top, spacing: 10) {
                if opener.busy { ProgressView().controlSize(.small) }
                else { Image(systemName: opener.outcome == .accepted ? "folder" : "info.circle") }
                Text(message).font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
                if !opener.busy {
                    Button { opener.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).help(L10n.string("關閉"))
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
