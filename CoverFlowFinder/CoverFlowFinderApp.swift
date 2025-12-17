import SwiftUI

@main
struct CoverFlowFinderApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.automatic)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SidebarCommands()
            ToolbarCommands()
        }
    }
}
