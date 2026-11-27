"""Forward Tailnet DNS queries and learn public IPv4 wildcard destinations."""

import ipaddress
import logging
import socketserver
import struct
import subprocess
import sys
import threading

import dns.exception
import dns.flags
import dns.message
import dns.opcode
import dns.query
import dns.rcode
import dns.rdatatype
import dns.resolver


def select_set(name, exact_names, suffixes):
    if name in exact_names:
        return None
    for suffix, destination_set in suffixes:
        if name.endswith("." + suffix):
            return destination_set
    return None


def learn_addresses(response, destination_set):
    if response.rcode() != dns.rcode.NOERROR:
        return
    chain = response.resolve_chaining()
    if chain.answer is None:
        return
    # ipset reserves zero for entries that never expire.
    ttl = max(1, min(chain.minimum_ttl, 2147483))
    rules = []
    for record in chain.answer:
        address = ipaddress.IPv4Address(record.address)
        if address.is_global and not address.is_multicast and not address.is_reserved:
            rules.append(f"add {destination_set} {address} timeout {ttl} -exist\n")
    if rules:
        subprocess.run(
            ["ipset", "restore"], input="".join(rules), text=True, check=True, timeout=2
        )


class Forwarder:
    def __init__(self, resolvers, exact_names, suffixes):
        self.resolvers = resolvers
        self.exact_names = exact_names
        self.suffixes = suffixes

    def answer(self, wire, tcp=False):
        request = dns.message.from_wire(wire)
        if request.opcode() != dns.opcode.QUERY or len(request.question) != 1:
            response = dns.message.make_response(request)
            response.set_rcode(dns.rcode.REFUSED)
            return response.to_wire()

        question = request.question[0]
        response = None
        for resolver in self.resolvers:
            try:
                if tcp:
                    candidate = dns.query.tcp(request, resolver, timeout=2)
                else:
                    candidate, _ = dns.query.udp_with_fallback(request, resolver, timeout=2)
            except (dns.exception.DNSException, OSError):
                continue
            if candidate.rcode() not in (dns.rcode.SERVFAIL, dns.rcode.REFUSED):
                response = candidate
                break

        if response is not None and question.rdtype == dns.rdatatype.A:
            name = question.name.to_text(omit_final_dot=True).lower()
            destination_set = select_set(name, self.exact_names, self.suffixes)
            if destination_set:
                try:
                    learn_addresses(response, destination_set)
                except (dns.exception.DNSException, subprocess.SubprocessError, OSError):
                    logging.exception("Could not install a wildcard DNS route")
                    response = None

        if response is None:
            response = dns.message.make_response(request)
            response.set_rcode(dns.rcode.SERVFAIL)
        max_size = 65535 if tcp else min(1232, max(512, request.payload))
        return response.to_wire(max_size=max_size, prefer_truncation=not tcp)


class BoundedServer(socketserver.ThreadingMixIn):
    daemon_threads = True
    allow_reuse_address = True
    slots = threading.BoundedSemaphore(24)

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()


class UDPServer(BoundedServer, socketserver.UDPServer):
    pass


class TCPServer(BoundedServer, socketserver.TCPServer):
    pass


class UDPHandler(socketserver.BaseRequestHandler):
    def handle(self):
        wire, sock = self.request
        try:
            response = self.server.forwarder.answer(wire)
            sock.sendto(response, self.client_address)
        except (dns.exception.DNSException, OSError):
            return


class TCPHandler(socketserver.StreamRequestHandler):
    timeout = 5

    def handle(self):
        try:
            length = self.rfile.read(2)
            if len(length) != 2:
                return
            size = struct.unpack("!H", length)[0]
            wire = self.rfile.read(size)
            if len(wire) != size:
                return
            response = self.server.forwarder.answer(wire, tcp=True)
            self.wfile.write(struct.pack("!H", len(response)) + response)
        except (dns.exception.DNSException, OSError):
            return


def main():
    port, rule_path = int(sys.argv[1]), sys.argv[2]
    exact_names = set()
    suffixes = []
    with open(rule_path, encoding="ascii") as rule_file:
        for line in rule_file:
            name, destination_set = line.split()
            if name.startswith("*."):
                suffixes.append((name[2:], destination_set))
            else:
                exact_names.add(name)
    suffixes.sort(key=lambda rule: len(rule[0]), reverse=True)

    resolvers = dns.resolver.Resolver().nameservers
    forwarder = Forwarder(resolvers, exact_names, suffixes)
    with UDPServer(("0.0.0.0", port), UDPHandler) as udp, TCPServer(
        ("0.0.0.0", port), TCPHandler
    ) as tcp:
        udp.forwarder = tcp.forwarder = forwarder
        threading.Thread(target=tcp.serve_forever, daemon=True).start()
        udp.serve_forever()


if __name__ == "__main__":
    main()
