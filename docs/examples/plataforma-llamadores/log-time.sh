#!/usr/bin/env bash
# Crea 40 time entries con rúbrica conservadora B.
set -uo pipefail
export PATH="/c/Users/die1fue/AppData/Local/Microsoft/WinGet/Links:$PATH"
export USER="${USER:-${USERNAME:-die1fue}}"
source "/c/Net 8/TeamworkTools/lib/tw-client.sh"

PROJECT_ID=1271590
ASSIGNEE_ID=677620

TASK_IDS=(
  47556101 47556289 47556293 47556294 47556295 47556296 47556297 47556300 47556301 47556302
  47556316 47556343 47556360 47556367 47556369 47556370 47556371 47556372 47556374 47556376
  47556378 47556379 47556380 47556381 47556382 47556383 47556384 47556405 47556407 47556408
  47556409 47556410 47556412 47556413 47556414 47556416 47556417 47556418 47556419 47556420
)

T1_TITLE="Setup inicial Video Repository"
T1_START="20260213"
T1_DUE="20260214"
T1_NCOMMITS=6
T1_FIRST_MSG="Initial commit"

get_minutes() {
  local n="$1" first_msg="$2"
  if (( n == 1 )); then
    if [[ "$first_msg" =~ ^fix ]]; then echo 30; else echo 60; fi
  elif (( n <= 3 )); then echo 120
  elif (( n <= 5 )); then echo 180
  elif (( n <= 9 )); then echo 300
  else echo 480
  fi
}

mid_date() {
  local s="$1" d="$2"
  local s_ts d_ts m_ts
  s_ts=$(date -d "${s:0:4}-${s:4:2}-${s:6:2}" +%s)
  d_ts=$(date -d "${d:0:4}-${d:4:2}-${d:6:2}" +%s)
  m_ts=$(( (s_ts + d_ts) / 2 ))
  date -d "@$m_ts" +%Y%m%d
}

log_entry() {
  local task_id="$1" minutes="$2" date="$3" desc="$4"
  local h=$((minutes / 60))
  local m=$((minutes % 60))
  local body
  body=$(jq -n \
    --arg pid "$ASSIGNEE_ID" \
    --arg date "$date" \
    --arg h "$h" --arg m "$m" \
    --arg desc "$desc" '{
      "time-entry": {
        "person-id": $pid,
        date: $date, hours: $h, minutes: $m,
        isbillable: "0", description: $desc
      }
    }')
  tw_post_v1 "/tasks/$task_id/time_entries.json" "$body"
}

process() {
  local idx="$1" task_id="$2" title="$3" start="$4" due="$5" n="$6" first_msg="$7"
  local mins; mins=$(get_minutes "$n" "$first_msg")
  local date; date=$(mid_date "$start" "$due")
  local resp; resp=$(log_entry "$task_id" "$mins" "$date" "Trabajo en: $title")
  local id; id=$(echo "$resp" | jq -r '.timeLogId // empty')
  local h=$((mins/60)) m=$((mins%60))
  if [[ -z "$id" ]]; then
    printf '[T%2d] ✗ FAIL: %s\n' "$idx" "$resp" >&2
  else
    printf '[T%2d] [tk:%s] %dh%02dm en %s (%dc)\n' "$idx" "$task_id" "$h" "$m" "$date" "$n"
  fi
}

process 1 "${TASK_IDS[0]}" "$T1_TITLE" "$T1_START" "$T1_DUE" "$T1_NCOMMITS" "$T1_FIRST_MSG"
i=1
while IFS= read -r ticket; do
  title=$(echo "$ticket" | jq -r '.title')
  start=$(echo "$ticket" | jq -r '.start')
  due=$(echo "$ticket" | jq -r '.due')
  n=$(echo "$ticket" | jq '.commits | length')
  first_msg=$(echo "$ticket" | jq -r '.commits[0][2]')
  process $((i+1)) "${TASK_IDS[$i]}" "$title" "$start" "$due" "$n" "$first_msg"
  i=$((i+1))
done < <(jq -c '.[]' /c/tmp/tickets-manifest.json)

echo ""
echo "=== Verificación ==="
tw_get_v3 "/projects/$PROJECT_ID/time.json?pageSize=200" \
  | jq '{entries: (.timelogs | length), hours: (([.timelogs[].minutes] | add) / 60)}'

echo ""
echo "=== Días con más horas ==="
tw_get_v3 "/projects/$PROJECT_ID/time.json?pageSize=200" \
  | jq -r '.timelogs[] | "\(.timeLogged[0:10])|\(.minutes)"' \
  | awk -F'|' '{sum[$1]+=$2} END {for(d in sum) printf "%s|%.1f\n", d, sum[d]/60}' \
  | sort -t'|' -k2 -rn | head -8 \
  | awk -F'|' '{printf "  %s  %sh\n", $1, $2}'
