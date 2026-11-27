# Shared by the bridge entrypoints. Read settings as data, never as shell code.
ROUTING_SETTINGS_PATH="${PROFILE_ROOT:-/etc/bridge-profiles}/.website-routing.env"
ROUTING_REVISION=

load_routing_settings() {
    [ -e "$ROUTING_SETTINGS_PATH" ] || return 0

    local revision bypass default rules
    {
        IFS= read -r revision &&
        IFS= read -r bypass &&
        IFS= read -r default &&
        IFS= read -r rules
    } < "$ROUTING_SETTINGS_PATH" || return 1

    revision=${revision#ROUTING_REVISION=}
    if [[ ! "$revision" =~ ^[a-f0-9]{32}$ || "$bypass" != VPN_BYPASS_DOMAINS=* ||
          "$default" != VPN_ROUTING_DEFAULT=* || "$rules" != VPN_ROUTING_RULES=* ]]; then
        return 1
    fi

    ROUTING_REVISION="$revision"
    export VPN_BYPASS_DOMAINS="${bypass#*=}"
    export VPN_ROUTING_DEFAULT="${default#*=}"
    export VPN_ROUTING_RULES="${rules#*=}"
}

routing_apply_requested() {
    local revision=
    if [ -e "$ROUTING_SETTINGS_PATH" ]; then
        IFS= read -r revision < "$ROUTING_SETTINGS_PATH" || return 1
        revision=${revision#ROUTING_REVISION=}
        [[ "$revision" =~ ^[a-f0-9]{32}$ ]] || return 1
    fi
    [ "$revision" != "$ROUTING_REVISION" ]
}
