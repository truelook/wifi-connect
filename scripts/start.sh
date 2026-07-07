#!/usr/bin/env bash

export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/host/run/dbus/system_bus_socket

# How long (seconds) to wait for a usable uplink before offering the setup
# portal. On reboot NetworkManager needs time to auto-connect saved WiFi / DHCP
# the USB-ethernet. Tunable via env.
CONNECT_GRACE="${CONNECT_GRACE:-60}"
# Poll interval while supervising.
SUPERVISE_INTERVAL="${SUPERVISE_INTERVAL:-30}"
# Consecutive failed probes before we treat the uplink as truly down and raise
# the portal. Hysteresis stops a transient blip from flapping the AP.
FAIL_THRESHOLD="${FAIL_THRESHOLD:-3}"
# Connectivity probe endpoint (balena's returns HTTP 204, same as NM uses).
PROBE_URL="${PROBE_URL:-https://api.balena-cloud.com/connectivity-check}"

# Reachable = we have a default route AND can actually reach the internet.
# The old gate only checked for a default route, so a wrong-password / dead
# uplink that still held a route would suppress the portal forever. We now
# require a real response, so a useless uplink correctly falls through to the
# portal. LAN profile is never-default and the portal AP adds no default route,
# so neither produces a false positive.
have_uplink() {
    ip route show default 2>/dev/null | grep -q '^default' || return 1
    curl -s -o /dev/null --max-time 5 "$PROBE_URL" 2>/dev/null
}

# Return success once uplink is reachable within the grace window.
wait_for_uplink() {
    local waited=0
    while [ "$waited" -lt "$CONNECT_GRACE" ]; do
        if have_uplink; then
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

while true; do
    if wait_for_uplink; then
        printf 'Uplink reachable. Skipping WiFi Connect.\n'
        # Supervise: only re-offer the portal after FAIL_THRESHOLD consecutive
        # failures, so a brief outage doesn't tear down a working setup.
        fails=0
        while [ "$fails" -lt "$FAIL_THRESHOLD" ]; do
            sleep "$SUPERVISE_INTERVAL"
            if have_uplink; then
                fails=0
            else
                fails=$((fails + 1))
                printf 'Uplink probe failed (%s/%s)\n' "$fails" "$FAIL_THRESHOLD"
            fi
        done
        printf 'Uplink lost (%s consecutive failures). Re-evaluating...\n' "$FAIL_THRESHOLD"
    else
        printf 'No reachable uplink after %ss. Starting WiFi Connect portal...\n' "$CONNECT_GRACE"
        # Run the portal in the BACKGROUND and watch for an uplink. The portal AP
        # on wlan0 (beaconing) is the worst case for Pi wifi/BT coexistence, so it
        # MUST NOT keep holding the radio once connectivity returns by any path
        # (e.g. ethernet plugged in, or BT PAN established). wifi-connect itself
        # only exits on submitted creds or ACTIVITY_TIMEOUT, so we kill it the
        # instant an uplink appears; SIGTERM lets it tear its own AP down cleanly.
        ./wifi-connect &
        wc_pid=$!
        while kill -0 "$wc_pid" 2>/dev/null; do
            if have_uplink; then
                printf 'Uplink appeared — stopping portal to free wlan0.\n'
                kill -TERM "$wc_pid" 2>/dev/null
                break
            fi
            sleep 5
        done
        wait "$wc_pid" 2>/dev/null
    fi
done
