# Shared IPv4 split-tunnel configuration, sourced by both bridge entrypoints.
BYPASS_TABLE=51901
BYPASS_PRIORITY=900
BYPASS_SET=bridge-vpn-bypass
BYPASS_NEXT_SET=bridge-vpn-bypass-next

normalize_bypass_domains() {
    printf '%s\n' "$1" | awk -F, '
        {
            for (i = 1; i <= NF; i++) {
                domain = tolower($i)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", domain)
                sub(/\.$/, "", domain)
                count = split(domain, labels, ".")
                if (count < 2 || length(domain) > 253 || labels[count] !~ /[a-z]/)
                    exit 1
                for (j = 1; j <= count; j++)
                    if (length(labels[j]) > 63 || labels[j] !~ /^[a-z0-9]([a-z0-9-]*[a-z0-9])?$/)
                        exit 1
                if (++domains > 10) exit 1
                print domain
            }
        }
    '
}

resolve_public_ipv4() {
    local answers
    answers=$(dig +time=1 +tries=1 +noall +answer A "$1.") || answers=""
    # Never install routes for private, shared, link-local or reserved IPv4 space.
    printf '%s\n' "$answers" | awk '
        $4 == "A" {
            split($5, octet, ".")
            a = octet[1]; b = octet[2]; c = octet[3]
            if (a == 0 || a == 10 || a == 127 || a >= 224 ||
                (a == 100 && b >= 64 && b <= 127) ||
                (a == 169 && b == 254) ||
                (a == 172 && b >= 16 && b <= 31) ||
                (a == 192 && (b == 168 || (b == 0 && (c == 0 || c == 2)) || (b == 88 && c == 99))) ||
                (a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100))) ||
                (a == 203 && b == 0 && c == 113))
                next
            print $5
        }
    '
}

init_vpn_bypass() {
    [ -n "${VPN_BYPASS_DOMAINS:-}" ] || return 0

    # Capture Docker's original gateway before either VPN changes routing.
    local route
    route=$(ip -4 route show default | awk '$1 == "default" && $2 == "via" {print $3, $5; exit}')
    BYPASS_GATEWAY=${route%% *}
    BYPASS_DEVICE=${route#* }
    if [ -z "$BYPASS_GATEWAY" ] || [ -z "$BYPASS_DEVICE" ]; then
        echo "VPN_BYPASS_DOMAINS requires an IPv4 default gateway" >&2
        return 1
    fi

    # Validate and normalize the comma-separated list without shell globbing.
    BYPASS_DOMAINS=$(normalize_bypass_domains "$VPN_BYPASS_DOMAINS") || {
        echo "VPN_BYPASS_DOMAINS must contain up to 10 comma-separated DNS hostnames" >&2
        return 1
    }
    [ -n "$BYPASS_DOMAINS" ] || return 1

    ipset create "$BYPASS_SET" hash:ip family inet -exist &&
        ipset create "$BYPASS_NEXT_SET" hash:ip family inet -exist &&
        ipset flush "$BYPASS_SET" &&
        iptables -t nat -A POSTROUTING -o "$BYPASS_DEVICE" -m set \
            --match-set "$BYPASS_SET" dst -j MASQUERADE
}

configure_vpn_bypass_interface() {
    [ -n "${BYPASS_DOMAINS:-}" ] || return 0
    local ts_if="$1"

    # Install the drop first so a partially configured interface stays closed.
    iptables -I FORWARD -i "$ts_if" -o "$BYPASS_DEVICE" -j DROP &&
        iptables -I FORWARD -i "$ts_if" -o "$BYPASS_DEVICE" -m set \
            --match-set "$BYPASS_SET" dst -j ACCEPT &&
        iptables -I FORWARD -i "$BYPASS_DEVICE" -o "$ts_if" -m conntrack \
            --ctstate ESTABLISHED --ctdir REPLY -j ACCEPT &&
        ip -4 rule add pref "$BYPASS_PRIORITY" iif "$ts_if" lookup "$BYPASS_TABLE"
}

refresh_vpn_bypass() {
    [ -n "${BYPASS_DOMAINS:-}" ] || return 0
    local now domain answers addresses address routes
    # /proc/uptime is monotonic, including across wall-clock adjustments.
    read -r now _ < /proc/uptime || return 1
    now=${now%%.*}
    [ "$now" -ge "${BYPASS_REFRESH_AT:-0}" ] || return 0
    BYPASS_REFRESH_AT=$((now + 30))

    addresses=""
    for domain in $BYPASS_DOMAINS; do
        answers=$(resolve_public_ipv4 "$domain")
        if [ -z "$answers" ]; then
            echo "VPN bypass: no public IPv4 DNS answers for $domain" >&2
        fi
        addresses="$addresses $answers"
    done

    ipset flush "$BYPASS_NEXT_SET" || return 1
    for address in $addresses; do
        ip -4 route replace "$address/32" via "$BYPASS_GATEWAY" dev "$BYPASS_DEVICE" \
            onlink table "$BYPASS_TABLE" || return 1
        ipset add "$BYPASS_NEXT_SET" "$address" -exist || return 1
    done
    ipset swap "$BYPASS_NEXT_SET" "$BYPASS_SET" || return 1

    # Routes no longer authorized by the active set are blocked until removed.
    routes=$(ip -4 route show table "$BYPASS_TABLE" 2>/dev/null | awk '{print $1}')
    for address in $routes; do
        if ! ipset test "$BYPASS_SET" "${address%/32}" >/dev/null 2>&1; then
            ip -4 route del "$address" table "$BYPASS_TABLE" || return 1
        fi
    done
}
