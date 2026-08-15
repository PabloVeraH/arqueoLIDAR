#!/usr/bin/env bash
# Guarda de arquitectura (F1): falla el build si un archivo de los módulos puros
# importa ARKit, SceneKit, RealityKit, UIKit, CoreLocation o SwiftData.
#
# Uso: Scripts/check_module_boundaries.sh <raíz_del_repositorio>
# Se integra como fase de build en Xcode y como paso de CI en Linux.

set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PACKAGE_DIR="$ROOT/PaleoRegistro"

# Módulos que NO pueden importar frameworks de plataforma.
PURE_MODULES="Domain Geometry Mesh Volume Stratigraphy Segmentation Geo Registration Custody Persistence Export"

# Imports prohibidos en módulos puros.
FORBIDDEN_IMPORTS="ARKit SceneKit RealityKit UIKit CoreLocation SwiftData Metal"

fail=0

for module in $PURE_MODULES; do
    dir="$PACKAGE_DIR/Sources/$module"
    [ -d "$dir" ] || continue
    while IFS= read -r file; do
        for imp in $FORBIDDEN_IMPORTS; do
            if grep -qE "^[[:space:]]*import[[:space:]]+$imp([[:space:]]|$)" "$file"; then
                echo "❌ [$module] import prohibido '$imp' en $file"
                fail=1
            fi
        done
    done < <(find "$dir" -name "*.swift" -type f)
done

if [ "$fail" -eq 1 ]; then
    echo "Guarda de arquitectura: FALLO."
    exit 1
fi

echo "Guarda de arquitectura: OK (sin imports prohibidos en módulos puros)."
exit 0