#!/usr/bin/env python3
"""Exercise the actual bundled SPICE client's TLS/link boundary on IPv4 loopback.

This deliberately does NOT implement a SPICE server beyond reading REDQ.
A trusted connection must transmit the SPICE link magic; rejected connections
must not transmit application bytes or downgrade to a plaintext connection.
"""
import argparse
import os
import socket
import ssl
import subprocess
import tempfile
import threading
from pathlib import Path

SUBJECT = "CN=mrv-ci.test"
TICKET = "mrv-ci-synthetic-ticket"


def run(*args):
    subprocess.run(args, check=True, timeout=30, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def create_certificates(root):
    # OpenSSL configuration avoids version-specific -addext behavior.
    config = root / "openssl.cnf"
    config.write_text(
        "[req]\nprompt=no\ndistinguished_name=dn\n"
        "[dn]\nCN=mrv-ci.test\n"
        "[ca_ext]\nbasicConstraints=critical,CA:TRUE\n"
        "keyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n"
        "[leaf_ext]\nbasicConstraints=critical,CA:FALSE\n"
        "keyUsage=critical,digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=serverAuth\nsubjectAltName=DNS:mrv-ci.test,IP:127.0.0.1\n"
    )
    for name in ("trusted", "untrusted"):
        run("openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
            "-subj", f"/CN=MRV CI {name} CA", "-config", str(config), "-extensions", "ca_ext",
            "-keyout", str(root / f"{name}.key"), "-out", str(root / f"{name}.pem"))
    run("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-config", str(config),
        "-keyout", str(root / "server.key"), "-out", str(root / "server.csr"))
    run("openssl", "x509", "-req", "-in", str(root / "server.csr"), "-days", "2",
        "-CA", str(root / "trusted.pem"), "-CAkey", str(root / "trusted.key"),
        "-set_serial", "1", "-extfile", str(config), "-extensions", "leaf_ext",
        "-out", str(root / "server.pem"))


def fixture_profile(port, ca, subject):
    pem = ca.read_text().strip().replace("\n", r"\n")
    return (
        "[virt-viewer]\n"
        "type=spice\nhost=127.0.0.1\n"
        f"tls-port={port}\npassword={TICKET}\nca={pem}\n"
        f"host-subject={subject}\ndelete-this-file=0\n"
    )


def observe(listener, context, stop, observations):
    listener.settimeout(0.2)
    while not stop.is_set():
        try:
            peer, _ = listener.accept()
        except socket.timeout:
            continue
        with peer:
            observations["connections"] += 1
            peer.settimeout(4)
            try:
                first = peer.recv(1, socket.MSG_PEEK)
                if first != b"\x16":
                    if first:
                        observations["plaintext"] = True
                    continue
                with context.wrap_socket(peer, server_side=True) as channel:
                    observations["handshakes"] += 1
                    data = bytearray()
                    while len(data) < 4:
                        chunk = channel.recv(4 - len(data))
                        if not chunk:
                            break
                        data.extend(chunk)
                        # Record even partial application data from rejected peers.
                        observations["application_data"] = True
                    if bytes(data) == b"REDQ":
                        observations["link_header"] = True
            except (ssl.SSLError, OSError):
                # The client is expected to close on certificate rejection.
                continue


def assert_observations(name, observations, expect_link):
    if not observations["connections"]:
        raise AssertionError(f"{name}: client never reached fixture")
    if observations["plaintext"]:
        raise AssertionError(f"{name}: unexpected plaintext connection")
    if expect_link:
        if not observations["handshakes"] or not observations["link_header"]:
            raise AssertionError(f"{name}: trusted peer did not send REDQ")
    elif observations["application_data"]:
        raise AssertionError(f"{name}: rejected peer sent application data")


def test_case(app, root, context, name, ca, subject, expect_link, injected_env=None):
    observations = dict(connections=0, handshakes=0, plaintext=False,
                        application_data=False, link_header=False)
    stop = threading.Event()
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(8)
        profile = root / f"{name}.vv"
        profile.write_text(fixture_profile(listener.getsockname()[1], ca, subject))
        thread = threading.Thread(target=observe, args=(listener, context, stop, observations), daemon=True)
        thread.start()
        env = {k: v for k, v in os.environ.items() if not k.startswith(("DYLD_", "GST_", "OPENSSL_"))}
        for key in list(env):
            if key.lower() in ("http_proxy", "https_proxy", "all_proxy", "no_proxy", "spice_proxy"):
                env.pop(key)
        env["NO_PROXY"] = "127.0.0.1"
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["GST_REGISTRY"] = str(root / "gst-registry.bin")
        env["MRV_ENABLE_INTEGRATION_PROBES"] = "1"
        if injected_env is not None:
            env.update(injected_env)
        executable = app / "Contents" / "MacOS" / "Mac Remote Viewer"
        try:
            result = subprocess.run([str(executable), "--loopback-tls-probe", str(profile)],
                                    cwd=root, env=env, capture_output=True, text=True, timeout=30)
        finally:
            stop.set()
            thread.join(timeout=6)
        if thread.is_alive():
            raise AssertionError(f"{name}: fixture failed to stop")
        markers = {"MRV_TLS_PROBE_REJECTED_TLS", "MRV_TLS_PROBE_TERMINAL"}
        if result.returncode != 0 or not markers.intersection(result.stdout.splitlines()):
            raise AssertionError(f"{name}: client probe failed (exit={result.returncode})")
        assert_observations(name, observations, expect_link)
        print(f"{name}: {observations}", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True, type=Path)
    args = parser.parse_args()
    app = args.app.resolve()
    with tempfile.TemporaryDirectory(prefix="mrv-loopback-tls-") as raw:
        root = Path(raw)
        create_certificates(root)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(root / "server.pem", root / "server.key")
        test_case(app, root, context, "trusted", root / "trusted.pem", SUBJECT, True)
        test_case(app, root, context, "wrong-ca", root / "untrusted.pem", SUBJECT, False)
        test_case(app, root, context, "wrong-subject", root / "trusted.pem", "CN=wrong.test", False)

        # A valid but hostile config would require algorithms from a nonexistent
        # provider. The real packaged client's TLS must still succeed, without
        # accepting the ambient CA in place of the explicit .vv trust.
        poison = root / "external-openssl"
        poison.mkdir()
        config = poison / "openssl.cnf"
        config.write_text("config_diagnostics = 1\nopenssl_conf = init\n"
                          "[init]\nalg_section = algorithm_properties\n"
                          "[algorithm_properties]\n"
                          "default_properties = provider=mrv_nonexistent\n")
        keylog = poison / "tls-secrets.log"
        injected = {
            "OPENSSL_CONF": str(config),
            "OPENSSL_CONF_INCLUDE": str(poison),
            "OPENSSL_MODULES": str(poison),
            "OPENSSL_ENGINES": str(poison),
            "SSL_CERT_FILE": str(root / "trusted.pem"),
            "SSL_CERT_DIR": str(poison),
            "SSLKEYLOGFILE": str(keylog),
        }
        test_case(app, root, context, "poisoned-config-trusted", root / "trusted.pem",
                  SUBJECT, True, injected)
        test_case(app, root, context, "poisoned-config-wrong-ca", root / "untrusted.pem",
                  SUBJECT, False, injected)
        test_case(app, root, context, "poisoned-config-wrong-subject", root / "trusted.pem",
                  "CN=wrong.test", False, injected)
        if keylog.exists():
            raise AssertionError("inherited SSLKEYLOGFILE was used")
        print("MRV_OPENSSL_ENV_ISOLATION_OK", flush=True)
    print("Real SPICE TLS/link boundary checks passed (not a complete SPICE session).")


if __name__ == "__main__":
    main()
