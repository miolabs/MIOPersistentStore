// swift-tools-version:6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MIOPersistentStore",
    platforms: [
        .macOS(.v12), .iOS(.v12)
    ],
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "MIOPersistentStore",
            targets: ["MIOPersistentStore"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        // TEMP-LOCAL: wasm spike — local checkouts have WASI gates; restore the github URLs before committing
        .package(url: "https://github.com/miolabs/MIOCoreData.git", branch: "master" ),
        .package(url: "https://github.com/miolabs/MIOCore.git", branch: "master" ),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "MIOPersistentStore",
            dependencies: [
                .product(name: "MIOCoreData", package: "MIOCoreData"),
                .product(name: "CoreDataSwift", package: "MIOCoreData"),
                .product(name: "MIOCoreLogger", package: "MIOCore"),
            ]),
        .testTarget(
            name: "MIOPersistentStoreTests",
            dependencies: ["MIOPersistentStore"]),
    ]
)
