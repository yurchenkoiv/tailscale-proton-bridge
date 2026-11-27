# Sourced by multi-entrypoint.sh after profile discovery.
SITE_ROUTE_MASK=0xffff0000
SITE_INGRESS_MASK=0x0000ffff
SITE_ROUTE_PRIORITY=890
SITE_ROUTE_CHAIN=BRIDGE-WEBSITE
SITE_DIRECT_ID=_direct
declare -A SITE_MARKS SITE_DOMAINS
SITE_ROUTING_ACTIVE=0
SITE_CONFLICTS_JSON='[]'

site_install_table() {
    local index="$1" mark="$2" table
    table=$(( 52000 + index ))
    while ip -4 rule del pref "$SITE_ROUTE_PRIORITY" fwmark "$mark/$SITE_ROUTE_MASK" lookup "$table" 2>/dev/null; do
        :
    done
    ip -4 route flush table "$table" 2>/dev/null || true
    ip -4 route replace blackhole default metric 32767 table "$table" &&
        ip -4 rule add pref "$SITE_ROUTE_PRIORITY" fwmark "$mark/$SITE_ROUTE_MASK" lookup "$table"
}

init_website_routing() {
    local default="${VPN_ROUTING_DEFAULT:-}"
    [ -n "$default" ] || return 0

    local i id entry domain target normalized gateway_route
    local -a rules=()
    for ((i = 0; i < PROFILE_COUNT; i++)); do
        if [ "${PROFILE_TYPES[$i]}" = wireguard ]; then
            SITE_MARKS["${PROFILE_IDS[$i]}"]=$(( (i + 1) << 16 ))
        fi
    done
    if [[ ! "$default" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || [ -z "${SITE_MARKS[$default]:-}" ]; then
        echo "VPN_ROUTING_DEFAULT must name a configured WireGuard profile" >&2
        return 1
    fi
    SITE_DEFAULT_MARK="${SITE_MARKS[$default]}"
    SITE_MARKS[$SITE_DIRECT_ID]=$(( (PROFILE_COUNT + 1) << 16 ))

    # Legacy exclusions become Direct rules while website routing is enabled.
    if [ -n "${VPN_BYPASS_DOMAINS:-}" ]; then
        normalized=$(normalize_bypass_domains "$VPN_BYPASS_DOMAINS") || return 1
        for domain in $normalized; do
            SITE_DOMAINS["$domain"]="$SITE_DIRECT_ID"
        done
    fi
    if [ -n "${VPN_ROUTING_RULES:-}" ]; then
        IFS=, read -r -a rules <<< "$VPN_ROUTING_RULES"
    fi
    if [ "${#rules[@]}" -gt 20 ]; then
        echo "VPN_ROUTING_RULES supports up to 20 hostnames" >&2
        return 1
    fi
    for entry in "${rules[@]}"; do
        domain=${entry%@*}
        target=${entry##*@}
        if [[ "$entry" != *@* || ! "$target" =~ ^(_direct|[a-z0-9][a-z0-9-]{0,31})$ ]] ||
           [ -z "${SITE_MARKS[$target]:-}" ] ||
           ! normalized=$(normalize_bypass_domains "$domain") ||
           [ "$normalized" != "$domain" ]; then
            echo "Invalid website routing rule. Use hostname@profile-id or hostname@_direct." >&2
            return 1
        fi
        if [ -n "${SITE_DOMAINS[$domain]:-}" ] && [ "${SITE_DOMAINS[$domain]}" != "$target" ]; then
            echo "Conflicting website routing rules for $domain" >&2
            return 1
        fi
        SITE_DOMAINS["$domain"]="$target"
    done

    if ! iptables -t mangle -N "$SITE_ROUTE_CHAIN"; then
        iptables -t mangle -F "$SITE_ROUTE_CHAIN" || return 1
    fi
    for ((i = 0; i < PROFILE_COUNT; i++)); do
        id="${PROFILE_IDS[$i]}"
        [ "${PROFILE_TYPES[$i]}" = wireguard ] || continue
        site_install_table "$i" "${SITE_MARKS[$id]}" || return 1
        iptables -t nat -A POSTROUTING -o "${VPN_INTERFACES[$i]}" -j MASQUERADE || return 1
    done
    for target in "${SITE_DOMAINS[@]}"; do
        [ "$target" = "$SITE_DIRECT_ID" ] || continue
        gateway_route=$(ip -4 route show default | awk '$1 == "default" && $2 == "via" {print $3, $5; exit}')
        read -r SITE_DIRECT_GATEWAY SITE_DIRECT_DEVICE <<< "$gateway_route"
        if [ -z "$SITE_DIRECT_GATEWAY" ] || [ -z "$SITE_DIRECT_DEVICE" ]; then
            echo "Website routing: Direct rules require an IPv4 default gateway" >&2
            return 1
        fi
        site_install_table "$PROFILE_COUNT" "${SITE_MARKS[$SITE_DIRECT_ID]}" &&
            ip -4 route replace default via "$SITE_DIRECT_GATEWAY" dev "$SITE_DIRECT_DEVICE" \
                onlink metric 10 table "$(( 52000 + PROFILE_COUNT ))" &&
            iptables -t nat -A POSTROUTING -o "$SITE_DIRECT_DEVICE" -m mark \
                --mark "${SITE_MARKS[$SITE_DIRECT_ID]}/$SITE_ROUTE_MASK" -j MASQUERADE || return 1
        break
    done
    SITE_ROUTING_ACTIVE=1
}

# Keep a terminal fallback in every policy table even when its device vanishes.
set_website_tunnel_state() {
    local index="$1" state="$2" table vpn_if
    [ "$SITE_ROUTING_ACTIVE" = 1 ] && [ "${PROFILE_TYPES[$index]}" = wireguard ] || return 0
    table=$(( 52000 + index ))
    vpn_if="${VPN_INTERFACES[$index]}"
    if [ "$state" = connected ]; then
        ip -4 route replace default dev "$vpn_if" metric 10 table "$table"
    else
        local route
        route=$(ip -4 route show table "$table" default) || return 1
        route=$(printf '%s\n' "$route" | awk -v dev="$vpn_if" '
            { for (i = 1; i < NF; i++) if ($i == "dev" && $(i + 1) == dev) print }
        ')
        if [ -n "$route" ]; then
            ip -4 route del default dev "$vpn_if" metric 10 table "$table" || return 1
        fi
    fi
}

configure_website_ingress() {
    local ts_if="$1" ingress_mark="$2" i id vpn_if
    iptables -t mangle -A PREROUTING -i "$ts_if" -m conntrack --ctstate NEW \
        -j CONNMARK --set-xmark "$ingress_mark/$SITE_INGRESS_MASK" &&
        iptables -t mangle -A PREROUTING -i "$ts_if" -j "$SITE_ROUTE_CHAIN" || return 1

    for ((i = 0; i < PROFILE_COUNT; i++)); do
        id="${PROFILE_IDS[$i]}"
        [ "${PROFILE_TYPES[$i]}" = wireguard ] || continue
        vpn_if="${VPN_INTERFACES[$i]}"
        iptables -A FORWARD -i "$ts_if" -o "$vpn_if" -m mark \
            --mark "${SITE_MARKS[$id]}/$SITE_ROUTE_MASK" -j ACCEPT &&
            iptables -A FORWARD -i "$vpn_if" -o "$ts_if" -m mark \
                --mark "$ingress_mark/$SITE_INGRESS_MASK" -m conntrack \
                --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT || return 1
    done
    if [ -n "${SITE_DIRECT_DEVICE:-}" ]; then
        iptables -A FORWARD -i "$ts_if" -o "$SITE_DIRECT_DEVICE" -m mark \
            --mark "${SITE_MARKS[$SITE_DIRECT_ID]}/$SITE_ROUTE_MASK" -j ACCEPT &&
            iptables -A FORWARD -i "$SITE_DIRECT_DEVICE" -o "$ts_if" -m mark \
                --mark "$ingress_mark/$SITE_INGRESS_MASK" -m conntrack \
                --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT || return 1
    fi
}

refresh_website_routing() {
    [ "$SITE_ROUTING_ACTIVE" = 1 ] || return 0
    local now domain target address answers mark conflicts=""
    local -A destinations=()
    read -r now _ < /proc/uptime || return 1
    now=${now%%.*}
    [ "$now" -ge "${SITE_REFRESH_AT:-0}" ] || return 0

    for domain in "${!SITE_DOMAINS[@]}"; do
        target="${SITE_DOMAINS[$domain]}"
        mark="${SITE_MARKS[$target]}"
        answers=$(resolve_public_ipv4 "$domain")
        for address in $answers; do
            if [ -z "${destinations[$address]:-}" ]; then
                destinations["$address"]="$mark"
            elif [ "${destinations[$address]}" != "$mark" ]; then
                destinations["$address"]=conflict
            fi
        done
    done

    # Replace the classifier atomically. Existing connections retain their
    # original route so NAT stays bound to the interface that opened the flow.
    {
        printf '*mangle\n-F %s\n' "$SITE_ROUTE_CHAIN"
        printf -- '-A %s -d 100.64.0.0/10 -j RETURN\n' "$SITE_ROUTE_CHAIN"
        printf -- '-A %s -j CONNMARK --restore-mark --nfmask %s --ctmask %s\n' \
            "$SITE_ROUTE_CHAIN" "$SITE_ROUTE_MASK" "$SITE_ROUTE_MASK"
        printf -- '-A %s -m mark ! --mark 0/%s -j RETURN\n' "$SITE_ROUTE_CHAIN" "$SITE_ROUTE_MASK"
        for address in "${!destinations[@]}"; do
            mark="${destinations[$address]}"
            [ "$mark" != conflict ] || continue
            printf -- '-A %s -d %s/32 -j MARK --set-xmark %s/%s\n' \
                "$SITE_ROUTE_CHAIN" "$address" "$mark" "$SITE_ROUTE_MASK"
        done
        printf -- '-A %s -m mark --mark 0/%s -j MARK --set-xmark %s/%s\n' \
            "$SITE_ROUTE_CHAIN" "$SITE_ROUTE_MASK" "$SITE_DEFAULT_MARK" "$SITE_ROUTE_MASK"
        printf -- '-A %s -j CONNMARK --save-mark --nfmask %s --ctmask %s\nCOMMIT\n' \
            "$SITE_ROUTE_CHAIN" "$SITE_ROUTE_MASK" "$SITE_ROUTE_MASK"
    } | iptables-restore --wait 5 --noflush || return 1

    for address in "${!destinations[@]}"; do
        if [ "${destinations[$address]}" = conflict ]; then
            conflicts="$conflicts,\"$address\""
        fi
    done
    SITE_CONFLICTS_JSON="[${conflicts#,}]"
    SITE_REFRESH_AT=$((now + 30))
}
