#!/usr/bin/env bash
# Crea los 39 tickets restantes desde /c/tmp/tickets-manifest.json
# Idempotente respecto a task lists: las cachea por nombre.

set -uo pipefail
export USER="${USER:-${USERNAME:-die1fue}}"
source "/c/Net 8/TeamworkTools/lib/tw-client.sh"

PROJECT_ID=1271590
ASSIGNEE_ID=677620
MANIFEST="/c/tmp/tickets-manifest.json"

# Cache de tasklists por nombre. Inicializa con la ya existente.
declare -A TASKLIST_IDS
TASKLIST_IDS["Fundación / Deploy"]=3805565

ensure_tasklist() {
  local name="$1"
  if [[ -n "${TASKLIST_IDS[$name]:-}" ]]; then
    echo "${TASKLIST_IDS[$name]}"
    return
  fi
  local body
  body=$(jq -n --arg n "$name" '{"todo-list":{"name":$n}}')
  local resp tl_id
  resp=$(tw_post_v1 "/projects/$PROJECT_ID/tasklists.json" "$body")
  tl_id=$(echo "$resp" | jq -r '.TASKLISTID // empty')
  if [[ -z "$tl_id" ]]; then
    echo "ERROR creando tasklist '$name': $resp" >&2
    return 1
  fi
  TASKLIST_IDS[$name]="$tl_id"
  echo "$tl_id"
}

# Convierte una fecha YYYYMMDD a YYYY-MM-DD para mostrar en la descripción
fmt_date() {
  local d="$1"
  echo "${d:0:4}-${d:4:2}-${d:6:2}"
}

create_one_ticket() {
  local idx="$1"
  local ticket="$2"

  local tl_name title start due repo summary
  tl_name=$(echo "$ticket" | jq -r '.tasklist')
  title=$(echo "$ticket" | jq -r '.title')
  start=$(echo "$ticket" | jq -r '.start')
  due=$(echo "$ticket" | jq -r '.due')
  repo=$(echo "$ticket" | jq -r '.repo')
  summary=$(echo "$ticket" | jq -r '.summary')

  local tl_id
  tl_id=$(ensure_tasklist "$tl_name") || return 1

  # Construir descripción
  local commits_block
  commits_block=$(echo "$ticket" | jq -r '.commits[] | "• \(.[0]) (\(.[1])) \(.[2])"')

  local desc
  desc=$(printf '%s\n\nRepo: %s\nRango de fechas: %s a %s\n\nCommits:\n%s\n\nEstado en producción: cerrado y desplegado.' \
    "$summary" "$repo" "$(fmt_date "$start")" "$(fmt_date "$due")" "$commits_block")

  # Crear task
  local task_body task_resp task_id
  task_body=$(jq -n \
    --arg t "$title" --arg d "$desc" \
    --arg s "$start" --arg du "$due" \
    --arg a "$ASSIGNEE_ID" '{
      "todo-item": {
        content: $t,
        description: $d,
        "responsible-party-id": $a,
        "start-date": $s,
        "due-date": $du,
        priority: "low"
      }
    }')
  task_resp=$(tw_post_v1 "/tasklists/$tl_id/tasks.json" "$task_body")
  task_id=$(echo "$task_resp" | jq -r '.id // empty')

  if [[ -z "$task_id" ]]; then
    printf '  ✗ [%2d] FAIL: %s | %s\n' "$idx" "$title" "$task_resp" >&2
    return 1
  fi

  # Marcar como completed
  tw_put_v1 "/tasks/$task_id/complete.json" '{}' > /dev/null

  printf '  ✓ [%2d] [tl:%s tk:%s] %s\n' "$idx" "$tl_id" "$task_id" "$title"
}

# Procesar todos los tickets
TOTAL=$(jq '. | length' "$MANIFEST")
echo "=== Creando $TOTAL tickets en proyecto $PROJECT_ID ==="
echo ""

idx=0
created=0
failed=0
while IFS= read -r ticket; do
  idx=$((idx+1))
  if create_one_ticket "$idx" "$ticket"; then
    created=$((created+1))
  else
    failed=$((failed+1))
  fi
done < <(jq -c '.[]' "$MANIFEST")

echo ""
echo "=== Resumen ==="
echo "Creados: $created"
echo "Fallidos: $failed"
echo ""
echo "Task lists usados:"
for k in "${!TASKLIST_IDS[@]}"; do
  printf '  %s → %s\n' "${TASKLIST_IDS[$k]}" "$k"
done | sort
