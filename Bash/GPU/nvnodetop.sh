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

# Populates parallel arrays: JOB_IDS, JOB_NAMES, JOB_NODES (space-sep node list per job)
declare -a  JOB_IDS=()
declare -A  JOB_NAMES=()   # job_id -> name
declare -A  JOB_NODES=()   # job_id -> newline-sep expanded node list
declare -A  JOB_NODE_IDX=() # job_id -> current node cursor

refresh_jobs() {
    local raw
    # Format: "JOBID NAME NODELIST"
    raw=$(squeue --me --noheader --states=R --format="%i %j %N" 2>/dev/null)
    [[ -z "$raw" ]] && { JOB_IDS=(); last_node_refresh=$(date +%s); return; }

    local new_ids=()
    declare -A new_names new_nodes

    while read -r jid jname nl; do
        [[ -z "$jid" ]] && continue
        local expanded; expanded=$(expand_nodelist "$nl")
        new_ids+=("$jid")
        new_names[$jid]="$jname"
        new_nodes[$jid]="$expanded"
        # Start fetchers for each node in this job
        while IFS= read -r n; do
            [[ -n "$n" ]] && start_fetcher "$n"
        done <<< "$expanded"
        # Preserve existing node cursor for this job
        [[ -z "${JOB_NODE_IDX[$jid]+x}" ]] && JOB_NODE_IDX[$jid]=0
    done <<< "$raw"

    JOB_IDS=("${new_ids[@]}")
    for k in "${!new_names[@]}"; do JOB_NAMES[$k]="${new_names[$k]}"; done
    for k in "${!new_nodes[@]}"; do JOB_NODES[$k]="${new_nodes[$k]}"; done
    last_node_refresh=$(date +%s)

    # Clamp job cursor
    local njobs=${#JOB_IDS[@]}
    (( njobs > 0 && job_idx >= njobs )) && job_idx=$(( njobs - 1 ))
    (( job_idx < 0 )) && job_idx=0
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
last_node_refresh=0

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
    local node=$1 node_cur=$2 node_total=$3 job_cur=$4 job_total=$5 jid=$6 jname=$7
    local now; now=$(date '+%H:%M:%S')

    # Read cached data
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

    # Line 1: job info
    printf "${DIM}  Job ${RESET}${BOLD}%-8s${RESET}${DIM} %-20s${RESET}" "$jid" "$jname"
    printf "  ${DIM}job %d/%d  ↑↓ switch job${RESET}\n" "$job_cur" "$job_total"
    # Line 2: node info
    printf "${BOLD}${CYAN}  %-30s${RESET}${age_label}"
    printf "  ${DIM}node [%d/%d]${RESET}  " "$node_cur" "$node_total"
    printf "${DIM}%s  poll:%ss  < prev node  next node >  q quit${RESET}\n" "$now" "$FETCH_INTERVAL"
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
job_idx=0
refresh_jobs   # initial fetch + start all fetchers

while true; do
    # Periodic refresh
    now_ts=$(date +%s)
    if (( now_ts - last_node_refresh >= NODE_REFRESH_INTERVAL )); then
        refresh_jobs
    fi

    njobs=${#JOB_IDS[@]}

    if (( njobs == 0 )); then
        tput cup 0 0
        printf "\n  ${YELLOW}No running SLURM jobs found.${RESET}  (retrying…)\n"
        tput ed
    else
        (( job_idx >= njobs )) && job_idx=$(( njobs - 1 ))
        jid="${JOB_IDS[$job_idx]}"
        jname="${JOB_NAMES[$jid]}"

        # Build node list for current job, filter blanks
        mapfile -t cur_nodes <<< "${JOB_NODES[$jid]}"
        cur_nodes=($(printf '%s\n' "${cur_nodes[@]}" | grep -v '^[[:space:]]*$'))
        ncount=${#cur_nodes[@]}

        # Clamp node cursor for this job
        nidx=${JOB_NODE_IDX[$jid]:-0}
        (( nidx >= ncount )) && nidx=$(( ncount - 1 ))
        (( nidx < 0 )) && nidx=0
        JOB_NODE_IDX[$jid]=$nidx

        node="${cur_nodes[$nidx]}"
        frame=$(render_node "$node" $(( nidx+1 )) "$ncount" $(( job_idx+1 )) "$njobs" "$jid" "$jname")
        tput cup 0 0
        printf '%b' "$frame"
        tput ed
    fi

    key=$(read_key)
    case "$key" in
        $'\x1b[C'|'>'|'.' )   # → next node
            if (( njobs > 0 )); then
                jid="${JOB_IDS[$job_idx]}"
                mapfile -t _nn <<< "${JOB_NODES[$jid]}"
                _nn=($(printf '%s\n' "${_nn[@]}" | grep -v '^[[:space:]]*$'))
                nc=${#_nn[@]}
                JOB_NODE_IDX[$jid]=$(( (${JOB_NODE_IDX[$jid]:-0} + 1) % nc ))
            fi ;;
        $'\x1b[D'|'<'|',' )   # ← prev node
            if (( njobs > 0 )); then
                jid="${JOB_IDS[$job_idx]}"
                mapfile -t _nn <<< "${JOB_NODES[$jid]}"
                _nn=($(printf '%s\n' "${_nn[@]}" | grep -v '^[[:space:]]*$'))
                nc=${#_nn[@]}
                JOB_NODE_IDX[$jid]=$(( (${JOB_NODE_IDX[$jid]:-0} - 1 + nc) % nc ))
            fi ;;
        $'\x1b[A'|'k'|'K' )   # ↑ prev job
            (( njobs > 0 )) && job_idx=$(( (job_idx - 1 + njobs) % njobs )) ;;
        $'\x1b[B'|'j'|'J' )   # ↓ next job
            (( njobs > 0 )) && job_idx=$(( (job_idx + 1) % njobs )) ;;
        'q'|'Q' )
            cleanup ;;
    esac
done
