// swift-tools-version: 5.9
import PackageDescription

// 本地 C 包：声明 sherpa-onnx 的 C API（实现由 Vendor/sherpa-onnx.xcframework 静态库提供）。
// 独立模块化是为了绕开 xcframework 自带 modulemap 与其他框架的头文件冲突。
let package = Package(
    name: "SherpaCAPI",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "SherpaCAPI", targets: ["sherpa_capi"])
    ],
    targets: [
        .target(name: "sherpa_capi", path: ".", sources: ["Sources/sherpa_capi/shim.c"], publicHeadersPath: "include")
    ]
)
