import ProjectDescription

let appInfoPlist: [String: Plist.Value] = [
    "CFBundleDisplayName": "Stashy",
    "CFBundleShortVersionString": "0.1.0",
    "CFBundleVersion": "1",
    "UILaunchScreen": [:],
    "UISupportsDocumentBrowser": false,
    "NSPhotoLibraryAddUsageDescription": "Stashy saves media to Photos only when you ask it to.",
    "CFBundleURLTypes": [[
        "CFBundleURLName": "com.tryvaultline.mrstashy",
        "CFBundleURLSchemes": ["stashy"]
    ]]
]

let project = Project(
    name: "MrStashy",
    organizationName: "Vaultline",
    packages: [
        .remote(url: "https://github.com/weichsel/ZIPFoundation.git", requirement: .upToNextMajor(from: "0.9.0"))
    ],
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.0",
            "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
            "TARGETED_DEVICE_FAMILY": "1,2",
            "DEVELOPMENT_TEAM": "",
            "CODE_SIGN_STYLE": "Automatic",
            "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES"
        ]
    ),
    targets: [
        .target(
            name: "MrStashy",
            destinations: .iOS,
            product: .app,
            bundleId: "com.tryvaultline.mrstashy",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: appInfoPlist),
            sources: ["MrStashy/**", "Shared/**"],
            resources: ["Resources/**"],
            entitlements: "MrStashy/MrStashy.entitlements",
            dependencies: [.target(name: "StashyShareExtension"), .sdk(name: "sqlite3", type: .library), .package(product: "ZIPFoundation")]
        ),
        .target(
            name: "StashyShareExtension",
            destinations: .iOS,
            product: .appExtension,
            bundleId: "com.tryvaultline.mrstashy.share",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Stashy",
                "CFBundleShortVersionString": "0.1.0",
                "CFBundleVersion": "1",
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.share-services",
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ShareViewController",
                    "NSExtensionAttributes": [
                        "NSExtensionActivationRule": "SUBQUERY (extensionItems, $item, SUBQUERY ($item.attachments, $attachment, ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO 'public.url' OR ANY $attachment.registeredTypeIdentifiers UTI-CONFORMS-TO 'public.plain-text').@count > 0).@count > 0"
                    ]
                ]
            ]),
            sources: ["ShareExtension/**", "Shared/**"],
            entitlements: "ShareExtension/StashyShareExtension.entitlements"
        ),
        .target(
            name: "MrStashyTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.tryvaultline.mrstashy.tests",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .default,
            sources: ["MrStashyTests/**"],
            dependencies: [.target(name: "MrStashy")]
        ),
        .target(
            name: "MrStashyUITests",
            destinations: .iOS,
            product: .uiTests,
            bundleId: "com.tryvaultline.mrstashy.uitests",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .default,
            sources: ["MrStashyUITests/**"],
            dependencies: [.target(name: "MrStashy")]
        ),
        .target(
            name: "PlatformContractTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.tryvaultline.mrstashy.platform-contracts",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .default,
            sources: ["PlatformContractTests/**"],
            dependencies: [.target(name: "MrStashy")]
        )
    ],
    schemes: [
        .scheme(
            name: "MrStashy",
            shared: true,
            buildAction: .buildAction(targets: ["MrStashy", "StashyShareExtension"]),
            testAction: .targets(["MrStashyTests", "MrStashyUITests", "PlatformContractTests"]),
            runAction: .runAction(configuration: .debug),
            archiveAction: .archiveAction(configuration: .release)
        )
    ]
)
