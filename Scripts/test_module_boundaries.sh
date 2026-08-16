#!/usr/bin/env bash
# Auto-test de la guarda de arquitectura (F1, plan §3 criterio de aceptación):
# "La guarda de arquitectura falla deliberadamente cuando se le agrega
# `import SceneKit` a un archivo de `Domain/` de prueba, y vuelve a pasar al
# quitarlo. Probar que la guarda falla es parte del criterio — una guarda que
# nunca se vio fallar no es una guarda."
#
# Este script no reemplaza a check_module_boundaries.sh: lo ejercita.
#
# Uso: Scripts/test_module_boundaries.sh [<raíz_del_repositorio>]
# Código de salida 0 si las tres aserciones pasan, 1 en caso contrario.

set -u

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
GUARD="$ROOT/Scripts/check_module_boundaries.sh"
PROBE_FILE="$ROOT/PaleoRegistro/Sources/Domain/__ArchitectureGuardProbe.swift"

cleanup() {
    rm -f "$PROBE_FILE"
}
trap cleanup EXIT

fail=0

# 1. Línea base: el repo tal cual debe pasar.
if ! "$GUARD" "$ROOT" > /dev/null 2>&1; then
    echo "❌ [1/3] La guarda falla sobre el repo sin modificar — no debería."
    fail=1
else
    echo "✅ [1/3] La guarda pasa sobre el repo sin modificar."
fi

# 2. Inyectar un import prohibido en Domain/ y verificar que la guarda
#    detecta la violación y falla (exit != 0).
cat > "$PROBE_FILE" << 'EOF'
import SceneKit
// Archivo de prueba temporal — Scripts/test_module_boundaries.sh lo borra
// después de esta corrida. Si ves esto en el árbol de trabajo, algo salió
// mal (revisa Scripts/test_module_boundaries.sh).
EOF

if "$GUARD" "$ROOT" > /dev/null 2>&1; then
    echo "❌ [2/3] La guarda NO detectó 'import SceneKit' inyectado en Domain/."
    fail=1
else
    echo "✅ [2/3] La guarda detecta y rechaza 'import SceneKit' inyectado en Domain/."
fi

# 3. Quitar el archivo de prueba y verificar que la guarda vuelve a pasar.
rm -f "$PROBE_FILE"

if ! "$GUARD" "$ROOT" > /dev/null 2>&1; then
    echo "❌ [3/3] La guarda sigue fallando después de quitar la violación."
    fail=1
else
    echo "✅ [3/3] La guarda vuelve a pasar después de quitar la violación."
fi

if [ "$fail" -eq 1 ]; then
    echo "Auto-test de la guarda de arquitectura: FALLO."
    exit 1
fi

echo "Auto-test de la guarda de arquitectura: OK."
exit 0
