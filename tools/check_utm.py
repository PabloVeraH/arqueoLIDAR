#!/usr/bin/env python3
"""
check_utm.py — Verificación externa del UTMConverter (F8).

Convierte un conjunto de coordenadas lat/lon a UTM usando pyproj (implementación
independiente) y las compara con las que produce el UTMConverter de PaleoRegistro.

Si las dos implementaciones coinciden dentro de 1 mm, es altamente improbable
que ambas estén equivocadas de la misma manera.

Uso:
    python3 check_utm.py
        Valida el MÉTODO (Krüger orden 8) contra pyproj usando puntos de
        control publicados y un round-trip interno — pyproj comparado
        contra sí mismo, no contra la app.

    python3 check_utm.py --file tools/utm_reference.txt
        Además del check anterior, cruza pyproj contra el UTMConverter real
        de la app. tools/utm_reference.txt se genera así (desde PaleoRegistro/):

            swift run UTMReferenceDump > ../tools/utm_reference.txt

Requisitos: pip install pyproj
"""

import argparse
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


# Puntos de control: los mismos (lat, lon) que `GeoTests.zone18Points` /
# `zone19Points` / `zone12Points` en Swift, con easting/northing calculados
# por `pyproj` (EPSG:32718/32719/32712) — no aproximaciones de mapa. Antes
# de este fix, esta tabla tenía valores redondeados a mano (fuente: IGM/OSM
# "aproximada, no geodésica") que además clasificaban mal el huso de 3 de
# sus 8 puntos, así que el propio check_utm.py reportaba `[DISCREPANCIA]`
# de hasta 2295 m en todos — no porque el `UTMConverter` estuviera mal, sino
# porque la tabla de referencia de este script sí lo estaba (fixes.md).
CONTROL_POINTS = [
    # Huso 18S
    (-33.42536, -73.50000, 639_453.8321, 6_300_550.3071, 18),
    (-27.00000, -75.00000, 500_000.0000, 7_013_564.7574, 18),
    (-45.00000, -74.00000, 578_815.3029, 5_016_563.2317, 18),
    # Huso 19S
    (-53.16000, -70.91667, 371_854.2814, 4_108_214.9013, 19),
    (-53.00000, -68.00000, 567_109.4354, 4_127_261.7386, 19),
    (-52.50000, -71.50000, 330_306.2303, 4_180_410.0708, 19),
    # Huso 12S
    (-27.11667, -109.36667, 661_896.4774, 6_999_590.3797, 12),
    (-27.15000, -109.43333, 655_242.0569, 6_995_982.0301, 12),
]


def check_control_points() -> float:
    print("=== Verificación UTM: pyproj vs puntos de control ===")
    max_error = 0.0
    for lat, lon, ref_e, ref_n, ref_zone in CONTROL_POINTS:
        e, n, zone, hem, epsg = to_utm(lat, lon)
        # Valores de referencia calculados con pyproj: tolerancia 1 mm, la
        # misma que exige el plan (§3, F8) y que usa GeoTests.
        d = math.hypot(e - ref_e, n - ref_n)
        max_error = max(max_error, d)
        status = "OK" if d < 0.001 else "DISCREPANCIA"
        print(f"  ({lat:+.5f}, {lon:+.5f}) → E={e:.4f} N={n:.4f} zona={zone} "
              f"epsg={epsg} | error={d * 1000:.3f} mm [{status}]")

    print(f"\nError máximo contra puntos de control: {max_error * 1000:.3f} mm (objetivo < 1 mm)")
    return max_error


def check_internal_round_trip() -> float:
    print("\n=== Round-trip lat/lon → UTM → lat/lon (solo pyproj) ===")
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
    return max_rt


def parse_reference_file(path: str) -> list:
    """Lee el CSV que produce `swift run UTMReferenceDump`:
    lat,lon,easting,northing,zone,hemisphere,epsg — una línea por punto,
    líneas que empiezan con '#' o vacías se ignoran."""
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        for lineno, raw in enumerate(f, start=1):
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(",")
            if len(parts) != 7:
                print(f"ADVERTENCIA: {path}:{lineno} tiene {len(parts)} campos, se esperaban 7 — línea ignorada")
                continue
            lat, lon, easting, northing, zone, hemisphere, epsg = parts
            rows.append({
                "lat": float(lat), "lon": float(lon),
                "easting": float(easting), "northing": float(northing),
                "zone": int(zone), "hemisphere": hemisphere.strip(),
                "epsg": int(epsg),
            })
    return rows


def check_against_app(path: str, tolerance_m: float = 0.001) -> bool:
    """Cruza el UTMConverter real de la app (volcado a `path` por
    UTMReferenceDump) contra pyproj: para cada punto, recalcula zona/
    hemisferio/EPSG y easting/northing de forma independiente y compara.
    Antes de este fix, check_utm.py no tenía ninguna forma de hacer esto —
    solo se comparaba pyproj contra sí mismo."""
    print(f"\n=== Cruce contra la app: pyproj vs UTMConverter ({path}) ===")
    try:
        rows = parse_reference_file(path)
    except OSError as exc:
        print(f"ERROR: no se pudo leer {path}: {exc}")
        return False

    if not rows:
        print(f"ERROR: {path} no contiene puntos válidos.")
        return False

    max_error = 0.0
    zone_mismatches = 0
    for r in rows:
        e, n, zone, hem, epsg = to_utm(r["lat"], r["lon"])
        if zone != r["zone"] or hem != r["hemisphere"] or epsg != r["epsg"]:
            zone_mismatches += 1
            print(
                f"  ({r['lat']:+.5f}, {r['lon']:+.5f}) → DISCREPANCIA DE ZONA: "
                f"app=huso{r['zone']}/{r['hemisphere']}/epsg{r['epsg']} "
                f"pyproj=huso{zone}/{hem}/epsg{epsg}"
            )
            continue
        d = math.hypot(e - r["easting"], n - r["northing"])
        max_error = max(max_error, d)
        status = "OK" if d < tolerance_m else "DISCREPANCIA"
        print(
            f"  ({r['lat']:+.5f}, {r['lon']:+.5f}) → huso={zone} "
            f"app(E={r['easting']:.4f}, N={r['northing']:.4f}) "
            f"pyproj(E={e:.4f}, N={n:.4f}) | error={d * 1000:.3f} mm [{status}]"
        )

    print(f"\nError máximo app vs pyproj: {max_error * 1000:.3f} mm (objetivo < {tolerance_m * 1000:.1f} mm)")
    if zone_mismatches:
        print(f"Discrepancias de zona/hemisferio/EPSG: {zone_mismatches}")

    passed = zone_mismatches == 0 and max_error < tolerance_m
    print("RESULTADO: OK. El UTMConverter de la app coincide con pyproj." if passed
          else "RESULTADO: REVISAR. El UTMConverter de la app difiere de pyproj más allá de la tolerancia.")
    return passed


def main() -> int:
    parser = argparse.ArgumentParser(description="Verificación externa del UTMConverter (F8).")
    parser.add_argument(
        "--file", metavar="PATH",
        help="CSV generado por 'swift run UTMReferenceDump' (lat,lon,easting,northing,zone,hemisphere,epsg). "
             "Si se entrega, cruza el UTMConverter real de la app contra pyproj, además del check interno.",
    )
    parser.add_argument(
        "--tolerance-mm", type=float, default=1.0,
        help="Tolerancia en milímetros para el cruce --file (por defecto 1.0 mm, igual que GeoTests).",
    )
    args = parser.parse_args()

    max_cp = check_control_points()
    max_rt = check_internal_round_trip()
    internal_ok = max_cp < 0.001 and max_rt * 1000 < 0.1

    app_ok = True
    if args.file:
        app_ok = check_against_app(args.file, tolerance_m=args.tolerance_mm / 1000.0)
    else:
        print(
            "\n(No se entregó --file: este check nunca ejercita el UTMConverter real de la app. "
            "Genera tools/utm_reference.txt con 'swift run UTMReferenceDump' y vuelve a correr "
            "con --file para cerrar ese hueco.)"
        )

    if internal_ok and app_ok:
        print("\nRESULTADO GLOBAL: OK.")
        return 0
    print("\nRESULTADO GLOBAL: REVISAR.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
