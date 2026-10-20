import SwiftUI

@main
struct AutoDroidApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .tint(Color(red: 0.06, green: 0.48, blue: 0.44))
                .task(id: phase) {
                    guard phase == .active else { return }
                    while !Task.isCancelled {
                        await model.refresh()
                        try? await Task.sleep(for: .seconds(3))
                    }
                }
        }
    }
}
