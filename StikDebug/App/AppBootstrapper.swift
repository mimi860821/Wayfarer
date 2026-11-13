//
//  AppBootstrapper.swift
//  StikDebug
//

import Foundation
import ObjectiveC.runtime
import UIKit

enum AppBootstrapper {
    static func configure() {
        IdeviceLogFileManager.shared.prepareForLogging()
        NetworkStateMonitor.shared.start()
        registerDefaultSettings()
        ensureKeepAliveSelection()
        applyDocumentPickerCopyWorkaround()
    }

    private static func registerDefaultSettings() {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let enableAdvancedOptions = os.majorVersion >= 19

        UserDefaults.standard.register(defaults: [
            "enableAdvancedOptions": enableAdvancedOptions,
            UserDefaults.Keys.txmOverride: false,
            UserDefaults.Keys.confirmExternalJITRequests: true,
            // Background location alone keeps the app alive and runs cooler than also
            // playing silent audio, so audio is off unless the user turns it on.
            "keepAliveAudio": false,
            "keepAliveLocation": true
        ])
    }

    private static func ensureKeepAliveSelection() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "keepAliveAudio"), !defaults.bool(forKey: "keepAliveLocation") {
            defaults.set(true, forKey: "keepAliveAudio")
        }
    }

    private static func applyDocumentPickerCopyWorkaround() {
        let fixedSelector = NSSelectorFromString("fix_initForOpeningContentTypes:asCopy:")
        let originalSelector = #selector(UIDocumentPickerViewController.init(forOpeningContentTypes:asCopy:))

        guard let fixedMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, fixedSelector),
              let originalMethod = class_getInstanceMethod(UIDocumentPickerViewController.self, originalSelector) else {
            return
        }

        method_exchangeImplementations(originalMethod, fixedMethod)
    }
}
