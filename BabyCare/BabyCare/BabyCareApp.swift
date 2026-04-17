//
//  BabyCareApp.swift
//  BabyCare
//
//  Created by Peiqi Tang on 2/12/26.
//

import SwiftUI
import SwiftData
import UIKit

@main
struct BabyCareApp: App {
    @StateObject private var wearablesManager = WearablesManager()

    init() {
        let tabBarAppearance = UITabBar.appearance()
        tabBarAppearance.itemPositioning = .fill
        tabBarAppearance.itemWidth = 0
        tabBarAppearance.itemSpacing = 0
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(wearablesManager)
                .onOpenURL { url in
                    wearablesManager.handleIncomingURL(url)
                }
        }
        .modelContainer(for: ActivityEventRecord.self)
    }
}
