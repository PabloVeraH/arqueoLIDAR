import Foundation
import Domain
import Geo

// ═══════════════════════════════════════════════════════════════════════════════
// UTMReferenceDump — herramienta de verificación externa (fixes.md).
//
// tools/check_utm.py solo comparaba pyproj contra sí mismo: nunca ejercitaba
// el `UTMConverter` real de la app, a pesar de que su propio docstring
// prometía un modo `--file` para cruzarlo. Este ejecutable es la mitad
// Swift de ese cruce: convierte un conjunto fijo de puntos lat/lon a UTM
// usando el `UTMConverter` de producción (el mismo código que usa la app) y
// lo imprime en CSV por stdout, para que `check_utm.py --file` lo compare
// contra una implementación independiente (pyproj).
//
// Uso (desde PaleoRegistro/):
//   swift run UTMReferenceDump > ../tools/utm_reference.txt
//   cd .. && python3 tools/check_utm.py --file tools/utm_reference.txt
//
// Formato de salida: una línea de cabecera `# lat,lon,easting,northing,zone,hemisphere,epsg`
// seguida de una línea por punto, campos separados por coma. Los floats se
// imprimen con `.description` (igual que `CanonicalFormat` en Export): la
// representación mínima que hace round-trip exacto, sin depender del locale.
// ═══════════════════════════════════════════════════════════════════════════════

func fmt(_ v: Double) -> String {
    v == 0 ? "0.0" : v.description
}

/// Puntos lat/lon cubriendo Chile continental e insular, incluyendo los tres
/// husos soportados (12, 18, 19) y bordes de huso — coherente con la
/// cobertura de `GeoTests.utmRoundTripLargeGrid`, aunque es una lista
/// independiente (no hay un módulo compartido entre el target de tests y
/// este ejecutable): si se agregan puntos de control nuevos a `GeoTests`,
/// conviene reflejarlos también aquí.
let points: [(lat: Double, lon: Double)] = [
    // Esquinas de Chile continental + insular.
    (-17.5, -72.0), (-17.5, -66.0),
    (-56.0, -75.0), (-56.0, -66.0),
    (-27.0, -109.5), (-27.0, -109.0), // Isla de Pascua, huso 12
    (-33.0, -71.0), (-33.5, -70.5),
    (-53.0, -71.0), (-53.0, -68.0),
    // Bordes de huso 18/19 y 19/20.
    (-33.0, -72.0), (-33.0, -71.999), (-33.0, -72.001),
    (-33.0, -66.0), (-33.0, -65.999), (-33.0, -66.001),
    // Puntos deterministas dispersos.
    (-20.1234, -69.5678), (-40.9876, -73.1234),
    (-25.5, -68.9), (-50.0, -74.5), (-35.0, -71.0),
    // Ciudades/puntos de referencia conocidos.
    (-33.42536, -70.63340), // Santiago
    (-53.16000, -70.91667), // Punta Arenas
    (-27.11667, -109.36667), // Isla de Pascua (Hanga Roa)
]

let converter = UTMConverter()
print("# lat,lon,easting,northing,zone,hemisphere,epsg")
for p in points {
    do {
        let utm = try converter.toUTM(latitude: p.lat, longitude: p.lon)
        let hemisphere = utm.isNorthernHemisphere ? "north" : "south"
        print("\(fmt(p.lat)),\(fmt(p.lon)),\(fmt(utm.easting)),\(fmt(utm.northing)),\(utm.zone),\(hemisphere),\(utm.epsg)")
    } catch {
        FileHandle.standardError.write("# ERROR en (\(p.lat), \(p.lon)): \(error)\n".data(using: .utf8)!)
    }
}
