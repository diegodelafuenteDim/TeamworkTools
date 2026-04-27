# TeamworkTools

Skill, agente y rutinas programadas para integrar Claude Code con la API de Teamwork (Projects v3 + v1) de la cuenta `dimcentrosdesalud.teamwork.com`.

Pensado para que el responsable del sector de desarrollo (Diego De La Fuente) pueda:
- Listar / crear / actualizar tickets desde Claude Code en cualquier proyecto.
- Consultar al equipo y a Teamwork en lenguaje natural mediante un subagente.
- Recibir reportes recurrentes (semanal del equipo, WIP diario, mis tickets) generados automáticamente.

## Estructura

```
TeamworkTools/
├── skill/SKILL.md              ← skill /teamwork con sub-comandos
├── agent/teamwork-agent.md     ← subagente NL
├── scheduled/                  ← rutinas cron (semanal, WIP, mis-tickets)
├── lib/tw-client.sh            ← wrapper API (auth, paginación, workarounds)
├── lib/tw-reports.sh           ← funciones de agregación
├── config/
│   ├── equipo.json             ← los 12 IDs del equipo (versionado)
│   └── proyectos-it.json       ← scope IT (categorías + overrides)
├── secrets/teamwork.env        ← API key (gitignored)
├── reports/                    ← salida de reportes (gitignored)
└── docs/plans/                 ← design docs y planes
```

## Instalación

### 1) Requisitos

- Bash (Git Bash en Windows funciona)
- `curl` (incluido en Windows 10+)
- `jq` 1.6+ — instalar con `winget install jqlang.jq`
- `git`

### 2) Clonar y configurar credenciales

```bash
cd "c:/Net 8"
# Si todavía no existe el repo remoto, ya está acá. Si existe:
# git clone <url> TeamworkTools
cd TeamworkTools
cp secrets/teamwork.env.example secrets/teamwork.env
# Editar secrets/teamwork.env y poner la API key real
```

La API key se obtiene en Teamwork → click en avatar → **Edit my details** → pestaña **API & Mobile** → **Generate new token**.

### 3) Crear los symlinks para que Claude Code vea el skill y el agente

```bash
# Skill (visible como /teamwork desde cualquier proyecto)
cmd //c mklink /D "C:\Users\die1fue\.claude\skills\teamwork" "C:\Net 8\TeamworkTools\skill"

# Agente (invocable como subagente teamwork)
mkdir -p "C:/Users/die1fue/.claude/agents"
cmd //c mklink "C:\Users\die1fue\.claude\agents\teamwork.md" "C:\Net 8\TeamworkTools\agent\teamwork-agent.md"
```

(En Windows los symlinks requieren modo dev habilitado o terminal admin.)

### 4) Probar el cliente

```bash
source lib/tw-client.sh
tw_get_v3 "/me.json" | jq .person.firstName
```

Debe devolver `"Diego"` (o el nombre del dueño de la API key).

## Configuración

### `config/equipo.json`

Define los 12 miembros del equipo de desarrollo y los `fueraDeAlcance` (gente que aparece en Teamwork pero no es del equipo). Editar cuando entre o salga gente.

### `config/proyectos-it.json`

Define el scope IT efectivo:

- `categoriasIncluidas`: 22 categorías de proyectos del sector de desarrollo.
- `categoriasExcluidas`: actualmente sólo `SOPORTES INFRA` (otro equipo).
- `proyectosIncluirSiempre`: overrides puntuales (proyectos sin categoría que igual cuentan).
- `proyectosExcluirSiempre`: overrides para excluir proyectos puntuales.

La función `tw_get_scope_proyectos_it` resuelve la regla:

```
scope = (categoriasIncluidas ∪ proyectosIncluirSiempre)
        − categoriasExcluidas
        − proyectosExcluirSiempre
        ∩ status=active
```

## Hallazgos del relevamiento inicial (2026-04-27)

- **Cuenta**: `dimcentrosdesalud.teamwork.com`, 1 empresa (DIM Centros de Salud).
- **23 personas** en la plataforma; **12 son del equipo** de desarrollo.
- **Equipo de Infra fuera de alcance** — no usa Teamwork (sólo Martin Rzeszut tiene cuenta).
- **37 proyectos activos** en Teamwork, en 23 categorías.
- **35 proyectos en scope IT efectivo** (37 − 2 de SOPORTES INFRA).
- **Saneamiento aplicado**:
  - Creada categoría `GESTION INTERNA` (id 51077).
  - 3 proyectos transversales movidos ahí: Mejoras y Cambios, Mesa de entrada, Reuniones y tareas de equipo.
  - 4 proyectos archivados: Análisis nuevos proyectos, Ejemplo/Pruebas, Gant General, Reclamos y Automatizaciones.

## Gotchas conocidos de la API

| Bug / particularidad | Workaround |
|----------------------|-----------|
| `/projects.json?tagIds=` se ignora — el filtro de tag de proyecto no funciona | No usar tag de proyecto para filtrar; usar categoría + override JSON |
| Tags de proyecto no se heredan a las tareas | Si se quiere clasificar tickets, taguear por ticket |
| `/projects/{id}/archive.json` requiere `{"status":"inactive"}` (no `archive`) | Está en `tw_archive_project()` |
| v3 no permite `PATCH` en `/projects/{id}.json`, sí `PUT` | `tw_put_v3()` |
| Asignar categoría a un proyecto: la lectura inmediata muestra `null`; recién en una segunda lectura aparece el cambio | Asumir éxito si STATUS:OK, no verificar inline |
| JSON de proyectos tiene claves duplicadas (`customfieldValues` / `customFieldValues`) | jq las maneja bien; PowerShell 5.1 ConvertFrom-Json no — usar jq siempre |
| Mojibake al imprimir UTF-8 desde la consola Windows | jq output a archivo y leerlo, o forzar `chcp 65001` |
| Strings con acentos via `-d "..."` desde Git Bash en Windows pierden los no-ASCII | Cliente usa `--data-binary @tmpfile` + `Content-Type: charset=utf-8` (todo `tw_post_v*`/`tw_put_v*`) |
| `POST /projects.json` con `start-date` solo falla — requiere también `end-date` | Pasar ambas o ninguna |
| Cuando una tasklist queda 100% completed, sus tasks no aparecen en listings (`/projects/{id}/tasks.json`, `/tasklists/{id}/tasks.json`, `?includeCompletedTasks=true`, `?filter=all`, etc.) — sí accesibles por id directo y en la UI bajo "Completed task lists" | Mantener cache local de IDs si hay que iterar histórico |
| `DELETE` en bash loop con lista pre-fetchada: solo el primer call funciona, el resto devuelve HTTP 000 (connection failed) — incluso con throttling | Traer un ID por iteración del API en cada vuelta del loop, no procesar la lista completa de una |
| Rate limit visible en header `x-ratelimit-limit: 150 / 60s` | El cliente respeta esto; un sleep 0.4s entre DELETEs es prudente |
| `/time.json` usa `startDate`/`endDate` para filtrar por rango. `fromDate`/`toDate` se ignoran silenciosamente (devuelve todo el histórico) | Usar `startDate`/`endDate` siempre. Cliente lo respeta en `_tw_fetch_horas` |
| Filtro `assignedToUserIds=<csv>` en `/tasks.json` NO es estricto: incluye también tasks sin asignar y con asignados fuera del csv | Filtrar client-side con jq: `select(.assigneeUserIds \| any(. as $a; $eq \| index($a)))` |
| Filtro `createdByUserIds=<csv>` también es laxo | Filtrar client-side con `.createdByUserId == $u` |
| `tasks[].projectId` viene `null` en respuesta directa de `/tasks.json` | Cruzar via `included.tasklists[<tasklistId>].projectId`. Cliente lo hace en `_tw_fetch_tasks_query` con `?include=tasklists` |
| `--argjson` en jq con var grande revienta ARG_MAX en Git Bash Windows (`Argument list too long`) | Usar `--slurpfile` con tmpfile en lugar de pasar JSON inline |
| jq < 1.7: `from_entries` NO acepta `{k, v}` shorthand. Da error críptico `Cannot use null (null) as object key` | Usar `{key, value}` explícito |
| Emoji con variation selector (`↔️`) en `name` de proyecto via POST/PUT v1 produce mojibake | Evitar emojis en nombres; mantener ASCII + acentos |
| `PUT /projects/{id}.json` para asignar categoría devuelve `STATUS:OK` pero la categoría puede tardar 10-30s en aparecer en `GET v1` (v3 la refleja antes) | Asumir éxito si STATUS:OK; verificar via v3, no v1 |

## Reportes implementados (`lib/tw-reports.sh`)

| Función | Output |
|---------|--------|
| `tw_report_semanal [YYYY-MM-DD]` | `reports/<hoy>/semanal-equipo.md` — cerrados / nuevos / horas, agrupado por persona y por proyecto. Sin arg: última semana lun-dom cerrada |
| `tw_report_wip [YYYY-MM-DD]` | `reports/<hoy>/wip.md` — snapshot diario, activos por persona con flags `[STALE Nd]` (>7d sin update) y `[BLQ]` (tag bloqueado/bloqueada) |
| `tw_report_mis_tickets [YYYY-MM-DD]` | `reports/<hoy>/mis-tickets.md` — vencidos, due 3d, asignados a mí, creados por mí (asignados a otros). Lee `responsable.id` de `equipo.json` |

Sourcing: `source lib/tw-reports.sh` → cliente HTTP se carga solo.

## Comandos del skill (planificados)

(Pendientes de implementar — esta entrega cierra estructura + cliente.)

| Comando | Descripción |
|---------|-------------|
| `/teamwork list` | Lista tickets (filtros: proyecto, asignado, estado, due) |
| `/teamwork mis-tickets` | Tickets del responsable, filtrados con criterio útil |
| `/teamwork create` | Crea un ticket nuevo |
| `/teamwork update` | Actualiza estado / asignado / comentarios de un ticket |
| `/teamwork log-time` | Carga horas a un ticket |
| `/teamwork equipo` | Resumen del equipo de desarrollo |
| `/teamwork reporte semanal` | Reporte del equipo de la semana pasada |
| `/teamwork reporte wip` | WIP del día |
| `/teamwork sanear` | Diagnóstico de saneamiento (proyectos sin categoría, sin owner, viejos) |

## Reportes programados (planificados)

| Cuándo | Reporte |
|--------|---------|
| Cada lunes 8:00 AM | Resumen semanal del equipo |
| Cada día 8:00 AM | WIP del equipo |
| Cada día 8:00 AM | Tus tickets del día (responsable) |

Salida en `reports/YYYY-MM-DD/<reporte>.md` (gitignored).

## Seguridad

- La API key vive en `secrets/teamwork.env` y nunca se commitea (cubierto por `.gitignore`).
- No se loguea la key en stdout/stderr.
- Si se rota la key, sólo hay que actualizar el `.env`; el resto del código no cambia.
