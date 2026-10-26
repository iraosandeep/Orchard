// What a new chat shows before the first message.
import SwiftUI

struct EmptyChat: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "leaf").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("Orchard").font(.title2.bold())
            Text("Chat with Apple's on-device model. Replies are drafts — check facts and code.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            Text("Type **/** for tasks")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
        }
        .padding(30)
    }
}
