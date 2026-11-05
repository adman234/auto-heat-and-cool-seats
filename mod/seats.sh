#!/system/bin/sh
# Auto Heat and Cool Seats: on each car start, turns on the seat heaters and wheel heat when
# it's cold outside, or the seat coolers when it's hot. Idea from eclipseempire's
# Cold-start Heat; here the readings and commands are HMG-API's (hmgapid vehicle,
# hmgapid vehicle-do), so there are no service numbers or logcat parsing.
#
# A start is hv.ready turning 1. The service also sees that when the head unit boots
# after the car is READY, and after the unit has slept (a jump in /proc/uptime).
#
# Usage: seats.sh               run as the mod's service
#        seats.sh check [temp]  print what it would do now, or at temp; sends nothing
#
# mksh only: the head unit has no sed, cut or expr.

MOD=auto-heat-and-cool-seats
START="hv.ready moving outside_temp outside_temp_f"
UP=${UP:-/proc/uptime}

log() { echo "$(date '+%m-%d %H:%M:%S') $*"; }

snapshot() {  # snapshot <name>...: into SNAP, as name=value words
    # hmgapid answers at once, then waits 3 s for a close that doesn't come, holding one of
    # its 8 workers. So: one call for all the names, in the background, taking just the lines.
    local n=$#
    SNAP=$({ hmgapid vehicle "$@" 2>/dev/null & } | {
        while [ $n -gt 0 ] && read a b; do echo "$a=$b"; n=$(( n - 1 )); done
    })
}

seen() {      # seen <name>: its value in SNAP, or -
    local w
    for w in $SNAP; do
        if [ "${w%%=*}" = "$1" ] && [ -n "${w#*=}" ]; then echo "${w#*=}"; return; fi
    done
    echo -
}

load_settings() {
    if [ -n "$HMGAPI_MOD" ]; then S=$(hmgapid setting-get); else S=$(hmgapid setting-get $MOD); fi
}

setting() {   # setting <key> <default>, from settings JSON like {"unit":"c","wheel":false}
    local v
    v=${S#*\"$1\":}
    [ "$v" = "$S" ] && { echo "$2"; return; }
    v=${v# }; v=${v#\"}; v=${v%%[\",\}]*}
    echo "${v:-$2}"
}

limit() {     # limit <key> <default>: a whole-degree setting, in tenths
    tenths "$(setting $1 $2)" || tenths $2
}

tenths() {    # tenths <reading>: 73 -> 730, -3.5 -> -35; fails on anything else
    local v=$1 s=1 w f
    case "$v" in -*) s=-1; v=${v#-} ;; esac
    case "$v" in *.*) w=${v%%.*}; f=${v#*.} ;; *) w=$v; f=0 ;; esac
    [ -n "$w" ] && [ -n "$f" ] || return 1
    case "$w$f" in *[!0-9]*) return 1 ;; esac
    f=${f%"${f#?}"}
    echo $(( s * (10#$w * 10 + 10#$f) ))
}

outside() {   # the outside temperature in tenths of the settings' unit; fails if there's none yet
    local t
    if [ "$unit" = c ]; then t=$(tenths "$(seen outside_temp)") || return 1
    else t=$(tenths "$(seen outside_temp_f)") || return 1
    fi
    if [ "$unit" = c ]; then [ $t -ge -500 ] && [ $t -le 600 ] || return 1
    else [ $t -ge -580 ] && [ $t -le 1400 ] || return 1
    fi
    echo $t
}

deg() {       # deg <tenths>: for the log
    local a=$1 s=
    [ $a -lt 0 ] && { s=-; a=$(( -a )); }
    echo "$s$(( a / 10 )).$(( a % 10 )) $unit"
}

jobs_for() {  # jobs_for <temp in tenths>: what this temperature asks for, or nothing
    local s l j=
    if [ $1 -le $(limit cold_below 50) ]; then
        [ "$(setting wheel true)" = true ] && j=wheel_heat
        for s in driver passenger rear_left rear_right; do
            case $s in driver) l=$(setting heat_$s medium) ;; *) l=$(setting heat_$s off) ;; esac
            [ "$l" = off ] || j="$j seat_heat:$s:$l"
        done
    elif [ $1 -ge $(limit hot_above 85) ]; then
        for s in driver passenger; do
            case $s in driver) l=$(setting cool_$s medium) ;; *) l=$(setting cool_$s off) ;; esac
            [ "$l" = off ] || j="$j seat_vent:$s:$l"
        done
    fi
    echo $j
}

result() {    # result <what> <answer> <state before>: 0 when it's done with, 1 to look again
    case "$2" in
    "refused: waiting"*) return 1 ;;   # the owner's question is on the screen
    refused*) log "$1: $2"; return 0 ;;
    ok*) ;;
    *) return 1 ;;                     # no answer from the vehicle service
    esac
    # it was off (0 and 15: not reported yet): the next pass shows if it took
    [ "$3" = 0 ] || [ "$3" = 2 ] || [ "$3" = 15 ] && return 1
    return 0
}

send() {      # send <job>: wheel_heat or seat_heat:driver:low
    local cmd=${1%%:*} rest=${1#*:} seat state
    if [ "$cmd" = wheel_heat ]; then
        state=$(seen wheel_heat)
        [ "$state" = 1 ] && { log "wheel heat is on"; return 0; }
        result "wheel heat" "$(hmgapid vehicle-do wheel_heat on 2>&1)" "$state"
        return
    fi
    seat=${rest%:*}
    state=$(seen seat_state.$seat)
    if [ "$state" != - ] && [ "$state" -ge 3 ] && [ "$state" -le 8 ]; then
        log "$seat seat is at step $state"   # the driver's or ours
        return 0
    fi
    result "$seat seat" "$(hmgapid vehicle-do $cmd $seat ${rest#*:} 2>&1)" "$state"
}

apply() {     # apply <jobs>: send each, again until the car shows it (a minute at most)
    local jobs=$1 left j n=0
    while [ -n "$jobs" ] && [ $n -lt 20 ]; do
        snapshot hv.ready wheel_heat seat_state.driver seat_state.passenger seat_state.rear_left seat_state.rear_right
        [ "$(seen hv.ready)" = 0 ] && return
        left=
        for j in $jobs; do
            send $j || left="$left $j"
        done
        jobs=$left
        n=$(( n + 1 ))
        [ -n "$jobs" ] && sleep 3
    done
    [ -z "$jobs" ] || log "the car didn't show:$jobs"
}

on_start() {  # SNAP holds START's readings
    local t waited= jobs
    # a service restart mid-drive isn't a start; right after the unit boots it may be one
    if [ "$(seen moving)" = 1 ] && [ "$(uptime_s)" -ge 180 ]; then
        log "READY but already moving (the service restarted), no action"
        return
    fi
    load_settings
    unit=$(setting unit f)
    until t=$(outside); do
        [ "$(seen hv.ready)" = 0 ] && { log "the car went off, no action"; return; }
        [ -n "$waited" ] || { log "waiting for an outside temperature"; waited=1; }
        sleep 3
        snapshot $START
    done
    jobs=$(jobs_for $t)
    log "outside $(deg $t), limits $(deg $(limit cold_below 50)) and $(deg $(limit hot_above 85)): ${jobs:-no action}"
    apply "$jobs"
}

uptime_s() { local u x; read u x < "$UP"; echo "${u%.*}"; }

if [ "$1" = check ]; then
    load_settings
    unit=$(setting unit f)
    snapshot $START
    if [ -n "$2" ]; then t=$(tenths "$2"); else t=$(outside); fi || { echo "no outside temperature"; exit 1; }
    echo "hv.ready $(seen hv.ready), moving $(seen moving), outside $(deg $t)"
    echo "limits $(deg $(limit cold_below 50)) and $(deg $(limit hot_above 85))"
    echo "would send: $(jobs_for $t)"
    exit 0
fi

log "started"
armed=1; last=$(uptime_s)
while :; do
    now=$(uptime_s)
    [ $(( now - last )) -gt 20 ] && armed=1   # the unit slept: this is a new start
    last=$now
    snapshot $START
    ready=$(seen hv.ready)
    if [ "$ready" = 1 ]; then
        if [ $armed = 1 ]; then
            armed=0
            on_start
            last=$(uptime_s)
        fi
    elif [ "$ready" != - ]; then
        armed=1                        # any read of off: the next READY is a new start
    fi
    sleep 3
done
