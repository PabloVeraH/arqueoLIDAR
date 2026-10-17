#!/usr/bin/env python3
"""
validate_reference.py — Resume el protocolo de validación en terreno (Fase 16).

Lee docs/validation_log.csv (una fila por corrida: lo que midió la app contra
una referencia física de valor conocido) y calcula, por magnitud y condición
(sombra / sol), el sesgo, la dispersión y la banda de error. Para el ensayo
nulo (dos escaneos sin cambio) calcula el piso de ruido del monitoreo.

Uso:
    python3 tools/validate_reference.py [docs/validation_log.csv] [--escribir docs/VALIDATION.md]

Con --escribir, reemplaza en ese archivo el bloque entre
<!-- resumen --> y <!-- /resumen -->. Sin él, imprime la tabla.
"""

import csv
import os
import statistics
import sys

# Repeticiones mínimas por magnitud (plan, Fase 16), en cada condición.
MINIMOS = {
    "escala_lineal": 5,
    "volumen_positivo": 5,
    "volumen_cavidad": 3,
    "potencia_estrato": 5,
    "volumen_solido": 3,
    "ensayo_nulo": 5,
    "recuperacion_cambio": 3,
    "sesgo_gps": 3,
}
CONDICIONES = ("sombra", "sol")
COLUMNAS = ["fecha", "commit", "magnitud", "condicion", "referencia", "medido",
            "unidad", "distancia_m", "material", "notas"]


def leer(ruta):
    with open(ruta, newline="", encoding="utf-8") as f:
        filas = list(csv.DictReader(f))
    for i, fila in enumerate(filas, start=2):
        if fila["magnitud"] not in MINIMOS:
            raise SystemExit(f"Línea {i}: magnitud desconocida «{fila['magnitud']}» (válidas: {', '.join(MINIMOS)})")
        if fila["condicion"] not in CONDICIONES:
            raise SystemExit(f"Línea {i}: condición «{fila['condicion']}» (válidas: sombra, sol)")
        fila["referencia"], fila["medido"] = float(fila["referencia"]), float(fila["medido"])
    return filas


def resumir(filas):
    """Una fila de resultado por (magnitud, condición), incluidas las que faltan."""
    salida = []
    for magnitud, minimo in MINIMOS.items():
        for condicion in CONDICIONES:
            grupo = [f for f in filas if f["magnitud"] == magnitud and f["condicion"] == condicion]
            unidad = grupo[0]["unidad"] if grupo else ""
            errores = [f["medido"] - f["referencia"] for f in grupo]
            n = len(errores)
            r = {"magnitud": magnitud, "condicion": condicion, "n": n, "minimo": minimo, "unidad": unidad}
            if n:
                sesgo = statistics.fmean(errores)
                sd = statistics.stdev(errores) if n > 1 else 0.0
                r.update(sesgo=sesgo, sd=sd, banda=(sesgo - 2 * sd, sesgo + 2 * sd))
                relativos = [e / f["referencia"] for e, f in zip(errores, grupo) if f["referencia"]]
                r["relativo"] = statistics.fmean(relativos) if relativos else None
                if magnitud == "ensayo_nulo":
                    # Lo que el sistema "ve" cambiar donde no cambió nada: bajo este
                    # umbral ninguna detección de monitoreo se puede afirmar.
                    r["piso_ruido"] = max(abs(e) for e in errores)
            r["estado"] = "OK" if n >= minimo else (f"faltan {minimo - n}" if n else "sin datos")
            salida.append(r)
    return salida


def tabla(resultados):
    def num(x):
        return f"{x:.4g}"
    lineas = ["| Magnitud | Condición | Corridas | Sesgo | Desv. | Banda (±2σ) | Error relativo | Estado |",
              "|---|---|---|---|---|---|---|---|"]
    for r in resultados:
        if r["n"]:
            u = r["unidad"]
            banda = f"{num(r['banda'][0])} a {num(r['banda'][1])} {u}"
            rel = f"{r['relativo'] * 100:.1f} %" if r.get("relativo") is not None else "—"
            if "piso_ruido" in r:
                rel = f"piso de ruido {num(r['piso_ruido'])} {u}"
            fila = [r["magnitud"], r["condicion"], f"{r['n']}/{r['minimo']}", f"{num(r['sesgo'])} {u}",
                    f"{num(r['sd'])} {u}", banda, rel, r["estado"]]
        else:
            fila = [r["magnitud"], r["condicion"], f"0/{r['minimo']}", "—", "—", "—", "—", r["estado"]]
        lineas.append("| " + " | ".join(fila) + " |")
    completas = all(r["estado"] == "OK" for r in resultados)
    lineas.append("")
    lineas.append("**Validación completa.**" if completas else
                  "**Validación incompleta:** la app debe seguir diciendo «no validada».")
    return "\n".join(lineas)


def escribir(ruta, texto):
    with open(ruta, encoding="utf-8") as f:
        doc = f.read()
    ini, fin = "<!-- resumen -->", "<!-- /resumen -->"
    if ini not in doc or fin not in doc:
        raise SystemExit(f"{ruta} no tiene el bloque {ini} … {fin}")
    antes, resto = doc.split(ini, 1)
    _, despues = resto.split(fin, 1)
    with open(ruta, "w", encoding="utf-8", newline="") as f:
        f.write(f"{antes}{ini}\n{texto}\n{fin}{despues}")


def main():
    args = sys.argv[1:]
    destino = None
    if "--escribir" in args:
        i = args.index("--escribir")
        destino = args[i + 1]
        del args[i:i + 2]
    raiz = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ruta = args[0] if args else os.path.join(raiz, "docs", "validation_log.csv")
    texto = tabla(resumir(leer(ruta)))
    if destino:
        escribir(destino, texto)
        print(f"Resumen escrito en {destino}")
    else:
        print(texto)


if __name__ == "__main__":
    main()
