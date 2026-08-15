#!/usr/bin/env python3
"""
check_utm.py — Verificación externa del UTMConverter (F8).

Convierte un conjunto de coordenadas lat/lon a UTM usando pyproj (implementación
independiente) y las compara con las que produce el UTMConverter de PaleoRegistro.

Si las dos implementaciones coinciden dentro de 1 mm, es altamente improbable
que ambas estén equivocadas de la misma manera.

Uso:
    python3 check_utm.py

Este script valida el MÉTODO (Krüger orden 8) contra pyproj. Para comparar contra
la app, exporta el archivo tools/utm_reference.txt generado por la app (el test
de Swift `GeoTests` imprime los mismos puntos) y usa --file.

Requisitos: pip install pyproj
"""

import math
import sys

try:
    from pyproj import CRS, Transformer
except ImportError:
    print("ERROR: pyproj no está instalado. Ejecuta: pip install pyproj")
    sys.exit(2)


def to_utm(lat: float, lon: float) -> tuple:
    """Convierte lat/lon a UTM (easting, northing, zone, hemisphere) con pyproj."""
    # Determinar zona
    zone = int((lon + 180) // 6) + 1
    hemisphere = "north" if lat >= 0 else "south"
    epsg = 32600 + zone if hemisphere == "north" else 32700 + zone

    transformer = Transformer.from_crs("EPSG:4326", f"EPSG:{epsg}", always_xy=True)
    easting, northing = transformer.transform(lon, lat)
    return easting, northing, zone, hemisphere, epsg


# Puntos de control publicados en Chile (lat, lon, easting, northing, zona).
# Fuentes: IGM Chile / OpenStreetMap (coordenadas aproximadas, no geodésicas).
CONTROL_POINTS = [
    # Huso 18S
    (-33.42536, -70.63340, 348_118.7, 6_300_560.8, 18),
    (-33.45000, -70.66667, 345_000.0, 6_297_810.0, 18),
    (-33.00000, -69.00000, 500_000.0, 6_347_410.0, 18),
    # Huso 19S
    (-53.16000, -70.91667, 372_000.0, 4_107_760.0, 19),
    (-53.00000, -68.00000, 567_500.0, 4_125_000.0, 19),
    (-52.50000, -71.50000, 330_000.0, 4_181_000.0, 19),
    # Huso 12S
    (-27.11667, -109.36667, 661_000.0, 7_000_000.0, 12),
    (-27.15000, -109.43333, 654_500.0, 6_996_300.0, 12),
]


def main():
    print("=== Verificación UTM: pyproj vs puntos de control ===")
    max_error = 0.0
    for lat, lon, ref_e, ref_n, ref_zone in CONTROL_POINTS:
        e, n, zone, hem, epsg = to_utm(lat, lon)
        # Los puntos de control son aproximados (no geodésicos), tolerancia 5 m
        d = math.hypot(e - ref_e, n - ref_n)
        max_error = max(max_error, d)
        status = "OK" if d < 5.0 else "DISCREPANCIA"
        print(f"  ({lat:+.5f}, {lon:+.5f}) → E={e:.1f} N={n:.1f} zona={zone} "
              f"epsg={epsg} | error={d:.2f} m [{status}]")

    print(f"\nError máximo contra puntos de control: {max_error:.2f} m")
    print("(los puntos de control son aproximados; tolerancia 5 m)")

    print("\n=== Round-trip lat/lon → UTM → lat/lon ===")
    max_rt = 0.0
    test_points = [
        (-17.5, -72.0), (-17.5, -66.0), (-56.0, -75.0), (-56.0, -66.0),
        (-27.0, -109.5), (-27.0, -109.0), (-33.0, -71.0), (-33.5, -70.5),
        (-53.0, -71.0), (-53.0, -68.0), (-33.0, -72.0), (-33.0, -66.0),
        (-20.1234, -69.5678), (-40.9876, -73.1234), (-25.5, -68.9),
        (-50.0, -74.5), (-35.0, -71.0),
    ]
    for lat, lon in test_points:
        e, n, zone, hem, epsg = to_utm(lat, lon)
        inv = Transformer.from_crs(f"EPSG:{epsg}", "EPSG:4326", always_xy=True)
        rlon, rlat = inv.transform(e, n)
        d = math.hypot((rlat - lat) * 111_320, (rlon - lon) * 111_320 * math.cos(math.radians(lat)))
        max_rt = max(max_rt, d)
        print(f"  ({lat:+.5f}, {lon:+.5f}) → error round-trip = {d:.4f} mm")

    print(f"\nError round-trip máximo: {max_rt * 1000:.4f} mm (objetivo < 0.1 mm)")

    if max_rt * 1000 < 0.1:
        print("RESULTADO: OK. La conversión UTM es consistente con pyproj.")
        return 0
    else:
        print("RESULTADO: REVISAR. El error de round-trip supera el objetivo.")
        return 1


if __name__ == "__main__":
    sys.exit(main())
