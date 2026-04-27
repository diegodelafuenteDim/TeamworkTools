#!/usr/bin/env bash
# tw-client.sh — wrapper de la API de Teamwork (Projects v3 + v1).
#
# Uso (sourcing):
#   source "$REPO/lib/tw-client.sh"
#   tw_get_v3 "/projects.json?pageSize=10" | jq .
#
# Variables que requiere:
#   TEAMWORK_API_KEY      (de secrets/teamwork.env)
#   TEAMWORK_BASE_URL     (de secrets/teamwork.env)
#   TW_REPO_ROOT          (raíz del repo, opcional — si no se setea, se infiere)

set -uo pipefail

# -- Resolver raíz del repo si no viene seteada --------------------------------
if [[ -z "${TW_REPO_ROOT:-}" ]]; then
  TW_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# -- Asegurar jq en PATH -------------------------------------------------------
# winget instala jq en ~/AppData/Local/Microsoft/WinGet/Links pero ese path
# no siempre está en PATH del shell del usuario.
_TW_USER="${USER:-${USERNAME:-}}"
if [[ -n "$_TW_USER" ]]; then
  JQ_WINGET="/c/Users/$_TW_USER/AppData/Local/Microsoft/WinGet/Links"
  [[ -d "$JQ_WINGET" ]] && export PATH="$JQ_WINGET:$PATH"
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq no encontrado en PATH. Instalar con: winget install jqlang.jq" >&2
  return 1 2>/dev/null || exit 1
fi

# -- Cargar credenciales -------------------------------------------------------
TW_ENV_FILE="$TW_REPO_ROOT/secrets/teamwork.env"
if [[ ! -f "$TW_ENV_FILE" ]]; then
  echo "ERROR: $TW_ENV_FILE no existe. Copiar de secrets/teamwork.env.example y completar." >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck disable=SC1090
set -a; source "$TW_ENV_FILE"; set +a

: "${TEAMWORK_API_KEY:?TEAMWORK_API_KEY no definida en $TW_ENV_FILE}"
: "${TEAMWORK_BASE_URL:?TEAMWORK_BASE_URL no definida en $TW_ENV_FILE}"

# -- Constantes ----------------------------------------------------------------
TW_AUTH="$TEAMWORK_API_KEY:x"
TW_V3="$TEAMWORK_BASE_URL/projects/api/v3"
TW_V1="$TEAMWORK_BASE_URL"

# -- Funciones públicas --------------------------------------------------------

# tw_get_v3 PATH                  → JSON completo de v3
# tw_get_v1 PATH                  → JSON completo de v1
# tw_get_v3_all_pages PATH KEY    → concatena todas las páginas, devuelve {KEY: [...combinados]}
# tw_post_v1 PATH BODY            → POST a v1
# tw_put_v1 PATH BODY             → PUT a v1
# tw_put_v3 PATH BODY             → PUT a v3
# tw_archive_project PROJECT_ID   → archiva un proyecto
# tw_set_project_category PID CID → asigna categoría a un proyecto
# tw_clean_json INPUT_FILE        → quita la clave duplicada que rompe parsers estrictos

tw_get_v3() {
  local path="$1"
  curl -s -u "$TW_AUTH" "$TW_V3$path" -H "Accept: application/json"
}

tw_get_v1() {
  local path="$1"
  curl -s -u "$TW_AUTH" "$TW_V1$path" -H "Accept: application/json"
}

tw_post_v1() {
  local path="$1" body="$2"
  curl -s -u "$TW_AUTH" -X POST "$TW_V1$path" \
    -H "Content-Type: application/json" \
    -d "$body"
}

tw_put_v1() {
  local path="$1" body="$2"
  curl -s -u "$TW_AUTH" -X PUT "$TW_V1$path" \
    -H "Content-Type: application/json" \
    -d "$body"
}

tw_put_v3() {
  local path="$1" body="$2"
  curl -s -u "$TW_AUTH" -X PUT "$TW_V3$path" \
    -H "Content-Type: application/json" \
    -d "$body"
}

# Pagina sobre /v3 hasta agotar y concatena las entradas de la clave indicada.
# Útil para listas grandes (tasks, time entries) que pasan los 200 items por página.
# Uso: tw_get_v3_all_pages "/tasks.json?assignedToUserIds=677620" "tasks"
tw_get_v3_all_pages() {
  local path="$1" key="$2"
  local sep="?"; [[ "$path" == *"?"* ]] && sep="&"
  local page=1 size=100 acc='[]' resp items hasMore
  while :; do
    resp=$(tw_get_v3 "${path}${sep}page=${page}&pageSize=${size}")
    items=$(echo "$resp" | jq ".${key} // []")
    acc=$(jq -n --argjson a "$acc" --argjson b "$items" '$a + $b')
    hasMore=$(echo "$resp" | jq -r '.meta.page.hasMore // false')
    [[ "$hasMore" != "true" ]] && break
    page=$((page+1))
  done
  jq -n --arg key "$key" --argjson items "$acc" '{($key): $items, total: ($items|length)}'
}

# Archiva un proyecto. Requiere body {"status":"inactive"} (no "archive").
tw_archive_project() {
  local pid="$1"
  tw_put_v1 "/projects/$pid/archive.json" '{"status":"inactive"}'
}

# Restaura un proyecto archivado.
tw_unarchive_project() {
  local pid="$1"
  tw_put_v1 "/projects/$pid/archive.json" '{"status":"active"}'
}

# Asigna categoría a un proyecto. Usa v1 con campo categoryId (alfanumérico, sin guión).
tw_set_project_category() {
  local pid="$1" cid="$2"
  tw_put_v1 "/projects/$pid.json" "{\"project\":{\"categoryId\":$cid}}"
}

# Crea una nueva categoría de proyecto y devuelve el ID.
tw_create_category() {
  local name="$1"
  local resp
  resp=$(tw_post_v1 "/projectCategories.json" "{\"category\":{\"name\":\"$name\"}}")
  echo "$resp" | jq -r '.id // .categoryId // empty'
}

# Lista todas las categorías de proyecto (endpoint v1, único disponible).
tw_list_categories() {
  tw_get_v1 "/projectCategories.json" | jq '[.categories[] | {id: (.id|tonumber), name}]'
}

# Resuelve scope IT (proyectos a monitorear) según config/proyectos-it.json.
# Devuelve un array JSON de IDs de proyecto activos que están dentro del scope.
tw_get_scope_proyectos_it() {
  local cfg="$TW_REPO_ROOT/config/proyectos-it.json"
  [[ ! -f "$cfg" ]] && { echo "ERROR: $cfg no existe" >&2; return 1; }

  local cats_in cats_out forced_in forced_out
  cats_in=$(jq '[.categoriasIncluidas[].id]' "$cfg")
  cats_out=$(jq '[.categoriasExcluidas[].id]' "$cfg")
  forced_in=$(jq '[.proyectosIncluirSiempre[].id]' "$cfg")
  forced_out=$(jq '[.proyectosExcluirSiempre[].id]' "$cfg")

  # Traer todos los proyectos activos y filtrar
  tw_get_v3 "/projects.json?pageSize=200" \
    | jq --argjson catsIn "$cats_in" \
         --argjson catsOut "$cats_out" \
         --argjson forcedIn "$forced_in" \
         --argjson forcedOut "$forced_out" '
      [
        .projects[]
        | select(.status == "active")
        | select(
            (.id as $pid | $forcedIn | index($pid))
            or (
              ((.category.id // null) as $cid | $catsIn | index($cid))
              and ((.category.id // null) as $cid | ($catsOut | index($cid)) | not)
            )
          )
        | select(.id as $pid | ($forcedOut | index($pid)) | not)
        | {id, name, categoryId: (.category.id // null)}
      ] | sort_by(.name)
    '
}

# Lista los IDs del equipo según config/equipo.json
tw_get_equipo_ids() {
  local cfg="$TW_REPO_ROOT/config/equipo.json"
  [[ ! -f "$cfg" ]] && { echo "ERROR: $cfg no existe" >&2; return 1; }
  jq '[.equipo[].id]' "$cfg"
}

# Lista los IDs del equipo en formato CSV (para parámetros de query)
tw_get_equipo_ids_csv() {
  local cfg="$TW_REPO_ROOT/config/equipo.json"
  [[ ! -f "$cfg" ]] && { echo "ERROR: $cfg no existe" >&2; return 1; }
  jq -r '[.equipo[].id] | join(",")' "$cfg"
}

# Resuelve nombre del miembro del equipo dado un userId.
tw_nombre_equipo() {
  local uid="$1"
  local cfg="$TW_REPO_ROOT/config/equipo.json"
  jq -r --argjson uid "$uid" '.equipo[] | select(.id == $uid) | .nombre' "$cfg"
}

# -- Marca el módulo como cargado ---------------------------------------------
TW_CLIENT_LOADED=1
