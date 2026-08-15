import Foundation
import Domain
import Persistence

// ═══════════════════════════════════════════════════════════════════════════════
// F12 — STLWriter. Formato STL binario. Convención: 1 unidad = 1 mm.
// Requiere malla estanca (sin bordes abiertos). Incluye cubo de escala.
// ═══════════════════════════════════════════════════════════════════════════════

public struct STLWriter {

    public init() {}

    /// Escribe STL binario. La malla DEBE estar en metros; internamente se
    /// convierte a mm (1 unidad STL = 1 mm).
    public func write(
        mesh: Mesh,
        metadata: ExportMetadata,
        to url: URL
    ) throws(ExportError) -> ExportSidecar {

        guard !mesh.isEmpty else { throw .writeFailed("Malla vacía") }

        let scaleMM: Float = 1000.0 // m → mm

        var data = Data()

        // Cabecera 80 bytes
        let headerStr = "PaleoRegistro STL binary - 1 unit = 1 mm"
        var header = headerStr.data(using: .ascii)!
        header.append(Data(repeating: 0, count: max(0, 80 - header.count)))
        data.append(header.prefix(80))

        // Número de triángulos (uint32 LE)
        let faceCount = mesh.triangleCount
        var count32 = UInt32(faceCount)
        withUnsafeBytes(of: &count32) { data.append(contentsOf: $0) }

        // Calcular normales por cara
        let faceNormals = computeFaceNormals(mesh)

        for f in 0..<faceCount {
            let base = f * 3
            let i0 = Int(mesh.indices[base])
            let i1 = Int(mesh.indices[base + 1])
            let i2 = Int(mesh.indices[base + 2])

            let n = faceNormals[f]

            // Normal (3 × float32)
            var nx = n.x; var ny = n.y; var nz = n.z
            withUnsafeBytes(of: &nx) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &ny) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &nz) { data.append(contentsOf: $0) }

            // Vértices escalados a mm (3 × 3 × float32)
            for vi in [i0, i1, i2] {
                let v = mesh.vertices[vi]
                var x = v.x * scaleMM; var y = v.y * scaleMM; var z = v.z * scaleMM
                withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
                withUnsafeBytes(of: &z) { data.append(contentsOf: $0) }
            }

            // Atributo (uint16, 0)
            var attr: UInt16 = 0
            withUnsafeBytes(of: &attr) { data.append(contentsOf: $0) }
        }

        try ExportWrite.data(data, to: url)

        let sidecarURL = url.deletingPathExtension().appendingPathExtension("record.json")
        var exportMeta = metadata
        exportMeta.scaleUnits = "1 unit = 1 mm"
        let sidecar = try RecordSidecarBuilder.build(metadata: exportMeta, format: "stl")
        
        try ExportWrite.sidecar(sidecar, to: sidecarURL)

        return ExportSidecar(fileURL: url, recordURL: sidecarURL)
    }

    private func computeFaceNormals(_ mesh: Mesh) -> [SIMD3<Float>] {
        var normals: [SIMD3<Float>] = []
        normals.reserveCapacity(mesh.triangleCount)
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            let p0 = mesh.vertices[Int(mesh.indices[i])]
            let p1 = mesh.vertices[Int(mesh.indices[i+1])]
            let p2 = mesh.vertices[Int(mesh.indices[i+2])]
            let n = vecNormalize(vecCross(p1 - p0, p2 - p0))
            normals.append(n)
        }
        return normals
    }
}