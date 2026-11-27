import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]


class RoutingOnlySupervisorTest(unittest.TestCase):
    def test_primary_keeps_its_identity_and_secondary_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            profiles = work / "profiles"
            for name in ("primary", "secondary"):
                profile = profiles / name
                profile.mkdir(parents=True)
                metadata = "VPN_TYPE=wireguard\n"
                if name == "primary":
                    metadata += "TS_HOSTNAME=existing-exit\n"
                else:
                    metadata += "ROUTING_ONLY=1\n"
                (profile / "profile.env").write_text(metadata)
                (profile / "wireguard.conf").write_text("[Interface]\n")

            # Run the real supervisor under unprivileged command stubs. Keep
            # its container paths inside the fixture's temporary directory.
            text = (ROOT / "multi-entrypoint.sh").read_text()
            paths = {
                "/tmp": "tmp",
                "/var/run/bridge-status": "status",
                "/var/run/tailscale": "sockets",
                "/var/lib/tailscale": "tailscale",
            }
            for path, name in paths.items():
                text = text.replace(path, str(work / name))
            for script in ("routing-settings.sh", "vpn-bypass.sh", "website-routing.sh"):
                text = text.replace(f". /{script}", f'. "{ROOT / script}"')
            text = text.replace(" -S ", " -f ")
            supervisor = work / "supervisor.sh"
            supervisor.write_text(text)
            stub = work / "commands.sh"
            stub.write_text(r"""
sysctl() { [ "$1" != -n ] || echo 1; }
ip() {
    printf 'ip %s\n' "$*" >> "$WORK/log"
    case "$*" in
        '-4 rule del '*) return 1 ;;
        'addr show dev '*) echo 'inet 10.2.0.2/32' ;;
        '-4 -o addr show dev '*) echo '1: vpn0 inet 10.2.0.2/32' ;;
        '-4 route show table 52001 default')
            echo 'default dev vpn1 metric 10'
            echo 'blackhole default metric 32767'
            ;;
    esac
}
iptables() { printf 'iptables %s\n' "$*" >> "$WORK/log"; }
ip6tables() { :; }
iptables-restore() { cat > "$WORK/classifier"; }
wg-quick() { printf 'wg-quick %s\n' "$*" >> "$WORK/log"; }
dig() { echo 'selected.example. 60 IN A 9.9.9.9'; }
curl() {
    printf 'curl %s\n' "$*" >> "$WORK/log"
    if [[ "$*" == *%vpn1* ]]; then
        [ ! -e "$WORK/secondary-probed" ] || return 1
        touch "$WORK/secondary-probed"
    fi
}
tailscaled() {
    printf 'tailscaled %s\n' "$*" >> "$WORK/log"
    for arg in "$@"; do
        if [[ "$arg" == --socket=* ]]; then
            touch "${arg#*=}"
            exec /bin/sleep 30
        fi
    done
}
tailscale() {
    printf 'tailscale %s\n' "$*" >> "$WORK/log"
    if [[ "$*" == *' ip -4' ]]; then
        echo 100.101.102.103
    fi
}
sleep() {
    if [ "$1" = 123 ]; then
        cp "$STATUS_FILE" "$WORK/final-status.json"
        kill -TERM "$$"
    else
        command sleep 0.02
    fi
}
""")
            result = subprocess.run(
                ["bash", str(supervisor)],
                env={
                    **os.environ,
                    "BASH_ENV": str(stub),
                    "WORK": directory,
                    "PROFILE_ROOT": str(profiles),
                    "VPN_ROUTING_DEFAULT": "primary",
                    "VPN_ROUTING_RULES": "selected.example@secondary",
                    "VPN_BYPASS_DOMAINS": "",
                    "VPN_CHECK_INTERVAL": "123",
                    "VPN_FAILURE_THRESHOLD": "1",
                    "VPN_HEALTHCHECK_URLS": "https://probe.example",
                },
                check=True,
                capture_output=True,
                text=True,
                timeout=15,
            )

            log = (work / "log").read_text()
            classifier = (work / "classifier").read_text()
            self.assertTrue((work / "final-status.json").exists(), result.stdout + result.stderr + log)
            status = json.loads((work / "final-status.json").read_text())
            self.assertEqual(log.count("tailscaled "), 1)
            self.assertIn("tailscaled --state=" + str(work / "tailscale/profiles/primary/tailscaled.state"), log)
            self.assertEqual(log.count("--advertise-exit-node"), 1)
            self.assertIn("--hostname=existing-exit", log)
            self.assertIn("10.2.0.2%vpn1", log)
            self.assertIn("-d 9.9.9.9/32 -j MARK --set-xmark 131072/", classifier)
            self.assertIn("FORWARD -i ts0 -o vpn1 -m mark --mark 131072/", log)
            self.assertIn("blackhole default metric 32767 table 52001", log)
            self.assertIn("replace default dev vpn1 metric 10 table 52001", log)
            self.assertIn("del default dev vpn1 metric 10 table 52001", log)
            self.assertTrue(status["connected"])
            self.assertEqual(status["tailscale_ip"], "100.101.102.103")
            self.assertEqual(status["profiles"][1]["state"], "degraded")
            self.assertTrue(status["profiles"][1]["routing_only"])
            self.assertEqual(status["profiles"][1]["tailscale_interface"], "")


if __name__ == "__main__":
    unittest.main()
