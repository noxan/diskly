//
//  DisklyApp.swift
//  Diskly
//
//  Created by Rick on 6/28/26.
//

import Sparkle
import SwiftUI

@main
struct DisklyApp: App {
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}
