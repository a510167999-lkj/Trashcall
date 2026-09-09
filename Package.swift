// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Trashcall",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "Trashcall",
            targets: ["Trashcall"]
        ),
        .executable(
            name: "TrashcallTestRunner",
            targets: ["TrashcallTestRunner"]
        )
    ],
    targets: [
        .target(
            name: "Trashcall",
            dependencies: [],
            path: "Sources/Trashcall"
        ),
        .executableTarget(
            name: "TrashcallTestRunner",
            dependencies: ["Trashcall"],
            path: "Sources/TrashcallTestRunner"
        )
    ],
    swiftLanguageModes: [.v6]
)
