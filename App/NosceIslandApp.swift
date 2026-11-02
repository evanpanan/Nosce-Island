import SwiftUI

@main struct NosceIslandApp: App {
    @StateObject private var store = MarketStore()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).environmentObject(store.commerce)
                .preferredColorScheme(.dark)
                .onChange(of: phase) { newPhase in
                    if newPhase == .active { store.startRefreshing(); Task { await store.commerce.start() } }
                    else { store.stopRefreshing() }
                }
                .onOpenURL { _ in store.syncActivityState() }
        }
    }
}
