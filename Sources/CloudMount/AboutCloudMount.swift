import AppKit
import CloudMountLocalization
import SwiftUI

@MainActor
enum AboutCloudMount {
    static func show() {
        let credits = NSMutableAttributedString(string:
            "\(L10n.string("開發"))：\(AppInformation.developer)\nEmail: \(AppInformation.email)")
        if let url = AppInformation.emailURL {
            credits.addAttribute(.link, value: url,
                range: (credits.string as NSString).range(of: AppInformation.email))
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "CloudMount",
            .applicationVersion: AppInformation.version,
            .version: AppInformation.build,
            .credits: credits
        ])
    }
}

struct CloudMountInfoCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.string("關於 CloudMount")) { AboutCloudMount.show() }
        }
    }
}
