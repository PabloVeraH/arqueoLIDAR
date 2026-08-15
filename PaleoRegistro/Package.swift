// swift-tools-version: 6.0
import PackageDescription

let crypto = Target.Dependency.product(name: "Crypto", package: "swift-crypto")

let package = Package(
    name: "PaleoRegistro",
    products: [
        .library(name: "PaleoDomain", targets: ["Domain"]),
        .library(name: "PaleoGeometry", targets: ["Geometry"]),
        .library(name: "PaleoMesh", targets: ["Mesh"]),
        .library(name: "PaleoVolume", targets: ["Volume"]),
        .library(name: "PaleoStratigraphy", targets: ["Stratigraphy"]),
        .library(name: "PaleoSegmentation", targets: ["Segmentation"]),
        .library(name: "PaleoGeo", targets: ["Geo"]),
        .library(name: "PaleoRegistration", targets: ["Registration"]),
        .library(name: "PaleoCustody", targets: ["Custody"]),
        .library(name: "PaleoPersistence", targets: ["Persistence"]),
        .library(name: "PaleoExport", targets: ["Export"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        // F1 — tipos puros, cero imports de framework.
        .target(name: "Domain"),

        // F2
        .target(name: "Geometry", dependencies: ["Domain"]),

        // F4
        .target(name: "Mesh", dependencies: ["Domain"]),

        // F5
        .target(name: "Volume", dependencies: ["Domain", "Mesh"]),

        // F6
        .target(name: "Stratigraphy", dependencies: ["Domain", "Geometry"]),

        // F7
        .target(name: "Segmentation", dependencies: ["Domain", "Geometry", "Mesh"]),

        // F8
        .target(name: "Geo", dependencies: ["Domain"]),

        // F11
        .target(name: "Registration", dependencies: ["Domain", "Mesh", "Geometry"]),

        // F10
        .target(name: "Custody", dependencies: ["Domain", "Persistence", crypto]),

        // F9 — depende de Mesh para poder leer de vuelta el PLY que ella
        // misma escribe (FindingStore.loadMesh, vía PLYCodec) sin crear una
        // dependencia circular con Export (que sí depende de Persistence).
        .target(name: "Persistence", dependencies: ["Domain", "Mesh"]),

        // F12
        .target(name: "Export", dependencies: ["Domain", "Mesh", "Geo", "Custody", "Persistence"]),

        // ─── Tests ───
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "GeometryTests", dependencies: ["Geometry", "Domain"]),
        .testTarget(name: "MeshTests", dependencies: ["Mesh", "Domain"]),
        .testTarget(name: "VolumeTests", dependencies: ["Volume", "Mesh", "Domain"]),
        .testTarget(name: "StratigraphyTests", dependencies: ["Stratigraphy", "Geometry", "Domain"]),
        .testTarget(name: "SegmentationTests", dependencies: ["Segmentation", "Geometry", "Mesh", "Domain"]),
        .testTarget(name: "GeoTests", dependencies: ["Geo", "Domain"]),
        .testTarget(name: "RegistrationTests", dependencies: ["Registration", "Mesh", "Geometry", "Domain"]),
        .testTarget(name: "CustodyTests", dependencies: ["Custody", "Persistence", "Domain"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "Domain"]),
        .testTarget(name: "ExportTests", dependencies: ["Export", "Geo", "Custody", "Persistence", "Domain"]),
        .testTarget(name: "IntegrationTests", dependencies: [
            "Domain", "Geometry", "Mesh", "Volume", "Stratigraphy", "Segmentation",
            "Geo", "Registration", "Custody", "Persistence", "Export",
        ]),
    ]
)