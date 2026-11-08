import CrowsnestUI
import SwiftUI
#if canImport(CrowsnestPro)
import CrowsnestPro
#endif

@main
struct CrowsnestPadApp: App {
    init() {
        #if canImport(CrowsnestPro)
        ProExtension.register()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
