// swift-tools-version:5.10
// Swift bindings over the NomadFS C ABI (src/mobile/nomadfs.h).
//
// Before building, produce the shared library at the repo root with:
//   zig build                       # native
// ... or any target in learning/mobile/api.md section 3.
import PackageDescription

let package = Package(
    name: "NomadFs",
    products: [
        .library(name: "NomadFs", targets: ["NomadFs"]),
    ],
    dependencies: [],
    targets: [
        // Header-only target wrapping the C ABI. The zig-built library is
        // expected at <repo root>/zig-out/lib (three levels up from here).
        .target(
            name: "CNomadFs",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L../../zig-out/lib",
                    "-Xlinker", "-rpath", "-Xlinker", "../../zig-out/lib",
                    "-lnomadfs",
                ]),
            ]
        ),
        .target(name: "NomadFs", dependencies: ["CNomadFs"]),
        .testTarget(name: "NomadFsTests", dependencies: ["NomadFs"]),
    ]
)
