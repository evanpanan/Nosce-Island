import SwiftUI

@main struct NosceIslandApp: App {
    @StateObject private var store = MarketStore()
    @AppStorage("appearanceV1") private var appearance = "dark"
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(store).environmentObject(store.commerce)
                .preferredColorScheme(appearance == "system" ? nil : appearance == "light" ? .light : .dark)
                .onChange(of: phase) { newPhase in
                    if newPhase == .active { store.startRefreshing(); Task { await store.commerce.start() } }
                    else { store.stopRefreshing() }
                }
                .onOpenURL { _ in store.syncActivityState() }
        }
    }
}
