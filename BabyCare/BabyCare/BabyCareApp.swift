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

        // SwiftUI Form can still be backed by opaque UIKit views.
        // Clear those container backgrounds so the shared animated tab background shows through.
        UITableView.appearance().backgroundColor = .clear
        UITableViewCell.appearance().backgroundColor = .clear
        UITableViewHeaderFooterView.appearance().tintColor = .clear
        UICollectionView.appearance().backgroundColor = .clear
        UICollectionViewCell.appearance().backgroundColor = .clear
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
