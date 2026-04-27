#!/usr/bin/env bash
# tw-reports.sh — funciones de agregación y renderizado de reportes recurrentes.
#
# Reportes implementados:
#   tw_report_semanal     [YYYY-MM-DD]   Resumen semanal del equipo (lun-dom)
#   tw_report_wip         [YYYY-MM-DD]   WIP del equipo (snapshot del día)
#   tw_report_mis_tickets [YYYY-MM-DD]   Mis tickets del día (responsable)
#
# Cada función escribe un .md en reports/YYYY-MM-DD/<nombre>.md y devuelve el path.

set -uo pipefail

# Cargar cliente HTTP si no está ya sourceado.
if [[ "${TW_CLIENT_LOADED:-0}" != "1" ]]; then
  _TW_REPORTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck disable=SC1091
  source "$_TW_REPORTS_DIR/tw-client.sh"
fi

# -- Helpers de fechas ---------------------------------------------------------

# _tw_semana_lun_dom [YYYY-MM-DD]
# Sin argumento: devuelve lunes-domingo de la semana pasada (la última cerrada).
# Con argumento: devuelve lunes-domingo de la semana que contiene esa fecha.
# Output: "FROM TO" en formato YYYY-MM-DD separado por espacio.
_tw_semana_lun_dom() {
  local ref="${1:-}"
  local from to
  if [[ -z "$ref" ]]; then
    # Última semana cerrada (lun-dom). Fórmula: to = hoy - dow_hoy días; from = to - 6.
    # Si hoy es lunes (dow=1): to=ayer (domingo). Si hoy es domingo (dow=7): to=hace 7d.
    local dow_hoy; dow_hoy=$(date +%u)
    to=$(date -d "today -${dow_hoy} days" +%Y-%m-%d)
    from=$(date -d "$to -6 days" +%Y-%m-%d)
  else
    # Semana lun-dom que contiene $ref.
    local dow; dow=$(date -d "$ref" +%u)   # 1=lun..7=dom
    from=$(date -d "$ref -$((dow-1)) days" +%Y-%m-%d)
    to=$(date -d "$from +6 days" +%Y-%m-%d)
  fi
  echo "$from $to"
}

# _tw_hoy → fecha actual YYYY-MM-DD.
_tw_hoy() { date +%Y-%m-%d; }

# -- Helpers de contexto (equipo + scope) --------------------------------------
# Cargan una sola vez por proceso. Setean:
#   TW_RPT_EQUIPO_CSV       "id,id,..."
#   TW_RPT_EQUIPO_NOMBRES   JSON object {"id": "Nombre", ...}
#   TW_RPT_SCOPE_CSV        "id,id,..."
#   TW_RPT_SCOPE_NOMBRES    JSON object {"id": "Nombre", ...}
_tw_load_contexto() {
  [[ -n "${TW_RPT_EQUIPO_CSV:-}" ]] && return 0
  TW_RPT_EQUIPO_CSV=$(tw_get_equipo_ids_csv)
  TW_RPT_EQUIPO_NOMBRES=$(jq '[.equipo[] | {key: (.id|tostring), value: .nombre}] | from_entries' "$TW_REPO_ROOT/config/equipo.json")
  local scope_json; scope_json=$(tw_get_scope_proyectos_it)
  TW_RPT_SCOPE_CSV=$(echo "$scope_json" | jq -r '[.[].id] | join(",")')
  TW_RPT_SCOPE_NOMBRES=$(echo "$scope_json" | jq '[.[] | {key: (.id|tostring), value: .name}] | from_entries')
  export TW_RPT_EQUIPO_CSV TW_RPT_EQUIPO_NOMBRES TW_RPT_SCOPE_CSV TW_RPT_SCOPE_NOMBRES
}

# -- Fetch enriquecido de tasks ------------------------------------------------
# _tw_fetch_tasks_enriched FROM TO MODE
#   MODE ∈ closed | created
# Pagina manualmente para preservar included.tasklists en cada página y
# resolver projectId desde el tasklist. Devuelve un JSON array de tasks
# con campos planos: id, name, status, projectId, projectName,
# assigneeUserIds, completedAt, createdAt, dateUpdated.
_tw_fetch_tasks_enriched() {
  local from="$1" to="$2" mode="$3"
  _tw_load_contexto

  local extra="" includeCompleted="true"
  case "$mode" in
    closed)  extra="completedAfter=${from}&completedBefore=${to}" ;;
    created) extra="createdAfter=${from}&createdBefore=${to}" ;;
    wip)     extra=""; includeCompleted="false" ;;
    *) echo "ERROR: mode inválido '$mode' (closed|created|wip)" >&2; return 1 ;;
  esac

  _tw_fetch_tasks_query "assignedToUserIds=${TW_RPT_EQUIPO_CSV}&projectIds=${TW_RPT_SCOPE_CSV}&includeCompletedTasks=${includeCompleted}&include=tasklists${extra:+&}${extra}"
}

# _tw_fetch_tasks_query QUERYSTRING
# Helper genérico: pagina /tasks.json con la query dada (sin "?", sin pageSize).
# Preserva included.tasklists para resolver projectId. Devuelve array enriquecido.
# Útil para queries con assignedToUserIds, createdByUserIds, dueAfter, etc.
_tw_fetch_tasks_query() {
  local query="$1"
  _tw_load_contexto
  local tmp_resp tmp_scope tmp_acc
  tmp_resp=$(mktemp -t tw-resp-XXXXXX.json)
  tmp_scope=$(mktemp -t tw-scope-XXXXXX.json)
  tmp_acc=$(mktemp -t tw-acc-XXXXXX.json)
  printf '%s' "$TW_RPT_SCOPE_NOMBRES" > "$tmp_scope"
  printf '[]' > "$tmp_acc"

  local page=1 size=100 hasMore
  while :; do
    tw_get_v3 "/tasks.json?${query}&page=${page}&pageSize=${size}" > "$tmp_resp"
    jq --slurpfile scope "$tmp_scope" --slurpfile acc "$tmp_acc" '
      ((.included.tasklists // {}) | with_entries(.value = .value.projectId)) as $tl
      | $acc[0] + [
          .tasks[]? | . as $t
          | ($tl[($t.tasklistId | tostring)] // null) as $pid
          | {
              id: $t.id,
              name: $t.name,
              status: $t.status,
              projectId: $pid,
              projectName: ($scope[0][($pid | tostring)] // "(fuera de scope)"),
              assigneeUserIds: ($t.assigneeUserIds // []),
              createdByUserId: $t.createdByUserId,
              completedAt: $t.completedAt,
              createdAt: $t.createdAt,
              dateUpdated: $t.dateUpdated,
              dueDate: $t.dueDate,
              tagNames: [($t.tags // [])[]?.name | select(. != null)]
            }
        ]
    ' "$tmp_resp" > "${tmp_acc}.new"
    mv "${tmp_acc}.new" "$tmp_acc"
    hasMore=$(jq -r '.meta.page.hasMore // false' "$tmp_resp")
    [[ "$hasMore" != "true" ]] && break
    page=$((page+1))
  done
  cat "$tmp_acc"
  rm -f "$tmp_resp" "$tmp_scope" "$tmp_acc"
}

# -- Reporte 1: Resumen semanal del equipo ------------------------------------
# tw_report_semanal [YYYY-MM-DD]
# Sin arg: semana lun-dom inmediatamente anterior cerrada.
# Con arg: semana lun-dom que contiene esa fecha.
# Output: imprime path del .md generado.
tw_report_semanal() {
  local ref="${1:-}"
  local rango from to
  rango=$(_tw_semana_lun_dom "$ref")
  from=${rango% *}; to=${rango#* }
  _tw_load_contexto

  local closed created horas
  closed=$(_tw_fetch_tasks_enriched "$from" "$to" closed)
  created=$(_tw_fetch_tasks_enriched "$from" "$to" created)
  horas=$(_tw_fetch_horas "$from" "$to")

  local out_dir="$TW_REPO_ROOT/reports/$(_tw_hoy)"
  mkdir -p "$out_dir"
  local out_md="$out_dir/semanal-equipo.md"

  # Volcar a tmpfiles para no tocar ARG_MAX en jq.
  local tmp_closed tmp_created tmp_horas tmp_eq tmp_scope
  tmp_closed=$(mktemp);  printf '%s' "$closed"  > "$tmp_closed"
  tmp_created=$(mktemp); printf '%s' "$created" > "$tmp_created"
  tmp_horas=$(mktemp);   printf '%s' "$horas"   > "$tmp_horas"
  tmp_eq=$(mktemp);      printf '%s' "$TW_RPT_EQUIPO_NOMBRES" > "$tmp_eq"
  tmp_scope=$(mktemp);   printf '%s' "$TW_RPT_SCOPE_NOMBRES"  > "$tmp_scope"

  # Agregaciones con jq y emisión de markdown.
  jq -nr \
    --arg from "$from" --arg to "$to" --arg gen "$(date '+%Y-%m-%d %H:%M')" \
    --slurpfile closed "$tmp_closed" \
    --slurpfile created "$tmp_created" \
    --slurpfile horas "$tmp_horas" \
    --slurpfile eq "$tmp_eq" \
    --slurpfile scope "$tmp_scope" '
    def fmt_h: . / 60 | .*10 | round / 10;
    ($closed[0])  as $C
    | ($created[0]) as $N
    | ($horas[0])   as $H
    | ($eq[0])      as $EQ
    | ($scope[0])   as $SC
    | ($EQ | to_entries | map({uid: (.key|tonumber), nombre: .value}) | sort_by(.nombre)) as $miembros
    | ($C | map(.assigneeUserIds[]?) | group_by(.) | map({key: (.[0]|tostring), value: length}) | from_entries) as $cerradosByUid
    | ($N | map(.assigneeUserIds[]?) | group_by(.) | map({key: (.[0]|tostring), value: length}) | from_entries) as $nuevosByUid
    | ($H | group_by(.userId) | map({key: (.[0].userId|tostring), value: ([.[].minutes]|add)}) | from_entries) as $minByUid
    | ($C | group_by(.projectId) | map({pid: .[0].projectId, name: .[0].projectName, count: length})) as $cerradosByProy
    | ($N | group_by(.projectId) | map({pid: .[0].projectId, name: .[0].projectName, count: length})) as $nuevosByProy
    | ($H | group_by(.projectId) | map({pid: .[0].projectId, name: ($SC[(.[0].projectId|tostring)] // "(fuera de scope)"), minutes: ([.[].minutes]|add)})) as $horasByProy
    | (($cerradosByProy + $nuevosByProy + $horasByProy) | map(.pid) | unique) as $allProyIds
    | ($allProyIds | map(. as $pid
        | {
            pid: $pid,
            name: (($SC[($pid|tostring)]) // ($cerradosByProy[]|select(.pid==$pid)|.name) // ($nuevosByProy[]|select(.pid==$pid)|.name) // "?"),
            cerrados: (($cerradosByProy[]|select(.pid==$pid)|.count) // 0),
            nuevos:   (($nuevosByProy[]|select(.pid==$pid)|.count) // 0),
            minutes:  (($horasByProy[]|select(.pid==$pid)|.minutes) // 0)
          })) as $proyectos
    | "# Resumen semanal del equipo — \($from) a \($to)\n",
      "**Generado:** \($gen) · **Equipo:** \($miembros|length) · **Scope:** \($SC|length) proyectos IT\n",
      "## Totales",
      "| Cerrados | Nuevos | Horas |",
      "|---------:|-------:|------:|",
      "| \($C|length) | \($N|length) | \(([$H[].minutes]|add // 0) | fmt_h) |",
      "",
      "## Por persona",
      "| Persona | Cerrados | Nuevos | Horas |",
      "|---------|---------:|-------:|------:|",
      ($miembros[] | "| \(.nombre) | \(($cerradosByUid[(.uid|tostring)]) // 0) | \(($nuevosByUid[(.uid|tostring)]) // 0) | \((($minByUid[(.uid|tostring)]) // 0) | fmt_h) |"),
      "",
      "## Por proyecto",
      "| Proyecto | Cerrados | Nuevos | Horas |",
      "|----------|---------:|-------:|------:|",
      ($proyectos | sort_by(-.minutes, -.cerrados, .name)[] | "| \(.name) | \(.cerrados) | \(.nuevos) | \(.minutes | fmt_h) |")
  ' > "$out_md"

  rm -f "$tmp_closed" "$tmp_created" "$tmp_horas" "$tmp_eq" "$tmp_scope"
  echo "$out_md"
}

# -- Fetch de horas ------------------------------------------------------------
# _tw_fetch_horas FROM TO
# Pagina /time.json con filtro startDate/endDate (¡no fromDate/toDate, esos
# se ignoran silenciosamente!). Devuelve JSON array con campos planos:
# userId, projectId, projectName, taskId, minutes, timeLogged.
_tw_fetch_horas() {
  local from="$1" to="$2"
  _tw_load_contexto
  local base="/time.json?userIds=${TW_RPT_EQUIPO_CSV}&projectIds=${TW_RPT_SCOPE_CSV}&startDate=${from}&endDate=${to}"
  local tmp_resp tmp_scope tmp_acc
  tmp_resp=$(mktemp -t tw-time-XXXXXX.json)
  tmp_scope=$(mktemp -t tw-tscope-XXXXXX.json)
  tmp_acc=$(mktemp -t tw-tacc-XXXXXX.json)
  printf '%s' "$TW_RPT_SCOPE_NOMBRES" > "$tmp_scope"
  printf '[]' > "$tmp_acc"

  local page=1 size=200 hasMore
  while :; do
    tw_get_v3 "${base}&page=${page}&pageSize=${size}" > "$tmp_resp"
    jq --slurpfile scope "$tmp_scope" --slurpfile acc "$tmp_acc" '
      $acc[0] + [
        .timelogs[]?
        | {
            userId,
            projectId,
            projectName: ($scope[0][(.projectId|tostring)] // "(fuera de scope)"),
            taskId,
            minutes,
            timeLogged
          }
      ]
    ' "$tmp_resp" > "${tmp_acc}.new"
    mv "${tmp_acc}.new" "$tmp_acc"
    hasMore=$(jq -r '.meta.page.hasMore // false' "$tmp_resp")
    [[ "$hasMore" != "true" ]] && break
    page=$((page+1))
  done
  cat "$tmp_acc"
  rm -f "$tmp_resp" "$tmp_scope" "$tmp_acc"
}

# -- Reporte 2: WIP del equipo ------------------------------------------------
# tw_report_wip [YYYY-MM-DD]
# Snapshot del día. Para cada miembro del equipo:
#   - tareas activas (status != completed)
#   - stale: dateUpdated > 7 días atrás
#   - bloqueadas: tags contienen "bloque..." (case-insensitive)
# Output: imprime path del .md generado.
#
# Nota gotcha: el filtro assignedToUserIds=<csv> NO es estricto (devuelve
# tasks sin asignar y con asignados fuera del csv). Filtramos client-side.
tw_report_wip() {
  local ref="${1:-$(_tw_hoy)}"
  _tw_load_contexto

  local wip
  wip=$(_tw_fetch_tasks_enriched "" "" wip)

  local out_dir="$TW_REPO_ROOT/reports/$(_tw_hoy)"
  mkdir -p "$out_dir"
  local out_md="$out_dir/wip.md"

  local tmp_wip tmp_eq
  tmp_wip=$(mktemp); printf '%s' "$wip" > "$tmp_wip"
  tmp_eq=$(mktemp);  printf '%s' "$TW_RPT_EQUIPO_NOMBRES" > "$tmp_eq"

  jq -nr \
    --arg fecha "$ref" --arg gen "$(date '+%Y-%m-%d %H:%M')" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile wip "$tmp_wip" \
    --slurpfile eq "$tmp_eq" '
    def parse_iso: . | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    def days_since($ts): (($now | parse_iso) - ($ts | parse_iso)) / 86400 | floor;

    ($eq[0]) as $EQ
    | ($eq[0] | keys | map(tonumber)) as $EQ_IDS
    | ($EQ | to_entries | map({uid: (.key|tonumber), nombre: .value}) | sort_by(.nombre)) as $miembros
    | ($wip[0]
        | map(. + {
            assigneesEquipo: (.assigneeUserIds | map(select(. as $a | $EQ_IDS | index($a)))),
            blocked: ((.tagNames // []) | any(test("(?i)bloque"))),
            staleDays: (if .dateUpdated then days_since(.dateUpdated) else 0 end)
          })
        | map(select((.assigneesEquipo|length) > 0))
      ) as $W
    | ($miembros
        | map(. as $m
            | (.uid) as $u
            | $m + {
                tasks: ($W | map(select(.assigneesEquipo | index($u))) | sort_by(-.staleDays, .name)),
                activos: ($W | map(select(.assigneesEquipo | index($u))) | length),
                stale: ($W | map(select((.assigneesEquipo | index($u)) and .staleDays > 7)) | length),
                blocked: ($W | map(select((.assigneesEquipo | index($u)) and .blocked)) | length)
              })
      ) as $M2
    | "# WIP del equipo — \($fecha)\n",
      "**Generado:** \($gen)\n",
      "## Resumen",
      "| Persona | Activos | Stale >7d | Bloqueados |",
      "|---------|--------:|----------:|-----------:|",
      ($M2[] | "| \(.nombre) | \(.activos) | \(.stale) | \(.blocked) |"),
      "",
      "## Detalle por persona",
      ($M2[]
        | (
            "\n### \(.nombre) — \(.activos) activos (\(.stale) stale, \(.blocked) bloqueados)\n",
            (if .activos == 0 then "_(sin tareas activas)_"
             else (.tasks[] | "- \(if .blocked then "[BLQ] " else "" end)\(if .staleDays > 7 then "[STALE \(.staleDays)d] " else "" end)\(.projectName) #\(.id) — \(.name)\(if .dueDate then " (due \(.dueDate[0:10]))" else "" end)") end)
          )
      )
  ' > "$out_md"

  rm -f "$tmp_wip" "$tmp_eq"
  echo "$out_md"
}

# -- Reporte 3: Mis tickets del día -------------------------------------------
# tw_report_mis_tickets [YYYY-MM-DD]
# Hecho para el responsable (id 677620). Lee de config/equipo.json.responsable.id.
# Buckets:
#   - Vencidos (dueDate < hoy, status != completed)
#   - Due en próximos 3 días
#   - Asignados a mí, abiertos (todos)
#   - Creados por mí, abiertos, asignados a otros
tw_report_mis_tickets() {
  local ref="${1:-$(_tw_hoy)}"
  _tw_load_contexto

  local mi_id
  mi_id=$(jq '.responsable.id' "$TW_REPO_ROOT/config/equipo.json")
  local hoy_iso="$ref"
  local in3="${ref}"  # se calcula abajo

  # +3 días desde ref
  local plus3
  plus3=$(date -d "$ref +3 days" +%Y-%m-%d)

  local mias creadas
  # Filtro estricto client-side: el filtro assignedToUserIds en /tasks.json es
  # laxo (devuelve también unassigned y otros uids). Idem createdByUserIds.
  mias=$(_tw_fetch_tasks_query "assignedToUserIds=${mi_id}&projectIds=${TW_RPT_SCOPE_CSV}&includeCompletedTasks=false&include=tasklists" \
    | jq --argjson u "$mi_id" '[.[] | select(.assigneeUserIds | index($u))]')
  creadas=$(_tw_fetch_tasks_query "createdByUserIds=${mi_id}&projectIds=${TW_RPT_SCOPE_CSV}&includeCompletedTasks=false&include=tasklists" \
    | jq --argjson u "$mi_id" '[.[] | select(.createdByUserId == $u)]')

  local out_dir="$TW_REPO_ROOT/reports/$(_tw_hoy)"
  mkdir -p "$out_dir"
  local out_md="$out_dir/mis-tickets.md"

  local tmp_mias tmp_creadas tmp_eq
  tmp_mias=$(mktemp);    printf '%s' "$mias"    > "$tmp_mias"
  tmp_creadas=$(mktemp); printf '%s' "$creadas" > "$tmp_creadas"
  tmp_eq=$(mktemp);      printf '%s' "$TW_RPT_EQUIPO_NOMBRES" > "$tmp_eq"

  jq -nr \
    --arg fecha "$ref" --arg plus3 "$plus3" --arg gen "$(date '+%Y-%m-%d %H:%M')" --argjson miId "$mi_id" \
    --slurpfile mias "$tmp_mias" \
    --slurpfile creadas "$tmp_creadas" \
    --slurpfile eq "$tmp_eq" '
    def date_only: if . == null then "" else .[0:10] end;
    ($eq[0]) as $EQ
    | ($mias[0]) as $MIAS
    | ($creadas[0]) as $CREADAS
    | ($MIAS | map(select(.dueDate != null and (.dueDate | date_only) < $fecha)) | sort_by(.dueDate)) as $vencidos
    | ($MIAS | map(select(.dueDate != null and (.dueDate | date_only) >= $fecha and (.dueDate | date_only) <= $plus3)) | sort_by(.dueDate)) as $proxs
    | ($CREADAS | map(select(.assigneeUserIds | index($miId) | not)) | sort_by(.dateUpdated) | reverse) as $delegadas
    | ($MIAS | sort_by(.dateUpdated) | reverse) as $todas_mias
    | "# Mis tickets — \($fecha)\n",
      "**Generado:** \($gen) · **Responsable:** id \($miId)\n",
      "## Vencidos (\($vencidos|length))",
      (if ($vencidos|length) == 0 then "_(ninguno)_" else
        "| Proyecto | Ticket | Vence |", "|----------|--------|-------|",
        ($vencidos[] | "| \(.projectName) | #\(.id) — \(.name) | \(.dueDate | date_only) |")
      end),
      "",
      "## Due en próximos 3 días (\($proxs|length))",
      (if ($proxs|length) == 0 then "_(ninguno)_" else
        "| Proyecto | Ticket | Vence |", "|----------|--------|-------|",
        ($proxs[] | "| \(.projectName) | #\(.id) — \(.name) | \(.dueDate | date_only) |")
      end),
      "",
      "## Asignados a mí, abiertos (\($todas_mias|length))",
      (if ($todas_mias|length) == 0 then "_(ninguno)_" else
        "| Proyecto | Ticket | Estado | Últ. act. |", "|----------|--------|--------|-----------|",
        ($todas_mias[] | "| \(.projectName) | #\(.id) — \(.name) | \(.status) | \(.dateUpdated | date_only) |")
      end),
      "",
      "## Creados por mí, abiertos, asignados a otros (\($delegadas|length))",
      (if ($delegadas|length) == 0 then "_(ninguno)_" else
        "| Proyecto | Ticket | Asignado | Estado |", "|----------|--------|----------|--------|",
        ($delegadas[]
          | (.assigneeUserIds[0] // null) as $a
          | "| \(.projectName) | #\(.id) — \(.name) | \(if $a then ($EQ[($a|tostring)] // ("uid " + ($a|tostring))) else "—" end) | \(.status) |")
      end)
  ' > "$out_md"

  rm -f "$tmp_mias" "$tmp_creadas" "$tmp_eq"
  echo "$out_md"
}
