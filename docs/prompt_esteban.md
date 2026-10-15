# Prompt para el asistente de Esteban

Copiar el bloque de abajo y pegarlo en el asistente de código, abierto en la carpeta
del repo `arqueoLIDAR` en la Mac.

```
Trabajas en el repo arqueoLIDAR (app iOS PaleoRegistro), rama feat/arreglosEsteban.
Lee primero AGENTS.md y síguelo: dos personas trabajan en esta rama.

1. ACTUALIZAR
   - git status. Si hay cambios locales, haz commit antes de seguir; no los pierdas.
   - git fetch origin && git pull --no-rebase. Nunca push --force.
   - Lee lo nuevo: git log --oneline -12 y git show de los commits desde a8e2047.

2. QUÉ CAMBIÓ (escrito sin compilador, en Windows; NUNCA se ha compilado)
   - Sitios: Terreno abre en SitesListView. Crear/editar sitio (SiteFormView) con
     "Tomar ubicación con GPS" (LocationRecorder + FieldStore.representativeFix).
     Eliminar sitio solo si no tiene hallazgos (FieldStore.deleteSite).
   - Domain: Site tiene `location: GeoFix?` (nuevo test en DomainTests).
   - Cada hallazgo se crea dentro de un sitio y su expediente guarda site.json
     (queda en el manifiesto del primer sello). Hallazgos antiguos: "Hallazgos sin sitio".
   - Eliminar hallazgo solo si NO verifica como íntegro (FieldStore.deleteIfNotIntact).
   - Pestaña Diagnóstico solo en #if DEBUG (ArqueoLidarApp.swift); en Release la app
     abre directo en Sitios. El módulo Domain se muestra como "Estructura de Trabajo".
   No reviertas estas decisiones (ver AGENTS.md §3) sin una razón verificada.

3. COMPILAR
   - cd PaleoRegistro && swift build && swift test (todo debe pasar).
   - Scripts/check_module_boundaries.sh y Scripts/test_module_boundaries.sh.
   - xcodebuild -project arqueoLidar.xcodeproj -scheme arqueoLidar
     -destination 'generic/platform=iOS' build (confirma el scheme con xcodebuild -list).
   - Corrige con el cambio mínimo en el archivo correcto. Puntos de riesgo:
     FieldViews.swift (dos .sheet en SitesListView, `if let` dentro de .sheet,
     `if` dentro de .toolbar, init de SiteFormView con State(initialValue:)),
     @State de LocationRecorder dentro de SiteFormView, interpolaciones en Text.
     No silencies warnings de concurrencia con @unchecked Sendable.

4. PROBAR EN EL iPHONE PRO (no des nada por bueno sin esto)
   Instalando desde Xcode (Debug):
   a. Se ven dos pestañas: Terreno y Diagnóstico. Diagnóstico → probar todo: todas
      pasan; "Estructura de Trabajo" aparece en lugar de "Domain".
   b. Terreno muestra "Hallazgos sin sitio (N)" con los expedientes anteriores.
   c. Crear sitio al aire libre → "Tomar ubicación con GPS" → esperar lecturas →
      "Usar esta ubicación": muestra lat/lon/altura/precisión. La fila ya no dice
      "sin ubicación". Anota la precisión obtenida.
   d. Deslizar el sitio → Editar: cambiar nombre y volver a tomar GPS → se guarda.
   e. Dentro del sitio: crear hallazgo (el formulario muestra el sitio) → escanear →
      guardar → Verificar expediente → debe decir Íntegro (ahora incluye site.json).
   f. Editar de nuevo el sitio → volver al hallazgo → Verificar → sigue Íntegro.
   g. Eliminar sitio con hallazgos → "No se eliminó". Crear un sitio vacío y
      eliminarlo → desaparece.
   h. En "Hallazgos sin sitio": eliminar uno con sellos inválidos (23:04, 23:06,
      23:15) → se borra. Intentar eliminar FND-D820CF5D (íntegro) → "No se eliminó".
   i. Archivos → En mi iPhone → ArqueoLiDAR: existe Sites/ con SIT-….json, y
      Findings/FND-…/site.json en el hallazgo nuevo.
   Con configuración Release (Edit Scheme → Run → Build Configuration → Release):
   j. La app abre directo en Sitios, sin barra de pestañas ni Diagnóstico.

5. ENTREGAR
   - Commits pequeños en español (fix(app): …), con la línea Co-Authored-By de tu asistente.
   - Anota cada resultado de la sección 4 en docs/registro_pruebas.md (fecha, commit,
     ✅/❌ con números) y saca de "Pendiente" lo que ya se probó.
   - Si algo falla en el núcleo (PaleoRegistro), arréglalo en la causa raíz y agrega un test.
   - git fetch otra vez antes de subir; si hay commits nuevos, pull e integra.
     git push a feat/arreglosEsteban (sin force).
   - Entrega un resumen: qué compiló a la primera, qué corregiste y por qué, resultado
     de cada punto a–j, y qué queda pendiente.
```
