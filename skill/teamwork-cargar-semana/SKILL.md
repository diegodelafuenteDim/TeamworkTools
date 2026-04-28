---
description: Analiza los commits del usuario en el repo git actual de los últimos N días, los agrupa semánticamente en tickets, y los sube como tickets cerrados a Teamwork con time entries (rúbrica conservadora). Si el repo no está mapeado a un proyecto Teamwork, ofrece crear el proyecto. Usar cuando el usuario pida cargar/subir/sincronizar/registrar commits a Teamwork, o "ordenar el trabajo de la semana".
---

# Cargar Tickets a Teamwork desde commits de git

Skill que toma los commits del usuario en el repo git actual y los carga en Teamwork como tickets cerrados (con time entries) — para registrar trabajo ya hecho sin tener que abrir Teamwork manualmente.

## Cuándo usar

| Frase del usuario | Acción |
|-------------------|--------|
| "cargá / subí mis commits de la semana a Teamwork" | Flujo completo |
| "registrá lo que hice en este repo" | Flujo completo |
| "ordená mi trabajo de Teamwork" | Flujo completo |
| "cargá mis últimos N días" | Flujo con `--days N` |

Si el usuario menciona "reportes", "horas del equipo" o "qué hizo Juan" → **NO es este skill** (eso es reporting, no carga).

## Configuración

| Parámetro | Valor |
|-----------|-------|
| Repo de tooling | `c:\Net 8\TeamworkTools` |
| Cliente HTTP | `lib/tw-client.sh` (source antes de cualquier llamada) |
| Mapeo repo→proyecto | `config/repos.json` |
| Equipo | `config/equipo.json` |
| Scope IT | `config/proyectos-it.json` |
| Secrets | `secrets/teamwork.env` (TEAMWORK_API_KEY, TEAMWORK_SUBDOMAIN) |
| Asignee default | id 677620 (Diego De La Fuente) |
| Default días | 7 |
| Rúbrica de horas | conservadora B (validada con el usuario) |

## Procedimiento (seguir en orden estricto)

### Fase 0: Prerequisites

1. **Verificar que estás en un repo git**:
   ```bash
   git -C "$PWD" rev-parse --is-inside-work-tree 2>/dev/null
   ```
   Si no es repo git → reportar y DETENERSE.

2. **Resolver el path del repo actual**:
   ```bash
   REPO_PATH=$(git -C "$PWD" rev-parse --show-toplevel | sed 's|^/c/|c:/|')
   ```

3. **Verificar que TeamworkTools y dependencias existen**:
   ```bash
   test -f "c:/Net 8/TeamworkTools/lib/tw-client.sh" || { echo "ERROR: TeamworkTools no encontrado"; exit 1; }
   test -f "c:/Net 8/TeamworkTools/secrets/teamwork.env" || { echo "ERROR: secrets/teamwork.env no existe"; exit 1; }
   command -v jq >/dev/null || { echo "ERROR: jq no está instalado (winget install jqlang.jq)"; exit 1; }
   ```

4. **Cargar el cliente**:
   ```bash
   export USER="${USER:-${USERNAME:-die1fue}}"
   export PATH="/c/Users/$USER/AppData/Local/Microsoft/WinGet/Links:$PATH"
   source "c:/Net 8/TeamworkTools/lib/tw-client.sh"
   ```

### Fase 1: Detectar autor y commits

1. **Identificar al usuario actual**. Default: el responsable Diego (`diegodelafuenteDim` / id `677620`). Verificar con `git config user.name` y `user.email`. Si el autor no es Diego, **PREGUNTAR** al usuario qué hacer (mappear su id de Teamwork o usar el default).

2. **Determinar rango de fechas**. Default: últimos 7 días. Si el usuario pidió `--days N`, usar N.

3. **Listar commits del autor en el rango**:
   ```bash
   SINCE=$(date -d "$DAYS days ago" +%Y-%m-%d)
   git -C "$REPO_PATH" log --since="$SINCE" --author="$AUTHOR" \
     --reverse --pretty=format:"%ad|%h|%s" --date=short
   ```

4. **Si no hay commits**: informar al usuario y DETENERSE (nada que cargar).

### Fase 2: Resolver proyecto Teamwork

1. **Buscar el repo en `config/repos.json`**:
   ```bash
   MAPEO=$(jq --arg p "$REPO_PATH" '.mapeos[] | select((.repoPath | ascii_downcase) == ($p | ascii_downcase))' \
     "c:/Net 8/TeamworkTools/config/repos.json")
   ```

2. **Si está mapeado** → extraer `teamworkProjectId`, `teamworkProjectName`, `categoryId`. Continuar a Fase 3.

3. **Si NO está mapeado**: preguntar al usuario:
   - "¿Querés crear un proyecto nuevo en Teamwork para este repo, o asociarlo a uno existente?"
   - Si **nuevo**: pedir nombre, mostrar las categorías disponibles (ver `config/proyectos-it.json` y/o `tw_list_categories`), elegir o crear nueva categoría, y crear el proyecto vía:
     ```bash
     # Crear categoría si es nueva
     CAT_ID=$(tw_create_category "NOMBRE")
     # Crear proyecto
     PROJ_BODY=$(jq -n --arg n "$NAME" --arg c "$CAT_ID" '{project: {name: $n, "category-id": $c}}')
     PROJ_RESP=$(tw_post_v1 "/projects.json" "$PROJ_BODY")
     PROJ_ID=$(echo "$PROJ_RESP" | jq -r '.id')
     ```
   - Si **existente**: pedir el ID del proyecto. Validar que existe con `tw_get_v3 "/projects/$PID.json"`.
   - **Actualizar `config/repos.json`** con el nuevo mapeo y informar al usuario que se guardó.

### Fase 3: Análisis y agrupamiento

**Esta fase la hace Claude (no es bash automatizado).**

1. Leer la lista de commits cronológicamente.
2. Agrupar commits semánticamente en tickets candidatos:
   - Commits con el mismo `scope` (ej: `feat(llamadores):`) probablemente son el mismo ticket
   - Commits que mencionan el mismo módulo/feature/bug van juntos
   - Un ticket es una **unidad de valor** (feature, fix, refactor), no un commit individual
   - Si hay un único commit que es un fix obvio → ticket de 1 commit
3. Para cada ticket candidato, definir:
   - **Título** descriptivo en español (no copiar el primer commit message)
   - **Lista de commits** asociados con hash, fecha y mensaje
   - **Rango de fechas** (start = primer commit, due = último commit)
   - **Task list** sugerida (agrupación temática, ej: "Llamadores: ABM", "TTS / Voces", "Dashboard")

### Fase 4: Calcular horas (rúbrica conservadora B)

Para cada ticket candidato, aplicar:

| Cantidad de commits | Tipo | Minutos |
|---------------------|------|---------|
| 1 | mensaje empieza con `fix` | 30 |
| 1 | mensaje empieza con otro tipo (`feat`, `refactor`, `docs`...) | 60 |
| 2-3 | cualquiera | 120 |
| 4-5 | cualquiera | 180 |
| 6-9 | cualquiera | 300 |
| 10+ | cualquiera | 480 |

Calcular el total y el promedio diario sobre los días hábiles del rango.

### Fase 5: Mostrar propuesta y esperar OK

Presentar al usuario:

```
Proyecto destino: <nombre del proyecto> (id <PID>)
Repo: <REPO_PATH>
Rango: YYYY-MM-DD a YYYY-MM-DD
Autor: Diego De La Fuente
Commits encontrados: N
Tickets propuestos: M
Total horas: X.X h (~Y h/día sobre Z días hábiles)

Tickets:
[Tasklist]
  - Título del ticket — N commits — X h
  - ...
```

**Esperar confirmación explícita** del usuario. Permitir editar:
- Renombrar tickets
- Mover commits entre tickets
- Cambiar tasklist
- Ajustar horas

Si el total de horas suena alto al usuario (>5h/día sobre los días hábiles), **PREGUNTAR** antes de cargar — la rúbrica B asume reparto entre proyectos.

### Fase 6: Bulk insert

Para cada ticket aprobado:

1. **Asegurar tasklist** (cache por nombre):
   ```bash
   TL_BODY=$(jq -n --arg n "$TASKLIST_NAME" '{"todo-list":{"name":$n}}')
   TL_RESP=$(tw_post_v1 "/projects/$PROJ_ID/tasklists.json" "$TL_BODY")
   TL_ID=$(echo "$TL_RESP" | jq -r '.TASKLISTID')
   ```

2. **Crear ticket**:
   ```bash
   TASK_BODY=$(jq -n --arg t "$TITLE" --arg d "$DESC" --arg s "$START" --arg du "$DUE" \
     '{ "todo-item": { content: $t, description: $d, "responsible-party-id": "677620",
        "start-date": $s, "due-date": $du, priority: "low" } }')
   TASK_RESP=$(tw_post_v1 "/tasklists/$TL_ID/tasks.json" "$TASK_BODY")
   TASK_ID=$(echo "$TASK_RESP" | jq -r '.id')
   ```

3. **Marcar como completed** (a menos que el usuario haya pedido `--abierto`):
   ```bash
   tw_put_v1 "/tasks/$TASK_ID/complete.json" '{}' > /dev/null
   ```

4. **Loguear time entry** (mid-point del rango):
   ```bash
   ENTRY_BODY=$(jq -n --arg pid "677620" --arg date "$MID_DATE" --arg h "$H" --arg m "$M" \
     --arg desc "Trabajo en: $TITLE" \
     '{ "time-entry": { "person-id": $pid, date: $date, hours: $h, minutes: $m,
        isbillable: "0", description: $desc } }')
   tw_post_v1 "/tasks/$TASK_ID/time_entries.json" "$ENTRY_BODY"
   ```

### Fase 7: Reporte final

```
Tickets cargados: M
Time entries: M (X.X h totales)
Proyecto: <nombre> → https://dimcentrosdesalud.teamwork.com/app/projects/<PID>
```

## Reglas / cuidados

1. **Encoding UTF-8**: el cliente ya manda `--data-binary @tmpfile` con `charset=utf-8`. No usar `-d "..."` directo en POST/PUT — pierde acentos.
2. **Validar antes de bulk**: SIEMPRE mostrar la propuesta y esperar OK. NUNCA crear tickets sin confirmación, ni siquiera si el usuario dice "todo OK" en su mensaje inicial — confirmar específicamente sobre la propuesta exacta.
3. **Rúbrica de horas**: validar con el usuario si el total se sale de su autoestimación (~2-3 h/día por proyecto). Si se sale, ofrecer recalibrar antes de cargar.
4. **Idempotencia**: si la fase de bulk falla en la mitad, NO reintentar automáticamente — pedir al usuario que decida (continuar desde donde quedó vs. borrar lo creado y reintentar).
5. **No mapear repo sin permiso**: solo agregar a `config/repos.json` si el usuario aprobó la creación o asociación.
6. **Estado por defecto**: tickets `completed`. Si el usuario aclara que parte del trabajo sigue, dejar esos en `in progress` (no marcar complete).
7. **Días hábiles**: para los promedios, contar lun-vie. Para fechas de tickets/time entries, usar las fechas de los commits tal cual (incluso fines de semana — los commits pueden ser sábado).
8. **Si rate limit (HTTP 429 o 000)**: hacer pausa de 1s y reintentar. Si persiste, abortar e informar.

## Errores comunes

| Error | Causa | Solución |
|-------|-------|---------|
| "TeamworkTools no encontrado" | El repo no está en `c:\Net 8\TeamworkTools` | Reinstalar el repo o ajustar la ruta |
| "secrets/teamwork.env no existe" | Falta el archivo de credenciales | Crear desde `secrets/teamwork.env.example` |
| "jq no está instalado" | jq no en PATH | `winget install jqlang.jq` |
| "No hay commits" | El rango no encontró commits del autor | Sugerir aumentar `--days` o verificar autor |
| Tickets duplicados después de un retry | Bulk se reintentó sin limpiar | El skill NO reintenta. Si pasó, borrar manualmente con `tw_delete` (ver gotcha de DELETE en README) |
| HTTP 000 en DELETE en loop | Bug de Teamwork con loops bash | Traer un ID por iteración, no procesar lista pre-fetchada |

## Variantes

| Argumento del usuario | Comportamiento |
|-----------------------|----------------|
| (sin args) | Últimos 7 días, autor = git user actual o Diego |
| `--days 14` | Últimos 14 días |
| `--abierto` | Tickets en estado `in progress` (no completed) |
| `--proyecto <id>` | Forzar proyecto destino, ignorar mapeo |
| `--autor <email>` | Filtrar por otro autor del equipo |
| `--dry-run` | Mostrar la propuesta pero NO crear nada |
