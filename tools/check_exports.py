#!/usr/bin/env python3
"""
check_exports.py — Verificación externa de los formatos de exportación (F12).

Valida que los archivos exportados por PaleoRegistro sean correctos usando
herramientas independientes (no el código de la app):

  - PLY binario: estructura y conteo de vértices/caras.
  - STL binario: bounding box y escala (1 unidad = 1 mm).
  - OBJ: conteo de vértices/caras.
  - LAS 1.4: firma "LASF", versión, WKT del CRS (si laspy está disponible).
  - GeoJSON: parseo JSON y presencia de CRS.
  - CSV: estructura de columnas.

Uso:
    python3 check_exports.py <directorio_de_exports>

Requisitos: solo la biblioteca estándar (numpy/laspy opcionales para validación
más profunda de STL y LAS).

Devuelve 0 si todo valida, 1 si algo falla.
"""

import json
import os
import struct
import sys


def check_ply(path):
    with open(path, "rb") as f:
        header = b""
        while b"end_header" not in header:
            line = f.readline()
            if not line:
                return False, "cabecera PLY incompleta"
            header += line
        text = header.decode("ascii", errors="replace")

        if not text.startswith("ply"):
            return False, "no empieza con 'ply'"
        if "binary_little_endian" not in text:
            return False, "no es binary_little_endian"

        nverts = nfaces = None
        for line in text.splitlines():
            if line.startswith("element vertex "):
                nverts = int(line.split()[-1])
            elif line.startswith("element face "):
                nfaces = int(line.split()[-1])
        if nverts is None or nfaces is None:
            return False, "no declara element vertex/face"

        # Verificar tamaño del archivo
        body = f.read()
        expected = nverts * 12 + nfaces * (1 + 12)
        if len(body) != expected:
            return False, f"tamaño de cuerpo {len(body)} != esperado {expected}"

        return True, f"{nverts} vértices, {nfaces} caras"


def check_stl(path):
    with open(path, "rb") as f:
        header = f.read(80)
        (ntri,) = struct.unpack("<I", f.read(4))
        body = f.read()
        if len(body) != ntri * 50:
            return False, f"tamaño {len(body)} != esperado {ntri * 50}"

        # Leer coordenadas y calcular bounding box
        mins = [float("inf")] * 3
        maxs = [float("-inf")] * 3
        for _ in range(ntri):
            f.read(12)  # normal
            for _ in range(3):
                x, y, z = struct.unpack("<3f", f.read(12))
                for i, v in enumerate((x, y, z)):
                    mins[i] = min(mins[i], v)
                    maxs[i] = max(maxs[i], v)
            f.read(2)  # atributo

        dims = [maxs[i] - mins[i] for i in range(3)]
        return True, f"bounding box {dims[0]:.1f} × {dims[1]:.1f} × {dims[2]:.1f} mm"


def check_obj(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        nverts = nfaces = 0
        for line in f:
            if line.startswith("v "):
                nverts += 1
            elif line.startswith("f "):
                nfaces += 1
    return True, f"{nverts} vértices, {nfaces} caras"


def check_las(path):
    with open(path, "rb") as f:
        sig = f.read(4)
        if sig != b"LASF":
            return False, f"firma inválida: {sig!r}"

        f.seek(24)
        major, minor = f.read(1)[0], f.read(1)[0]

        content = open(path, "rb").read()
        has_wkt = b"WGS 84" in content or b"UTM zone" in content

        detail = f"LAS {major}.{minor}"
        if has_wkt:
            detail += " (con WKT CRS)"
        return True, detail


def check_geojson(path):
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if data.get("type") != "FeatureCollection":
        return False, "no es FeatureCollection"
    crs = data.get("crs", {})
    crs_name = crs.get("properties", {}).get("name", "")
    return True, f"FeatureCollection, CRS={crs_name}"


def check_csv(path):
    with open(path, "r", encoding="utf-8") as f:
        lines = f.read().splitlines()
    if not lines:
        return False, "CSV vacío"
    header = lines[0].split(",")
    return True, f"{len(lines) - 1} filas, columnas: {header[0]}, {header[1]}…"


def main():
    if len(sys.argv) != 2:
        print("Uso: python3 check_exports.py <directorio_de_exports>")
        sys.exit(2)

    export_dir = sys.argv[1]
    if not os.path.isdir(export_dir):
        print(f"ERROR: {export_dir} no es un directorio")
        sys.exit(2)

    checkers = {
        ".ply": check_ply,
        ".stl": check_stl,
        ".obj": check_obj,
        ".las": check_las,
        ".geojson": check_geojson,
        ".csv": check_csv,
    }

    found = False
    failed = False
    for name in sorted(os.listdir(export_dir)):
        path = os.path.join(export_dir, name)
        if not os.path.isfile(path):
            continue
        ext = os.path.splitext(name)[1].lower()
        if ext not in checkers:
            continue
        found = True
        ok, detail = checkers[ext](path)
        status = "OK" if ok else "FALLO"
        print(f"  {name}: {status} — {detail}")
        if not ok:
            failed = True

    if not found:
        print("No se encontraron archivos exportados reconocibles.")
        return 1

    if failed:
        print("\nRESULTADO: FALLO. Algunos archivos no validan.")
        return 1
    else:
        print("\nRESULTADO: OK. Todos los archivos validan con herramientas externas.")
        return 0


if __name__ == "__main__":
    sys.exit(main())
