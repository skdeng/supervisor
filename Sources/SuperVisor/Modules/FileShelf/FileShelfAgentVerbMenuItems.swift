import SwiftUI

/// Shared verb menu content for the toolbar menu and per-file context menus.
struct FileShelfAgentVerbMenuItems: View {
    @ObservedObject var store: FileShelfStore
    @ObservedObject var file: StagedFile
    var includesDivider = false
    var showsUnavailableMessage = true

    @ViewBuilder
    var body: some View {
        let verbs = store.agentVerbs(for: file.id)
        if verbs.isEmpty {
            if showsUnavailableMessage {
                Button("No agent actions for this file") {}
                    .disabled(true)
            }
        } else {
            if includesDivider {
                Divider()
            }
            ForEach(verbs) { verb in
                Button {
                    store.dispatchAgentVerb(verb, on: file.id)
                } label: {
                    Label(verb.title, systemImage: verb.systemImage)
                }
            }
        }
    }
}
