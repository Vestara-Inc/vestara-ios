// swift-tools-version: 5.9

import PackageDescription

let package = Package(
  name: "VestaraSDK",
  platforms: [
    .iOS(.v14),
  ],
  products: [
    .library(
      name: "VestaraSDK",
      targets: ["VestaraSDK"]
    ),
  ],
  targets: [
    .target(
      name: "VestaraSDK",
      path: "Sources/sdk-ios"
    ),
    .executableTarget(
      name: "SampleApp",
      dependencies: ["VestaraSDK"],
      path: "Sources/SampleApp"
    ),
    .testTarget(
      name: "VestaraSDKTests",
      dependencies: ["VestaraSDK"],
      path: "Tests/sdk-ios"
    ),
  ]
)
