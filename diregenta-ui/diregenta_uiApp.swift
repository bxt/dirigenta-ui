//
//  diregenta_uiApp.swift
//  diregenta-ui
//
//  Created by Bernhard Häussner on 18.02.26.
//

import SwiftUI

@main
struct diregenta_uiApp: App {
    @State private var accessToken: String = (try? KeychainService.get("dirigeraAccessToken")) ?? ""
    @StateObject private var mdns = MDNSResolver()

    var body: some Scene {
        MenuBarExtra("diregenta-ui", systemImage: "house") {
            MenuContent(accessToken: $accessToken)
                .environmentObject(mdns)
        }
        .menuBarExtraStyle(.window)
    }
}


