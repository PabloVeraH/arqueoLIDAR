import Foundation

// ═══════════════════════════════════════════════════════════════════════════════
// F1 — Matemática vectorial/matricial portátil. Reemplaza al módulo `simd`
// (Apple-only) para que Domain sea compilable en Linux y en iOS con cero
// imports de plataforma. Mismos nombres de convención que simd para facilitar
// la portabilidad futura. Column-major, como simd.
// ═══════════════════════════════════════════════════════════════════════════════

// MARK: - Vectores

@inlinable
public func vecLength(_ v: SIMD3<Float>) -> Float {
    (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
}

@inlinable
public func vecNormalize(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let l = vecLength(v)
    guard l > 1e-12 else { return .zero }
    return v / l
}

@inlinable
public func vecDot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    a.x * b.x + a.y * b.y + a.z * b.z
}

@inlinable
public func vecCross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3(a.y * b.z - a.z * b.y,
          a.z * b.x - a.x * b.z,
          a.x * b.y - a.y * b.x)
}

// MARK: - Matrix3x3

/// Matriz 3×3 column-major (columnas accesibles como `columns[i]`).
public struct Matrix3x3: Sendable {
    public var columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    public init(_ c0: SIMD3<Float>, _ c1: SIMD3<Float>, _ c2: SIMD3<Float>) {
        self.columns = (c0, c1, c2)
    }

    public init(_ columns: [SIMD3<Float>]) {
        precondition(columns.count == 3, "Matrix3x3 requiere 3 columnas")
        self.init(columns[0], columns[1], columns[2])
    }

    public static var identity: Matrix3x3 {
        Matrix3x3(SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1))
    }

    public subscript(column: Int) -> SIMD3<Float> {
        get {
            switch column {
            case 0: return columns.0
            case 1: return columns.1
            default: return columns.2
            }
        }
        set {
            switch column {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            default: columns.2 = newValue
            }
        }
    }

    public static func * (lhs: Matrix3x3, rhs: Matrix3x3) -> Matrix3x3 {
        var result = Matrix3x3.identity
        for c in 0..<3 {
            let col = rhs[c]
            for r in 0..<3 {
                var sum: Float = 0
                for k in 0..<3 {
                    sum += lhs[k][r] * col[k]
                }
                // sum = Σ_k lhs[r,k]·rhs[k,c] = (lhs·rhs)[r,c] — el elemento
                // de fila r, columna c del producto. Con almacenamiento por
                // columnas (subscript[columna][fila]), eso va en
                // result[c][r], no en result[r][c] (que guardaba el
                // resultado transpuesto: cualquier composición de rotaciones
                // encadenada —A*B*C— quedaba silenciosamente traspuesta,
                // dejando de ser una rotación válida a partir de la segunda
                // multiplicación).
                result[c][r] = sum
            }
        }
        return result
    }
}

extension Matrix3x3: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var cols: [SIMD3<Float>] = []
        for _ in 0..<3 {
            cols.append(try container.decode(SIMD3<Float>.self))
        }
        self.init(cols)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for c in 0..<3 {
            try container.encode(self[c])
        }
    }
}

extension Matrix3x3: Equatable {
    public static func == (lhs: Matrix3x3, rhs: Matrix3x3) -> Bool {
        for c in 0..<3 {
            if lhs[c] != rhs[c] { return false }
        }
        return true
    }
}

// MARK: - Quatf (cuaternión, w+xi+yj+zk)

public struct Quatf: Sendable, Codable, Equatable {
    public var vector: SIMD3<Float>
    public var scalar: Float

    public init(vector: SIMD3<Float>, scalar: Float) {
        self.vector = vector
        self.scalar = scalar
    }

    public static var identity: Quatf { Quatf(vector: .zero, scalar: 1) }
}

// MARK: - Matrix4x4

/// Matriz 4×4 column-major. Misma convención que simd_float4x4: `columns.3`
/// es la columna de traslación (x, y, z, w).
public struct Matrix4x4: Sendable {
    public var columns: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

    public init(_ c0: SIMD4<Float>, _ c1: SIMD4<Float>, _ c2: SIMD4<Float>, _ c3: SIMD4<Float>) {
        self.columns = (c0, c1, c2, c3)
    }

    public init(_ columns: [SIMD4<Float>]) {
        precondition(columns.count == 4, "Matrix4x4 requiere 4 columnas")
        self.init(columns[0], columns[1], columns[2], columns[3])
    }

    public static var identity: Matrix4x4 {
        Matrix4x4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
    }

    public subscript(column: Int) -> SIMD4<Float> {
        get {
            switch column {
            case 0: return columns.0
            case 1: return columns.1
            case 2: return columns.2
            default: return columns.3
            }
        }
        set {
            switch column {
            case 0: columns.0 = newValue
            case 1: columns.1 = newValue
            case 2: columns.2 = newValue
            default: columns.3 = newValue
            }
        }
    }

    public init(translation: SIMD3<Float>, quaternion: Quatf) {
        let r = Self.rotationMatrix(quaternion)
        self = Matrix4x4(
            SIMD4(r[0].x, r[0].y, r[0].z, 0),
            SIMD4(r[1].x, r[1].y, r[1].z, 0),
            SIMD4(r[2].x, r[2].y, r[2].z, 0),
            SIMD4(translation.x, translation.y, translation.z, 1)
        )
    }

    public var translation: SIMD3<Float> {
        SIMD3(columns.3.x, columns.3.y, columns.3.z)
    }

    public var rotation3x3: Matrix3x3 {
        let sx = vecLength(columns.0.xyz)
        let sy = vecLength(columns.1.xyz)
        let sz = vecLength(columns.2.xyz)
        return Matrix3x3(
            columns.0.xyz / (sx > 0 ? sx : 1),
            columns.1.xyz / (sy > 0 ? sy : 1),
            columns.2.xyz / (sz > 0 ? sz : 1)
        )
    }

    public func multiplying(_ other: Matrix4x4) -> Matrix4x4 {
        var result = Matrix4x4.identity
        for c in 0..<4 {
            let col = other[c]
            for r in 0..<4 {
                var sum: Float = 0
                for k in 0..<4 {
                    sum += self[k][r] * col[k]
                }
                // Mismo bug que en Matrix3x3 * Matrix3x3 (ver el comentario
                // ahí): sum es el elemento (fila r, columna c) del producto,
                // que en almacenamiento por columnas va en result[c][r].
                // result[r][c] guardaba el producto TRASPUESTO — para una
                // matriz afín 4×4, eso mueve la traslación (columna 3) a la
                // fila 3 y dejaba `.translation` leyendo (0,0,0), y hace que
                // cualquier composición encadenada de transformaciones
                // (exactamente lo que hace ICPAligner en cada iteración,
                // `transform = deltaTransform * transform`) se corrompa
                // después del primer paso.
                result[c][r] = sum
            }
        }
        return result
    }

    public func transforming(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let r = rotation3x3
        return r * v + translation
    }

    public func transformingPoint(_ v: SIMD3<Float>) -> SIMD3<Float> {
        transforming(v)
    }

    /// Producto matriz-vector con w=1 (afín).
    public func applyAffine(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let x = columns.0.x * v.x + columns.1.x * v.y + columns.2.x * v.z + columns.3.x
        let y = columns.0.y * v.x + columns.1.y * v.y + columns.2.y * v.z + columns.3.y
        let z = columns.0.z * v.x + columns.1.z * v.y + columns.2.z * v.z + columns.3.z
        return SIMD3(x, y, z)
    }

    public static func * (lhs: Matrix4x4, rhs: Matrix4x4) -> Matrix4x4 {
        lhs.multiplying(rhs)
    }

    /// Inversa para transformaciones rígidas (rotación transpuesta + traslación).
    public func rigidInverse() -> Matrix4x4 {
        let r = rotation3x3
        let rt = Matrix3x3(SIMD3(r[0].x, r[1].x, r[2].x),
                           SIMD3(r[0].y, r[1].y, r[2].y),
                           SIMD3(r[0].z, r[1].z, r[2].z))
        let t = translation
        let neg = rt * t
        return Matrix4x4(
            SIMD4(rt[0].x, rt[0].y, rt[0].z, 0),
            SIMD4(rt[1].x, rt[1].y, rt[1].z, 0),
            SIMD4(rt[2].x, rt[2].y, rt[2].z, 0),
            SIMD4(-neg.x, -neg.y, -neg.z, 1)
        )
    }

    private static func rotationMatrix(_ q: Quatf) -> Matrix3x3 {
        let x = q.vector.x, y = q.vector.y, z = q.vector.z, w = q.scalar
        return Matrix3x3(
            SIMD3(1 - 2*(y*y + z*z), 2*(x*y + z*w), 2*(x*z - y*w)),
            SIMD3(2*(x*y - z*w), 1 - 2*(x*x + z*z), 2*(y*z + x*w)),
            SIMD3(2*(x*z + y*w), 2*(y*z - x*w), 1 - 2*(x*x + y*y))
        )
    }
}

extension Matrix4x4: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var cols: [SIMD4<Float>] = []
        for _ in 0..<4 {
            cols.append(try container.decode(SIMD4<Float>.self))
        }
        self.init(cols)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for c in 0..<4 {
            try container.encode(self[c])
        }
    }
}

extension Matrix4x4: Equatable {
    public static func == (lhs: Matrix4x4, rhs: Matrix4x4) -> Bool {
        for c in 0..<4 {
            if lhs[c] != rhs[c] { return false }
        }
        return true
    }
}

/// SIMD6 con acceso por subíndice (para QuadricSurface).
public struct SIMD6<Scalar>: Codable, Equatable, Sendable where Scalar: Codable & Equatable & Sendable {
    public var components: [Scalar]

    public init(_ components: [Scalar]) {
        precondition(components.count == 6, "SIMD6 requiere 6 componentes")
        self.components = components
    }

    public init(_ a: Scalar, _ b: Scalar, _ c: Scalar, _ d: Scalar, _ e: Scalar, _ f: Scalar) {
        self.components = [a, b, c, d, e, f]
    }

    public subscript(index: Int) -> Scalar {
        get { components[index] }
        set { components[index] = newValue }
    }
}

// MARK: - Codable para SIMD2/3/4

extension SIMD2: Codable where Scalar: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Scalar.self)
        let y = try container.decode(Scalar.self)
        self.init(x, y)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }
}

extension SIMD3: Codable where Scalar: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Scalar.self)
        let y = try container.decode(Scalar.self)
        let z = try container.decode(Scalar.self)
        self.init(x, y, z)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(z)
    }
}

extension SIMD4: Codable where Scalar: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Scalar.self)
        let y = try container.decode(Scalar.self)
        let z = try container.decode(Scalar.self)
        let w = try container.decode(Scalar.self)
        self.init(x, y, z, w)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(z)
        try container.encode(w)
    }
}

// MARK: - Matrix3x3 * vector

/// Producto matriz-vector estándar: combinación lineal de las columnas.
public func * (lhs: Matrix3x3, rhs: SIMD3<Float>) -> SIMD3<Float> {
    rhs.x * lhs[0] + rhs.y * lhs[1] + rhs.z * lhs[2]
}

extension SIMD4 where Scalar == Float {
    public var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}