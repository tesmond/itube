import ITubeCore
import SwiftUI

@main
struct ITubeApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var bootstrap: Bootstrap

    enum Bootstrap {
        case ready(AppEnvironment)
        case failed(String)
    }

    init() {
        // Provider set is a build-time decision (ADR §27). Build with -D APPSTORE to exclude the YouTube provider.
        #if APPSTORE
        let providers: any ProviderSet = AppStoreProviderSet()
        #else
        let providers: any ProviderSet = FullProviderSet()
        #endif
        do { _bootstrap = State(initialValue: .ready(try AppEnvironment.live(providers: providers))) }
        catch { _bootstrap = State(initialValue: .failed(error.localizedDescription)) }
    }

    var body: some Scene {
        WindowGroup {
            switch bootstrap {
            case .ready(let app):
                RootView(app: app)
                    .onChange(of: scenePhase) { _, phase in
                        app.coordinator.lifecycleChanged(phase == .active ? .active : phase == .background ? .background : .inactive)
                    }
            case .failed(let message):
                ContentUnavailableView("itube couldn’t start", systemImage: "exclamationmark.triangle", description: Text(message))
            }
        }
    }
}

/// Orientation: portrait-first UI, landscape for full-screen playback (ADR §58).
@MainActor
enum OrientationController {
    static var mask: UIInterfaceOrientationMask = .portrait

    static func allowLandscape(_ allowed: Bool) {
        mask = allowed ? .allButUpsideDown : .portrait
        update(mask: allowed ? .allButUpsideDown : .portrait)
    }

    static func rotate(toLandscape: Bool) {
        update(mask: toLandscape ? .landscape : .portrait)
    }

    private static func update(mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { OrientationController.mask }
    }
}
