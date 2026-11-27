import importlib.util
from pathlib import Path
from unittest.mock import patch

import dns.message
import dns.rrset


SPEC = importlib.util.spec_from_file_location(
    "website_dns", Path(__file__).resolve().parents[1] / "website-dns.py"
)
website_dns = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(website_dns)


def test_most_specific_wildcard_and_exact_exceptions():
    suffixes = [("video.example.com", "video"), ("example.com", "general")]
    exact = {"direct.example.com"}
    match = website_dns.select_set
    assert match("eu.video.example.com", exact, suffixes) == "video"
    assert match("video.example.com", exact, suffixes) == "general"
    assert match("direct.example.com", exact, suffixes) is None
    assert match("example.com", exact, suffixes) is None
    assert match("notexample.com", exact, suffixes) is None


def test_forwarder_learns_public_addresses_with_cname_ttl_before_reply():
    request = dns.message.make_query("video.example.com", "A")
    response = dns.message.make_response(request)
    response.answer.extend(
        [
            dns.rrset.from_text("video.example.com.", 20, "IN", "CNAME", "cdn.example.net."),
            dns.rrset.from_text("cdn.example.net.", 60, "IN", "A", "1.1.1.1", "192.168.1.5"),
        ]
    )
    response = dns.message.from_wire(response.to_wire())
    forwarder = website_dns.Forwarder(["127.0.0.1"], set(), [("example.com", "video")])
    with (
        patch("dns.query.udp_with_fallback", return_value=(response, False)),
        patch("subprocess.run") as install,
    ):
        received = dns.message.from_wire(forwarder.answer(request.to_wire()))
    assert received.answer == response.answer
    assert install.call_args.kwargs["input"] == "add video 1.1.1.1 timeout 20 -exist\n"
