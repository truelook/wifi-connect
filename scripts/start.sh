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
# Keep the captive portal up at least this long so phones can load the page
# and finish entering credentials before any teardown is even considered.
PORTAL_MIN_UP="${PORTAL_MIN_UP:-180}"
# Consecutive successful non-WiFi uplink probes required before tearing the
# portal down for BT coexistence.
UPLINK_OK_THRESHOLD="${UPLINK_OK_THRESHOLD:-3}"

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

# While the portal owns wlan0, only tear it down for a *real* alternate uplink
# (USB ethernet / onboard eth / BT PAN). A flaky/stale WiFi route + lucky curl
# was killing the AP mid-setup — phone CNA sheet closes, then the outer loop
# brings the portal back a moment later.
have_non_wifi_uplink() {
    # Match common balenaOS / Pi iface names; explicitly exclude wlan*.
    ip route show default 2>/dev/null \
        | grep -E 'dev (eth|enx|enp|eno|ens|pan)[0-9a-z]*' \
        | grep -q '^default' || return 1
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
        # Run the portal in the BACKGROUND and watch for a *stable* uplink. The
        # portal AP on wlan0 (beaconing) is the worst case for Pi wifi/BT
        # coexistence, so once connectivity returns via another path (ethernet,
        # BT PAN) we tear the portal down. wifi-connect itself only exits on
        # submitted creds or ACTIVITY_TIMEOUT.
        #
        # Do NOT kill on the first successful probe: intermittent WAN made that
        # tear down HTTP mid-load and phones show a blank captive-portal page.
        ./wifi-connect &
        wc_pid=$!
        portal_up_for=0
        ok=0
        while kill -0 "$wc_pid" 2>/dev/null; do
            sleep 5
            portal_up_for=$((portal_up_for + 5))
            if [ "$portal_up_for" -lt "$PORTAL_MIN_UP" ]; then
                continue
            fi
            if have_non_wifi_uplink; then
                ok=$((ok + 1))
                printf 'Non-WiFi uplink ok while portal up (%s/%s)\n' "$ok" "$UPLINK_OK_THRESHOLD"
                if [ "$ok" -ge "$UPLINK_OK_THRESHOLD" ]; then
                    printf 'Stable eth/PAN uplink — stopping portal to free wlan0.\n'
                    kill -TERM "$wc_pid" 2>/dev/null
                    break
                fi
            else
                ok=0
            fi
        done
        wait "$wc_pid" 2>/dev/null
    fi
done
