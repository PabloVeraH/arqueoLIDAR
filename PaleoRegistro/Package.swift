// swift-tools-version: 6.0
import PackageDescription

// En plataformas Apple se usa CryptoKit del sistema (misma API), así Xcode no
// necesita descargar swift-crypto. En Linux (toolchain de tests) se usa swift-crypto.
#if os(Linux) || os(Windows)
let cryptoPackages: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
]
let cryptoDeps: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
#else
let cryptoPackages: [Package.Dependency] = []
let cryptoDeps: [Target.Dependency] = []
#endif

let package = Package(
    name: "PaleoRegistro",
    // Sin plataformas mínimas, Xcode compila contra iOS 12 / macOS 10.13, donde
    // CryptoKit (P256, SHA256), `actor` y typed throws no están disponibles.
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
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
    dependencies: cryptoPackages,
    targets: [
        // F1 — tipos puros, cero imports de framework.
        .target(name: "Domain"),

        // F2
        .target(name: "Geometry", dependencies: ["Domain"]),

        // F4
        .target(name: "Mesh", dependencies: ["Domain"]),

        // F5
        .target(name: "Volume", dependencies: ["Domain", "Mesh", "Geometry"]),

        // F6
        .target(name: "Stratigraphy", dependencies: ["Domain", "Geometry"]),

        // F7
        .target(name: "Segmentation", dependencies: ["Domain", "Geometry", "Mesh"]),

        // F8
        .target(name: "Geo", dependencies: ["Domain"]),

        // F11
        .target(name: "Registration", dependencies: ["Domain", "Mesh", "Geometry"]),

        // F10
        .target(name: "Custody", dependencies: ["Domain", "Persistence"] + cryptoDeps),

        // F9 — depende de Mesh para poder leer de vuelta el PLY que ella
        // misma escribe (FindingStore.loadMesh, vía PLYCodec) sin crear una
        // dependencia circular con Export (que sí depende de Persistence).
        .target(name: "Persistence", dependencies: ["Domain", "Mesh"]),

        // F12
        .target(name: "Export", dependencies: ["Domain", "Mesh", "Geo", "Custody", "Persistence"]),

        // Herramienta de verificación externa (fixes.md): imprime UTM real
        // calculado por UTMConverter en CSV, para que tools/check_utm.py
        // --file lo cruce contra pyproj. Sin esto, check_utm.py solo podía
        // comparar pyproj contra sí mismo — nunca contra la app.
        .executableTarget(name: "UTMReferenceDump", dependencies: ["Domain", "Geo"]),

        // ─── Tests ───
        .testTarget(name: "DomainTests", dependencies: ["Domain"]),
        .testTarget(name: "GeometryTests", dependencies: ["Geometry", "Domain"]),
        .testTarget(name: "MeshTests", dependencies: ["Mesh", "Domain"]),
        .testTarget(name: "VolumeTests", dependencies: ["Volume", "Mesh", "Geometry", "Domain"]),
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