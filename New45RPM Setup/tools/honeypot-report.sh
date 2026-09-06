#!/usr/bin/env bash
# honeypot-report.sh — Command-line summary of honeypot activity
#
# Run on the Docker host (if the log volume is mounted there), or inside
# the nginx container:
#   docker compose exec nginx sh /path/to/honeypot-report.sh
#
# Usage:
#   ./honeypot-report.sh              # full report
#   ./honeypot-report.sh --today      # today's hits only
#   ./honeypot-report.sh --tail 50    # show last 50 hits
#   ./honeypot-report.sh --watch      # refresh every 30 s (Ctrl-C to stop)

set -euo pipefail

LOG_FILE="${HONEYPOT_LOG:-/var/log/nginx/honeypot.log}"
BLOCKLIST="${HONEYPOT_BLOCKLIST:-/var/log/nginx/honeypot-blocklist.txt}"
CHART_DAYS=14
TOP_N=10
TAIL_N=25

# ── Colour codes (suppressed when stdout is not a terminal) ──────────────────
if [ -t 1 ]; then
    BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'
    ORANGE=$'\e[38;5;208m'; RED=$'\e[31m'; GREEN=$'\e[32m'; GREY=$'\e[90m'
else
    BOLD=''; DIM=''; RESET=''; ORANGE=''; RED=''; GREEN=''; GREY=''
fi

# ── Argument parsing ─────────────────────────────────────────────────────────
MODE="full"
TAIL_OVERRIDE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --today)  MODE="today";            shift ;;
        --tail)   TAIL_OVERRIDE="${2:-25}"; shift 2 ;;
        --watch)  MODE="watch";            shift ;;
        --log)    LOG_FILE="$2";           shift 2 ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# *//'
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Validate log file ────────────────────────────────────────────────────────
if [[ ! -f "$LOG_FILE" ]]; then
    echo "${RED}Log file not found: $LOG_FILE${RESET}"
    echo "No probes have been logged yet, or set HONEYPOT_LOG to the correct path."
    exit 1
fi

# ── Watch mode: loop ─────────────────────────────────────────────────────────
if [[ "$MODE" == "watch" ]]; then
    while true; do
        clear
        HONEYPOT_LOG="$LOG_FILE" bash "$0" --today
        echo ""
        echo "${GREY}Refreshing every 30 s — Ctrl-C to stop${RESET}"
        sleep 30
    done
    exit 0
fi

# ── Filter to today if requested ─────────────────────────────────────────────
TODAY=$(date -u +"%Y-%m-%d")

if [[ "$MODE" == "today" ]]; then
    WORK_FILE=$(mktemp)
    trap 'rm -f "$WORK_FILE"' EXIT
    grep "^\[$TODAY" "$LOG_FILE" > "$WORK_FILE" || true
    LABEL="Today (${TODAY} UTC)"
else
    WORK_FILE="$LOG_FILE"
    LABEL="All time"
fi

TOTAL=$(wc -l < "$WORK_FILE")
TODAY_COUNT=$(grep -c "^\[$TODAY" "$LOG_FILE" 2>/dev/null || echo 0)

# ── Header ───────────────────────────────────────────────────────────────────
printf '\n%s45RPM Software — Honeypot Activity Report%s\n' "$BOLD" "$RESET"
printf '%sGenerated: %s UTC%s\n' "$GREY" "$(date -u '+%Y-%m-%d %H:%M:%S')" "$RESET"
printf '%sLog: %s%s\n' "$GREY" "$LOG_FILE" "$RESET"
printf '%s\n' "────────────────────────────────────────────────────"

# ── Overview ─────────────────────────────────────────────────────────────────
UNIQUE_IPS=$(awk '{for(i=1;i<=NF;i++) if($i~/^IP=/) print substr($i,4)}' "$WORK_FILE" | sort -u | wc -l)
UNIQUE_PATHS=$(awk '{for(i=1;i<=NF;i++) if($i~/^URI=/) print substr($i,5)}' "$WORK_FILE" | sort -u | wc -l)

BLOCKLIST_COUNT=0
if [[ -f "$BLOCKLIST" ]]; then
    BLOCKLIST_COUNT=$(sort -u "$BLOCKLIST" | grep -c . || true)
fi

printf '\n%sOVERVIEW  [%s]%s\n' "$BOLD" "$LABEL" "$RESET"
printf '  %-30s %s%s%s\n' "Total probes:"    "$ORANGE" "$TOTAL"          "$RESET"
printf '  %-30s %s%s%s\n' "Today (UTC):"     "$ORANGE" "$TODAY_COUNT"    "$RESET"
printf '  %-30s %s\n'     "Unique source IPs:"        "$UNIQUE_IPS"
printf '  %-30s %s\n'     "Distinct probe paths:"     "$UNIQUE_PATHS"
printf '  %-30s %s%s%s\n' "Blocklisted IPs:" \
    "$( [[ $BLOCKLIST_COUNT -gt 0 ]] && echo "$RED" || echo "" )" \
    "$BLOCKLIST_COUNT" "$RESET"

# ── Daily activity chart ─────────────────────────────────────────────────────
printf '\n%sACTIVITY — last %d days%s\n' "$BOLD" "$CHART_DAYS" "$RESET"

# Build daily counts using awk
declare -A daily_counts
for i in $(seq $((CHART_DAYS - 1)) -1 0); do
    day=$(date -u -d "-${i} days" +"%Y-%m-%d" 2>/dev/null \
       || date -u -v"-${i}d"     +"%Y-%m-%d" 2>/dev/null)   # macOS fallback
    daily_counts["$day"]=$(grep -c "^\[$day" "$LOG_FILE" 2>/dev/null || echo 0)
done

# Find max for scaling
max_count=1
for day in "${!daily_counts[@]}"; do
    c=${daily_counts[$day]}
    [[ $c -gt $max_count ]] && max_count=$c
done

# Render 4-row tall ASCII bar chart
BAR_HEIGHT=4
# Block characters: 0, ¼, ½, ¾, full
BLOCKS=(' ' '░' '▒' '▓' '█')

# Build sorted day list
mapfile -t sorted_days < <(for d in "${!daily_counts[@]}"; do echo "$d"; done | sort)

for row in $(seq $BAR_HEIGHT -1 1); do
    printf '  '
    for day in "${sorted_days[@]}"; do
        c=${daily_counts[$day]}
        # Fraction of full height this bar reaches
        # bar_rows = ceil(c / max * BAR_HEIGHT)
        bar_rows=$(( (c * BAR_HEIGHT + max_count - 1) / max_count ))
        if [[ $bar_rows -ge $row ]]; then
            if [[ $c -eq 0 ]]; then
                printf ' '
            else
                printf '%s█%s' "$ORANGE" "$RESET"
            fi
        else
            printf ' '
        fi
        printf ' '
    done
    # Right-side scale label on top row only
    if [[ $row -eq $BAR_HEIGHT ]]; then
        printf '  %s← %d hits (peak)%s' "$GREY" "$max_count" "$RESET"
    fi
    printf '\n'
done

# Date labels (last 2 chars of MM-DD)
printf '  '
for day in "${sorted_days[@]}"; do
    printf '%s ' "${day:8:2}"   # DD portion only
done
printf '\n'

printf '  '
for day in "${sorted_days[@]}"; do
    printf '%s ' "${day:5:2}"   # MM portion only
done
printf '  %s(day/month UTC)%s\n' "$GREY" "$RESET"

# ── Top IPs ──────────────────────────────────────────────────────────────────
printf '\n%sTOP %d SOURCE IPs%s\n' "$BOLD" "$TOP_N" "$RESET"
printf '  %s%-6s  %-18s  %s%s\n' "$GREY" "Hits" "IP" "Status" "$RESET"
printf '  %s\n' "──────  ──────────────────  ──────────"

awk '{for(i=1;i<=NF;i++) if($i~/^IP=/) print substr($i,4)}' "$WORK_FILE" \
  | sort | uniq -c | sort -rn | head -"$TOP_N" \
  | while read -r count ip; do
        blocked=""
        if [[ -f "$BLOCKLIST" ]] && grep -qx "$ip" "$BLOCKLIST" 2>/dev/null; then
            blocked="${RED}[BLOCKED]${RESET}"
        fi
        printf '  %-6s  %-18s  %s\n' "$count" "$ip" "$blocked"
    done

# ── Top probe paths ───────────────────────────────────────────────────────────
printf '\n%sTOP %d PROBE PATHS%s\n' "$BOLD" "$TOP_N" "$RESET"
printf '  %s%-6s  %s%s\n' "$GREY" "Hits" "Path" "$RESET"
printf '  %s\n' "──────  ──────────────────────────────────────────"

awk '{for(i=1;i<=NF;i++) if($i~/^URI=/) print substr($i,5)}' "$WORK_FILE" \
  | sort | uniq -c | sort -rn | head -"$TOP_N" \
  | while read -r count path; do
        printf '  %-6s  %s%s%s\n' "$count" "$RED" "$path" "$RESET"
    done

# ── Top user-agents ───────────────────────────────────────────────────────────
printf '\n%sTOP 8 USER-AGENTS%s\n' "$BOLD" "$RESET"
printf '  %s%-6s  %s%s\n' "$GREY" "Hits" "Agent" "$RESET"
printf '  %s\n' "──────  ──────────────────────────────────────────"

# UA field runs from "UA=" to the next " URI=" — extract with sed
sed -n 's/.*UA=\(.*\) URI=.*/\1/p' "$WORK_FILE" \
  | sort | uniq -c | sort -rn | head -8 \
  | while read -r count ua; do
        # Truncate at 60 chars
        short="${ua:0:60}"
        [[ ${#ua} -gt 60 ]] && short="${short}…"
        printf '  %-6s  %s%s%s\n' "$count" "$GREY" "$short" "$RESET"
    done

# ── Recent hits ───────────────────────────────────────────────────────────────
TAIL_N="${TAIL_OVERRIDE:-$TAIL_N}"
printf '\n%sRECENT %d HITS%s  %s(newest first)%s\n' \
    "$BOLD" "$TAIL_N" "$RESET" "$GREY" "$RESET"
printf '  %s%-21s  %-18s  %s%s\n' "$GREY" "Timestamp (UTC)" "IP" "Path" "$RESET"
printf '  %s\n' "─────────────────────  ──────────────────  ────────────────────────────"

tail -"$TAIL_N" "$WORK_FILE" | tac | while IFS= read -r line; do
    ts=$(  echo "$line" | sed 's/^\[\(.*\)\] IP=.*/\1/')
    ip=$(  echo "$line" | awk '{for(i=1;i<=NF;i++) if($i~/^IP=/)  print substr($i,4)}')
    uri=$( echo "$line" | awk '{for(i=1;i<=NF;i++) if($i~/^URI=/) print substr($i,5)}')
    short_uri="${uri:0:40}"
    [[ ${#uri} -gt 40 ]] && short_uri="${short_uri}…"
    printf '  %-21s  %-18s  %s%s%s\n' "$ts" "$ip" "$RED" "$short_uri" "$RESET"
done

printf '\n'
