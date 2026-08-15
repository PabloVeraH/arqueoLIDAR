import Foundation
import Domain

// ═══════════════════════════════════════════════════════════════════════════════
// F4/F9 — PLYCodec. Códec binario PLY (little-endian, x/y/z + caras
// triangulares): única fuente de verdad del formato interno del bundle
// (scans/<scanID>/mesh.ply, §2.B del plan) y del export PLY
// (Export/PLYWriter, que delega en encode(_:) para no duplicar el formato).
//
// Vive en Mesh, que solo depende de Domain, para que Persistence pueda leer
// de vuelta sus propias mallas sin depender de Export — Export ya depende
// de Persistence, así que la dependencia inversa sería circular.
// ═══════════════════════════════════════════════════════════════════════════════

public enum PLYCodec {

    private static let headerEndMarker = "end_header\n"
    /// Cabeceras PLY reales son de pocas líneas de texto ASCII; limitar la
    /// búsqueda del marcador a un prefijo evita copiar mallas grandes enteras
    /// solo para ubicar dónde termina el texto.
    private static let maxHeaderSearchBytes = 4096

    /// Codifica una malla a PLY binario little-endian. Byte-determinista:
    /// la misma malla produce siempre los mismos bytes.
    public static func encode(_ mesh: Mesh) -> Data {
        var data = Data()

        let header = """
        ply
        format binary_little_endian 1.0
        comment PaleoRegistro PLY export
        element vertex \(mesh.vertices.count)
        property float x
        property float y
        property float z
        element face \(mesh.triangleCount)
        property list uchar int vertex_indices
        end_header\n
        """
        data.append(header.data(using: .ascii)!)

        for v in mesh.vertices {
            var x = v.x.bitPattern; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) }
            var y = v.y.bitPattern; withUnsafeBytes(of: &y) { data.append(contentsOf: $0) }
            var z = v.z.bitPattern; withUnsafeBytes(of: &z) { data.append(contentsOf: $0) }
        }

        var three: UInt8 = 3
        for i in stride(from: 0, to: mesh.indices.count, by: 3) {
            data.append(&three, count: 1)
            var a = mesh.indices[i];   withUnsafeBytes(of: &a) { data.append(contentsOf: $0) }
            var b = mesh.indices[i + 1]; withUnsafeBytes(of: &b) { data.append(contentsOf: $0) }
            var c = mesh.indices[i + 2]; withUnsafeBytes(of: &c) { data.append(contentsOf: $0) }
        }

        return data
    }

    /// Decodifica PLY binario little-endian producido por `encode(_:)`. No es
    /// un lector PLY genérico: no soporta ASCII, big-endian, ni propiedades
    /// por vértice más allá de `x,y,z` — es el lector del formato interno
    /// del bundle, simétrico de `encode(_:)`.
    public static func decode(_ data: Data) throws(MeshError) -> Mesh {
        guard let headerEnd = findHeaderEnd(data) else {
            throw .invalidInput("PLY sin 'end_header': cabecera incompleta o formato no reconocido")
        }
        guard let headerText = String(data: data[data.startIndex..<headerEnd], encoding: .ascii) else {
            throw .invalidInput("Cabecera PLY no es ASCII válido")
        }
        guard headerText.hasPrefix("ply") else {
            throw .invalidInput("No es un archivo PLY (falta la firma 'ply')")
        }
        guard headerText.contains("binary_little_endian") else {
            throw .invalidInput("Solo se soporta PLY binary_little_endian")
        }

        var vertexCount: Int?
        var faceCount: Int?
        for line in headerText.split(separator: "\n") {
            if line.hasPrefix("element vertex ") {
                vertexCount = Int(line.dropFirst("element vertex ".count))
            } else if line.hasPrefix("element face ") {
                faceCount = Int(line.dropFirst("element face ".count))
            }
        }
        guard let nVerts = vertexCount, let nFaces = faceCount else {
            throw .invalidInput("Cabecera PLY no declara 'element vertex'/'element face'")
        }

        let bodySize = data.distance(from: headerEnd, to: data.endIndex)
        let expectedBodySize = nVerts * 12 + nFaces * 13
        guard bodySize == expectedBodySize else {
            throw .invalidInput(
                "Tamaño de cuerpo PLY (\(bodySize)) no coincide con el esperado " +
                "(\(expectedBodySize)) para \(nVerts) vértices y \(nFaces) caras"
            )
        }

        var offset = headerEnd
        var vertices: [SIMD3<Float>] = []
        vertices.reserveCapacity(nVerts)
        for _ in 0..<nVerts {
            let x = readFloat(data, at: &offset)
            let y = readFloat(data, at: &offset)
            let z = readFloat(data, at: &offset)
            vertices.append(SIMD3(x, y, z))
        }

        var indices: [UInt32] = []
        indices.reserveCapacity(nFaces * 3)
        for _ in 0..<nFaces {
            let count = data[offset]
            offset = data.index(after: offset)
            guard count == 3 else {
                throw .invalidInput("Cara con \(count) vértices; solo se soportan triángulos")
            }
            indices.append(readUInt32(data, at: &offset))
            indices.append(readUInt32(data, at: &offset))
            indices.append(readUInt32(data, at: &offset))
        }

        return Mesh(vertices: vertices, indices: indices)
    }

    // MARK: - Helpers

    private static func findHeaderEnd(_ data: Data) -> Data.Index? {
        let marker = Array(headerEndMarker.utf8)
        let searchLimit = min(data.count, maxHeaderSearchBytes)
        guard searchLimit >= marker.count else { return nil }

        let bytes = [UInt8](data.prefix(searchLimit))
        guard bytes.count >= marker.count else { return nil }
        for start in 0...(bytes.count - marker.count) {
            if Array(bytes[start..<(start + marker.count)]) == marker {
                return data.index(data.startIndex, offsetBy: start + marker.count)
            }
        }
        return nil
    }

    private static func readUInt32(_ data: Data, at offset: inout Data.Index) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[data.index(offset, offsetBy: 1)])
        let b2 = UInt32(data[data.index(offset, offsetBy: 2)])
        let b3 = UInt32(data[data.index(offset, offsetBy: 3)])
        offset = data.index(offset, offsetBy: 4)
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    private static func readFloat(_ data: Data, at offset: inout Data.Index) -> Float {
        Float(bitPattern: readUInt32(data, at: &offset))
    }
}
