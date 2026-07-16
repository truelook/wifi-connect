#!/usr/bin/env bash

export DBUS_SYSTEM_BUS_ADDRESS=unix:path=/host/run/dbus/system_bus_socket

# Stamp this device's identity into the captive-portal page (issue #6) so a field
# tech can confirm which gateway they're configuring before entering WiFi creds.
# UUID prefix matches the balena dashboard; MAC is the wlan0 (AP) address. The
# binary serves ./ui/index.html, which carries __DEVICE_UUID__/__DEVICE_MAC__
# placeholders; replace them in place (a no-op on restart once substituted).
stamp_portal_identity() {
    local page="./ui/index.html" uuid mac
    [ -f "$page" ] || return 0
    uuid="${BALENA_DEVICE_UUID:0:7}"
    [ -n "$uuid" ] || uuid="unknown"
    mac="$(tr 'a-z' 'A-Z' < /sys/class/net/wlan0/address 2>/dev/null)"
    [ -n "$mac" ] || mac="unknown"
    sed -i "s/__DEVICE_UUID__/${uuid}/g; s/__DEVICE_MAC__/${mac}/g" "$page"
    printf 'Portal identity stamped: %s / %s\n' "$uuid" "$mac"
}
stamp_portal_identity

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
# Interface the portal AP runs on (single-radio Pi: same radio as the STA).
PORTAL_IFACE="${PORTAL_IFACE:-wlan0}"
# WiFi-only-WAN self-heal cadence (seconds). When the portal holds wlan0 and
# there is NO alternate (eth/PAN) uplink, the portal must periodically RELEASE
# the radio so NetworkManager can rejoin the saved WiFi if the WAN came back.
# Without this a site whose only WAN is WiFi (e.g. a Starlink dish shared by a
# few trailers) can NEVER recover once the portal is up: the one radio can't be
# an AP and a station at the same time, and the eth/PAN teardown gate ignores
# WiFi by design. Kept >= PORTAL_MIN_UP so a just-arrived tech is never cut off.
PORTAL_WIFI_RETRY="${PORTAL_WIFI_RETRY:-180}"

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

# Drop a WiFi STA that is holding wlan0 without providing a working uplink so
# the portal AP can claim the radio. Without this, a "connected but no
# internet" profile after a portal submit leaves the box offline with no AP.
clear_dead_wifi_sta() {
    local conn
    conn=$(nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device 2>/dev/null \
        | awk -F: '$1 ~ /^wlan/ && $2 == "wifi" && $3 == "connected" { print $4; exit }')
    if [ -n "$conn" ] && [ "$conn" != "--" ]; then
        printf 'Clearing dead WiFi STA "%s" so portal can claim wlan0.\n' "$conn"
        nmcli connection down "$conn" 2>/dev/null || true
    fi
}

# True while a station is associated to the portal AP — i.e. an operator is
# actively using the captive portal. We defer the WiFi-only self-heal retry
# while this holds so we never yank the AP out from under someone entering
# credentials. Best-effort: if `iw` is missing or errors we return false (favor
# unattended recovery — a stranded, unreachable box is far worse than a portal
# page that briefly re-shows itself).
portal_has_client() {
    command -v iw >/dev/null 2>&1 || return 1
    iw dev "$PORTAL_IFACE" station dump 2>/dev/null | grep -q '^Station'
}

# 1 = last loop iteration ran the portal; skip CONNECT_GRACE and restart ASAP
# if we still have no uplink (covers wifi-connect exiting after a bad submit).
need_portal_soon=0

while true; do
    if [ "$need_portal_soon" -eq 0 ] && wait_for_uplink; then
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
        need_portal_soon=0
    else
        if [ "$need_portal_soon" -eq 1 ]; then
            printf 'Portal session ended without uplink — restarting portal.\n'
            clear_dead_wifi_sta
        else
            printf 'No reachable uplink after %ss. Starting WiFi Connect portal...\n' "$CONNECT_GRACE"
        fi
        # Run the portal in the BACKGROUND and supervise it. wifi-connect itself
        # only exits on submitted creds (or a trapped signal), so WE decide when
        # to relinquish wlan0. Two triggers tear it down, both gated behind
        # PORTAL_MIN_UP so a just-arrived tech is never cut off:
        #   (a) a real ALTERNATE uplink (eth / USB-eth / BT PAN) came up — free
        #       the radio (the AP on wlan0 is the worst case for wifi/BT
        #       coexistence). Requires UPLINK_OK_THRESHOLD consecutive OK probes
        #       so an intermittent route can't tear down HTTP mid-load.
        #   (b) WiFi-only-WAN self-heal — the portal has held the radio past
        #       PORTAL_WIFI_RETRY with NO alternate uplink AND no operator
        #       connected to the AP, so we drop it to let NM rejoin the saved
        #       WiFi (the WAN may have returned). This is the ONLY thing that
        #       recovers a WiFi-only site; without it the box is stuck forever.
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
            # (a) Alternate non-WiFi uplink returned — free wlan0 for coexistence.
            if have_non_wifi_uplink; then
                ok=$((ok + 1))
                printf 'Non-WiFi uplink ok while portal up (%s/%s)\n' "$ok" "$UPLINK_OK_THRESHOLD"
                if [ "$ok" -ge "$UPLINK_OK_THRESHOLD" ]; then
                    printf 'Stable eth/PAN uplink — stopping portal to free wlan0.\n'
                    kill -TERM "$wc_pid" 2>/dev/null
                    break
                fi
                continue
            fi
            ok=0
            # (b) WiFi-only self-heal. No alternate uplink: if nobody is on the
            #     portal, release wlan0 and let NM retry the saved WiFi.
            if [ "$portal_up_for" -ge "$PORTAL_WIFI_RETRY" ]; then
                if portal_has_client; then
                    printf 'Portal client connected — holding AP (deferring WiFi retry).\n'
                    continue
                fi
                printf 'Portal up %ss, no alternate uplink, no client — releasing wlan0 to retry saved WiFi.\n' "$portal_up_for"
                kill -TERM "$wc_pid" 2>/dev/null
                break
            fi
        done
        wait "$wc_pid" 2>/dev/null
        # After ANY portal exit (creds submitted, eth/PAN takeover, or a WiFi
        # self-heal release) give NetworkManager a fair CONNECT_GRACE window to
        # (re)join the saved WiFi / let an eth/PAN route settle BEFORE deciding
        # to re-raise the portal. This single window is what makes a WiFi-only
        # site self-heal instead of instantly re-grabbing the radio and flapping.
        if wait_for_uplink; then
            printf 'Uplink up after portal exit — supervising.\n'
            need_portal_soon=0
        else
            printf 'Still no uplink after portal exit — re-raising portal.\n'
            need_portal_soon=1
        fi
    fi
done
