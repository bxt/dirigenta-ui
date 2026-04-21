import Foundation
import Combine

final class AppState: ObservableObject {
    @Published var accessToken: String {
        didSet {
            do {
                if accessToken.isEmpty {
                    try KeychainService.delete("dirigeraAccessToken")
                } else {
                    try KeychainService.set(accessToken, for: "dirigeraAccessToken")
                }
            } catch {
                print("[Keychain] Error: \(error)")
            }
        }
    }
    @Published var pinnedLightId: String? {
        didSet { UserDefaults.standard.set(pinnedLightId, forKey: "pinnedLightId") }
    }
    @Published var pinnedLightIsOn: Bool = false
    let mdns = MDNSResolver()

    init() {
        accessToken = (try? KeychainService.get("dirigeraAccessToken")) ?? ""
        pinnedLightId = UserDefaults.standard.string(forKey: "pinnedLightId")
    }
}
