import Foundation
import Testing

@testable import BiliKit

@MainActor
struct AppUpdaterTests {
    private var configuredInfo: [String: Any] {
        [
            "BiliKitUpdaterEnabled": true,
            "SUFeedURL": "https://updates.example.org/appcast.xml",
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString(),
            "SUEnableInstallerLauncherService": true,
            "SUEnableDownloaderService": false,
            "SUVerifyUpdateBeforeExtraction": true,
            "SURequireSignedFeed": true,
            "SUSignedFeedFailureExpirationInterval": 0,
        ]
    }

    @Test
    func incompleteConfigurationLeavesUpdaterUnavailable() {
        let updater = AppUpdater(info: [:])
        #expect(!updater.isConfigured)
        #expect(!updater.canCheckForUpdates)
        #expect(!updater.failedToStart)
        updater.checkForUpdates()
        var info = configuredInfo
        info["BiliKitUpdaterEnabled"] = false
        #expect(!AppUpdater.hasValidConfiguration(info))
        info = configuredInfo
        info["SUPublicEDKey"] = ""
        #expect(!AppUpdater.hasValidConfiguration(info))
        info["SUPublicEDKey"] = Data(repeating: 1, count: 31).base64EncodedString()
        #expect(!AppUpdater.hasValidConfiguration(info))
    }

    @Test
    func feedMustBeCredentialFreeHTTPSAndSigningMustBeEnabled() {
        #expect(AppUpdater.hasValidConfiguration(configuredInfo))
        for feed in [
            "http://updates.example.org/appcast.xml",
            "https://user@updates.example.org/appcast.xml",
            "https://updates.example.org/appcast.xml?key=placeholder",
            "https://updates.example.org/appcast.xml#fragment",
            "https://updates.example.org:8080/appcast.xml",
            "https://updates.example.org/",
        ] {
            var info = configuredInfo
            info["SUFeedURL"] = feed
            #expect(!AppUpdater.hasValidConfiguration(info))
        }
        for key in [
            "SUEnableInstallerLauncherService", "SUVerifyUpdateBeforeExtraction",
            "SURequireSignedFeed",
        ] {
            var info = configuredInfo
            info[key] = false
            #expect(!AppUpdater.hasValidConfiguration(info))
        }
        var info = configuredInfo
        info["SUSignedFeedFailureExpirationInterval"] = 1
        #expect(!AppUpdater.hasValidConfiguration(info))
        info = configuredInfo
        info["SUEnableDownloaderService"] = true
        #expect(!AppUpdater.hasValidConfiguration(info))
    }
}
