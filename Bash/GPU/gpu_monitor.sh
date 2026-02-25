#!/bin/bash
# GPU Monitor — per-node view, instant navigation via cached background fetchers

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

# ── Config ───────────────────────────────────────────────────────────────────
FETCH_INTERVAL=${1:-3}    # seconds between GPU polls per node
DISPLAY_INTERVAL=1        # display refresh rate (seconds, for read_key timeout)
BAR_WIDTH=24
NODE_REFRESH_INTERVAL=30  # seconds between squeue calls

# ── Cache directory (auto-cleaned on exit) ───────────────────────────────────
CACHE_DIR=$(mktemp -d /tmp/gpu_mon_XXXXXX)
declare -A FETCHER_PIDS   # node -> background loop PID

# ── Helpers ──────────────────────────────────────────────────────────────────
get_color() {
    local p=$1
    (( p >= 80 )) && printf '%s' "$RED"  && return
    (( p >= 50 )) && printf '%s' "$YELLOW" && return
    printf '%s' "$GREEN"
}

draw_bar() {
    local pct=$1
    (( pct < 0   )) && pct=0
    (( pct > 100 )) && pct=100
    local filled=$(( pct * BAR_WIDTH / 100 ))
    local empty=$(( BAR_WIDTH - filled ))
    local c; c=$(get_color "$pct")
    printf '%s' "$c"
    (( filled > 0 )) && printf '█%.0s' $(seq 1 "$filled")
    printf '%s' "$RESET$DIM"
    (( empty  > 0 )) && printf '░%.0s' $(seq 1 "$empty")
    printf '%s' "$RESET"
}

trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"; printf '%s' "$v"; }

cache_file() { printf '%s/%s' "$CACHE_DIR" "${1//\//_}"; }
age_file()   { printf '%s/%s.age' "$CACHE_DIR" "${1//\//_}"; }

# ── SLURM helpers ─────────────────────────────────────────────────────────────
expand_nodelist() {
    command -v scontrol &>/dev/null \
        && scontrol show hostnames "$1" 2>/dev/null \
        || echo "$1"
}

get_job_nodes() {
    local raw
    raw=$(squeue --me --noheader --states=R --format="%N" 2>/dev/null)
    [[ -z "$raw" ]] && return
    while IFS= read -r nl; do
        [[ -z "$nl" ]] && continue
        expand_nodelist "$nl"
    done <<< "$raw"
}

# ── Background fetcher (one per node, runs forever until killed) ──────────────
# Writes atomically: query -> .tmp -> mv -> cache file
_node_fetcher_loop() {
    local node=$1
    local cf; cf=$(cache_file "$node")
    local af; af=$(age_file  "$node")
    local tmp="${cf}.tmp"
    while true; do
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
            "$node" \
            "nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu \
             --format=csv,noheader,nounits 2>/dev/null" \
            >"$tmp" 2>/dev/null \
        && mv -f "$tmp" "$cf" \
        && date +%s > "$af"
        sleep "$FETCH_INTERVAL"
    done
}

start_fetcher() {
    local node=$1
    [[ -n "${FETCHER_PIDS[$node]}" ]] && return   # already running
    _node_fetcher_loop "$node" &
    FETCHER_PIDS[$node]=$!
}

stop_all_fetchers() {
    for node in "${!FETCHER_PIDS[@]}"; do
        kill "${FETCHER_PIDS[$node]}" 2>/dev/null
    done
    FETCHER_PIDS=()
}

# ── Node list management ──────────────────────────────────────────────────────
NODES=()
total=0
last_node_refresh=0

refresh_nodes() {
    local new_nodes=()
    mapfile -t new_nodes < <(get_job_nodes)
    last_node_refresh=$(date +%s)
    # Start fetchers for any new nodes
    for n in "${new_nodes[@]}"; do
        start_fetcher "$n"
    done
    NODES=("${new_nodes[@]}")
    total=${#NODES[@]}
    (( total > 0 && cur_idx >= total )) && cur_idx=$(( total - 1 ))
    (( cur_idx < 0 )) && cur_idx=0
}

# ── Rendering ─────────────────────────────────────────────────────────────────
render_gpu_rows() {
    local gpu_data=$1
    if [[ -z "$gpu_data" ]]; then
        printf "  ${DIM}Waiting for first data...${RESET}\n"
        return
    fi
    while IFS=',' read -r idx name util mem_used mem_total temp; do
        idx=$(trim "$idx"); name=$(trim "$name")
        util=$(trim "$util"); mem_used=$(trim "$mem_used")
        mem_total=$(trim "$mem_total"); temp=$(trim "$temp")

        local mem_pct=0
        (( mem_total > 0 )) && mem_pct=$(( mem_used * 100 / mem_total ))
        local uc mc; uc=$(get_color "$util"); mc=$(get_color "$mem_pct")

        printf "  ${BOLD}%3s${RESET}  %-22.22s  ${CYAN}%3s°C${RESET}  " "$idx" "$name" "$temp"
        draw_bar "$util";  printf " ${uc}%3d%%${RESET}  " "$util"
        draw_bar "$mem_pct"; printf " ${mc}%5d${RESET}/${mem_total}\n" "$mem_used"
    done <<< "$gpu_data"
}

render_node() {
    local node=$1 cur=$2 total=$3
    local now; now=$(date '+%H:%M:%S')

    # Read cached data (may be empty on first call)
    local cf; cf=$(cache_file "$node")
    local gpu_data=''
    [[ -f "$cf" ]] && gpu_data=$(cat "$cf")

    # Staleness indicator
    local age_label=''
    local af; af=$(age_file "$node")
    if [[ -f "$af" ]]; then
        local ts now_ts age
        ts=$(cat "$af"); now_ts=$(date +%s); age=$(( now_ts - ts ))
        (( age > FETCH_INTERVAL * 3 )) && age_label="${YELLOW} [stale ${age}s]${RESET}"
    fi

    printf "${BOLD}${CYAN}  %-30s${RESET}${age_label}" "$node"
    printf "  ${DIM}[%d/%d]${RESET}  " "$cur" "$total"
    printf "${DIM}%s  poll:%ss  < prev  next >  q quit${RESET}\n" "$now" "$FETCH_INTERVAL"
    printf "${DIM}%s${RESET}\n" "$(printf '─%.0s' $(seq 1 78))"
    printf "  ${BOLD}%-3s  %-22s  %4s  %-${BAR_WIDTH}s %-4s  %-${BAR_WIDTH}s %-14s${RESET}\n" \
           "GPU" "Name" "Temp" "  GPU Util" "%" "  Memory" "Used/Total MiB"
    render_gpu_rows "$gpu_data"
}

# ── Terminal setup ────────────────────────────────────────────────────────────
cleanup() {
    stop_all_fetchers
    rm -rf "$CACHE_DIR"
    tput cnorm; tput rmcup; stty echo
    exit 0
}
trap cleanup INT TERM EXIT

tput smcup; tput civis; stty -echo

read_key() {
    local k
    IFS= read -r -s -n1 -t "$DISPLAY_INTERVAL" k
    if [[ $k == $'\x1b' ]]; then
        local seq
        IFS= read -r -s -n2 -t 0.1 seq
        k="${k}${seq}"
    fi
    printf '%s' "$k"
}

# ── Main loop ─────────────────────────────────────────────────────────────────
cur_idx=0
refresh_nodes   # initial fetch + start all fetchers

while true; do
    # Periodic node list refresh
    now_ts=$(date +%s)
    if (( now_ts - last_node_refresh >= NODE_REFRESH_INTERVAL )); then
        refresh_nodes
    fi

    # Render current state (reads from cache — always instant)
    if (( total == 0 )); then
        tput cup 0 0
        printf "\n  ${YELLOW}No running SLURM jobs found.${RESET}  (retrying…)\n"
        tput ed
    else
        frame=$(render_node "${NODES[$cur_idx]}" $(( cur_idx + 1 )) "$total")
        tput cup 0 0
        printf '%b' "$frame"
        tput ed
    fi

    key=$(read_key)
    case "$key" in
        $'\x1b[C'|'>'|'.' )   (( total > 0 )) && cur_idx=$(( (cur_idx + 1) % total )) ;;
        $'\x1b[D'|'<'|',' )   (( total > 0 )) && cur_idx=$(( (cur_idx - 1 + total) % total )) ;;
        'q'|'Q' )              cleanup ;;
    esac
done
