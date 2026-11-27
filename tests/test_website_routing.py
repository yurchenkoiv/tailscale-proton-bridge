import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class WebsiteRoutingTest(unittest.TestCase):
    def run_routing(self, script, **settings):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "commands"
            classifier = Path(directory) / "classifier"
            result = subprocess.run(
                ["bash", "-euo", "pipefail", "-c", r"""
source ./vpn-bypass.sh
source ./website-routing.sh
PROFILE_COUNT=2
PROFILE_IDS=(usa ukraine)
PROFILE_TYPES=(wireguard wireguard)
VPN_INTERFACES=(vpn0 vpn1)

ip() {
    printf 'ip %s\n' "$*" >> "$COMMAND_LOG"
    case "$*" in
        '-4 rule del '*) return 1 ;;
        '-4 route show default') echo 'default via 172.18.0.1 dev eth0' ;;
        '-4 route show table 52001 default')
            echo 'default dev vpn1 metric 10'
            echo 'blackhole default metric 32767'
            ;;
    esac
}
iptables() { printf 'iptables %s\n' "$*" >> "$COMMAND_LOG"; }
iptables-restore() { cat > "$CLASSIFIER"; }
dig() {
    case "${@: -1}" in
        usa.example.) echo 'usa.example. 60 IN A 8.8.8.8' ;;
        ukraine.example.)
            echo 'ukraine.example. 60 IN A 9.9.9.9'
            echo 'ukraine.example. 60 IN A 8.8.8.8'
            ;;
        direct.example.)
            echo 'direct.example. 60 IN A 1.1.1.1'
            echo 'direct.example. 60 IN A 192.168.0.1'
            ;;
    esac
}
""" + script],
                cwd=ROOT,
                env={
                    **os.environ,
                    "COMMAND_LOG": str(log),
                    "CLASSIFIER": str(classifier),
                    **settings,
                },
                text=True,
                capture_output=True,
                check=True,
            )
            return (
                log.read_text() if log.exists() else "",
                classifier.read_text() if classifier.exists() else "",
                result.stdout.strip(),
            )

    def test_conflict_uses_default_and_tunnel_loss_keeps_blackhole(self):
        commands, classifier, conflicts = self.run_routing(
            """
init_website_routing
refresh_website_routing
configure_website_ingress ts0 100
set_website_tunnel_state 1 connected
set_website_tunnel_state 1 degraded
set_website_tunnel_state 1 connected
printf '%s\n' "$SITE_CONFLICTS_JSON"
""",
            VPN_ROUTING_DEFAULT="usa",
            VPN_ROUTING_RULES="usa.example@usa,ukraine.example@ukraine",
            VPN_BYPASS_DOMAINS="direct.example",
        )
        self.assertEqual(conflicts, '["8.8.8.8"]')
        self.assertNotIn("8.8.8.8", classifier)
        self.assertNotIn("192.168.0.1", classifier)
        self.assertIn("-d 9.9.9.9/32 -j MARK --set-xmark 131072/", classifier)
        self.assertIn("-d 1.1.1.1/32 -j MARK --set-xmark 196608/", classifier)
        self.assertIn("--mark 0/0xffff0000 -j MARK --set-xmark 65536/", classifier)
        self.assertIn("blackhole default metric 32767 table 52001", commands)
        self.assertEqual(commands.count("replace default dev vpn1 metric 10 table 52001"), 2)
        self.assertIn("del default dev vpn1 metric 10 table 52001", commands)
        self.assertIn("FORWARD -i ts0 -o vpn1 -m mark --mark 131072/", commands)
        self.assertIn("FORWARD -i vpn1 -o ts0 -m mark --mark 100/", commands)

    def test_disabled_policy_does_not_change_routing(self):
        commands, classifier, _ = self.run_routing(
            "init_website_routing\nrefresh_website_routing\n",
            VPN_ROUTING_DEFAULT="",
            VPN_ROUTING_RULES="ukraine.example@ukraine",
            VPN_BYPASS_DOMAINS="",
        )
        self.assertEqual((commands, classifier), ("", ""))

    def test_conflicting_hostname_is_rejected_before_network_changes(self):
        commands, classifier, _ = self.run_routing(
            "if init_website_routing; then exit 1; fi\n",
            VPN_ROUTING_DEFAULT="usa",
            VPN_ROUTING_RULES="direct.example@ukraine",
            VPN_BYPASS_DOMAINS="direct.example",
        )
        self.assertEqual((commands, classifier), ("", ""))


if __name__ == "__main__":
    unittest.main()
