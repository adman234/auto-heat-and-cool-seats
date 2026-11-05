#!/bin/bash
# Off-car test of mod/seats.sh with a fake hmgapid and sleep. No mksh on the Mac, so
# it runs under bash; the HMG-API script check covers which commands the unit has.
#   test/run.sh
HERE=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export T PATH="$T/bin:$PATH" HMGAPI_MOD=auto-heat-and-cool-seats UP="$T/uptime"
mkdir "$T/bin"

cat > "$T/bin/hmgapid" <<'EOF'
#!/bin/bash
case "$1" in
setting-get) cat "$T/settings" ;;
vehicle) shift; for n in "$@"; do echo "$n $(cat "$T/r/$n" 2>/dev/null || echo -)"; done ;;
vehicle-do)
    shift; echo "$*" >> "$T/sent"
    if [ -s "$T/refuse" ]; then read -r a < "$T/refuse"; grep -v -x -F "$a" "$T/refuse" > "$T/refuse2"; mv "$T/refuse2" "$T/refuse"; echo "$a"; exit; fi
    [ -f "$T/ignored" ] && { echo "ok"; exit; }
    case "$1:$3" in
    wheel_heat:*) echo 1 > "$T/r/wheel_heat" ;;
    seat_heat:low) echo 6 > "$T/r/seat_state.$2" ;;
    seat_heat:medium) echo 7 > "$T/r/seat_state.$2" ;;
    seat_heat:high) echo 8 > "$T/r/seat_state.$2" ;;
    seat_vent:low) echo 3 > "$T/r/seat_state.$2" ;;
    seat_vent:medium) echo 4 > "$T/r/seat_state.$2" ;;
    seat_vent:high) echo 5 > "$T/r/seat_state.$2" ;;
    esac
    echo "ok" ;;
esac
EOF
# each sleep takes the next hv.ready from seq, after any "up <n>" (/proc/uptime), "moving <n>" or "temp <n>" lines; none left ends the run
cat > "$T/bin/sleep" <<'EOF'
#!/bin/bash
off() { for f in "$T"/r/seat_state.*; do echo 2 > "$f"; done; }   # the car off: seats off
while [ -s "$T/seq" ]; do
    read -r line < "$T/seq"
    tail -n +2 "$T/seq" > "$T/seq2"; mv "$T/seq2" "$T/seq"
    case "$line" in
    "up "*) echo "${line#up } 0" > "$UP"; off ;;
    "moving "*) echo "${line#moving }" > "$T/r/moving" ;;
    "temp "*) echo "${line#temp }" > "$T/r/outside_temp_f" ;;
    0) echo 0 > "$T/r/hv.ready"; off; exit 0 ;;
    *) echo "$line" > "$T/r/hv.ready"; exit 0 ;;
    esac
done
kill "$PPID"
EOF
chmod +x "$T"/bin/*

pass=0; fail=0
scenario() {  # scenario <name> <settings json> <hv.ready sequence, one per line> <expected sends> [setup...]
    local name=$1 settings=$2 seq=$3 want=$4 got; shift 4
    rm -rf "$T/r" "$T/sent" "$T/refuse" "$T/ignored"; mkdir "$T/r"
    echo "$settings" > "$T/settings"; echo "100.00 0" > "$UP"
    for s in driver passenger rear_left rear_right; do echo 2 > "$T/r/seat_state.$s"; done
    echo 0 > "$T/r/wheel_heat"; echo 0 > "$T/r/moving"; echo 0 > "$T/r/hv.ready"
    echo 40 > "$T/r/outside_temp_f"
    for c in "$@"; do eval "$c"; done
    echo "$seq" > "$T/seq"
    bash "$HERE/mod/seats.sh" > "$T/log" 2>&1 &
    wait $! 2>/dev/null
    got=$(cat "$T/sent" 2>/dev/null)
    if [ "$got" = "$want" ]; then pass=$((pass + 1)); echo "ok   $name"
    else fail=$((fail + 1)); echo "FAIL $name"; echo "  want: ${want//$'\n'/ | }"; echo "  got:  ${got//$'\n'/ | }"; cat "$T/log"; fi
}

ON=$'1\n1\n1\n1\n1\n1'
COLD=$'wheel_heat on\nseat_heat driver medium'

scenario "cold: defaults, once per start" '{}' "$ON" "$COLD"
scenario "not READY yet, then READY" '{}' $'0\n0\n1\n1\n1\n1\n1' "$COLD"
scenario "accessory power only: nothing" '{}' $'0\n0\n0' ""
scenario "hot: seat coolers, no wheel" '{}' "$ON" "seat_vent driver medium" 'echo 90 > $T/r/outside_temp_f'
scenario "between the limits: nothing" '{}' "$ON" "" 'echo 62 > $T/r/outside_temp_f'
scenario "exactly on the cold limit: heat" '{}' "$ON" "$COLD" 'echo 50 > $T/r/outside_temp_f'
scenario "exactly on the hot limit: cool" '{}' "$ON" "seat_vent driver medium" 'echo 85 > $T/r/outside_temp_f'
scenario "just over the cold limit: nothing" '{}' "$ON" "" 'echo 50.1 > $T/r/outside_temp_f'
scenario "just under the hot limit: nothing" '{}' "$ON" "" 'echo 84.9 > $T/r/outside_temp_f'
scenario "exactly on a negative limit: heat" '{"cold_below":-10,"wheel":false}' "$ON" "seat_heat driver medium" 'echo -10 > $T/r/outside_temp_f'
scenario "just under a limit (decimal)" '{"wheel":false}' "$ON" "seat_heat driver medium" 'echo 49.9 > $T/r/outside_temp_f'
scenario "service restart mid-drive: nothing" '{}' "$ON" "" 'echo 1 > $T/r/moving' 'echo "500.00 0" > $UP'
scenario "just booted, already moving: still on" '{}' "$ON" "$COLD" 'echo 1 > $T/r/moving'
scenario "seat already on: left alone" '{}' "$ON" "wheel_heat on" 'echo 8 > $T/r/seat_state.driver'
scenario "seat already cooling: left alone" '{"wheel":false}' "$ON" "" 'echo 3 > $T/r/seat_state.driver'
scenario "wheel already on: left alone" '{}' "$ON" "seat_heat driver medium" 'echo 1 > $T/r/wheel_heat'
scenario "chosen seats and levels" '{"wheel":false,"heat_driver":"off","heat_passenger":"high","heat_rear_left":"low","heat_rear_right":"high"}' "$ON" \
    $'seat_heat passenger high\nseat_heat rear_left low\nseat_heat rear_right high'
scenario "wheel only" '{"heat_driver":"off"}' "$ON" "wheel_heat on"
scenario "chosen coolers" '{"cool_driver":"high","cool_passenger":"low"}' "$ON" $'seat_vent driver high\nseat_vent passenger low' 'echo 90 > $T/r/outside_temp_f'
scenario "Celsius limits, spaced JSON" '{"unit": "c", "cold_below": 5, "hot_above": 30, "wheel": false}' "$ON" "seat_heat driver medium" 'echo -3.5 > $T/r/outside_temp'
scenario "negative limit" '{"cold_below":-10,"wheel":false}' "$ON" "" 'echo -3 > $T/r/outside_temp_f'
scenario "under a negative limit" '{"cold_below":-10,"wheel":false}' "$ON" "seat_heat driver medium" 'echo -10.5 > $T/r/outside_temp_f'
scenario "no temperature: nothing" '{}' "$ON" "" 'rm $T/r/outside_temp_f'
scenario "nonsense temperature: nothing" '{}' "$ON" "" 'echo 400 > $T/r/outside_temp_f'
scenario "off, then a new start" '{"wheel":false}' $'1\n1\n1\n0\n0\n0\n0\n0\n1\n1\n1\n1\n1' $'seat_heat driver medium\nseat_heat driver medium'
scenario "off for one read: a new start" '{"wheel":false}' $'1\n1\n1\n0\n1\n1\n1' $'seat_heat driver medium\nseat_heat driver medium'
scenario "stays READY: only once" '{"wheel":false}' "$ON$'\n'$ON" "seat_heat driver medium"
scenario "off while still sending: stops" '{"wheel":false}' $'1\n0\n0\n0' "seat_heat driver medium" 'touch $T/ignored'
scenario "the unit slept: a new start" '{"wheel":false}' $'1\n1\n1\nup 500\n1\n1\n1\n1\n1' $'seat_heat driver medium\nseat_heat driver medium'
scenario "the unit slept, moving at wake: nothing new" '{"wheel":false}' $'1\n1\n1\nmoving 1\nup 500\n1\n1\n1' "seat_heat driver medium"
scenario "temperature comes late: still on" '{"wheel":false}' $'1\n1\n1\n1\n1\n1\n1\n1\n1\n1\ntemp 40\n1\n1\n1' "seat_heat driver medium" 'rm $T/r/outside_temp_f'
scenario "owner refuses: not sent again" '{"wheel":false}' "$ON" "seat_heat driver medium" \
    'echo "refused: the owner did not allow seat_heat" > $T/refuse'
scenario "owner's question up, then allowed" '{"wheel":false}' "$ON" $'seat_heat driver medium\nseat_heat driver medium' \
    'echo "refused: waiting for the owner" > $T/refuse'

# a seat that never shows on: sent every pass, then it gives up
want=$(for i in $(seq 20); do echo "seat_heat driver medium"; done)
scenario "car never shows it: stops after 20" '{"wheel":false}' "$ON$'\n'$ON$'\n'$ON$'\n'$ON" "$want" 'touch $T/ignored'
grep -q "the car didn't show" "$T/log" && echo "ok   ...and says so" || { fail=$((fail + 1)); echo "FAIL no give-up line"; }

echo "$pass passed, $fail failed"
[ $fail = 0 ]
