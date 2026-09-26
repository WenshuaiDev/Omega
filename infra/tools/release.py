#!/usr/bin/env python3
"""Bounded release checks in the bundled tools image; no host control access."""
import http.client
import json
import re
import socket
import ssl
import stat
import sys
from pathlib import Path
from compose_policy import validate_model


def run(args):
    command = args[0]
    if command in {"build-evidence", "compatibility"}:
        root = Path(args[1])
        value = json.loads((root / "evidence/api-version.json").read_text())
        assert value["exit_code"] == 0 and value["command"] == "version", "API version query failed"
        if command == "compatibility":
            print(f'compatibility\tconfig-v1\t{value["data"]["schema_min"]}\t{value["data"]["schema_max"]}')
        else:
            assert value["version"] == args[2] and value["commit"] == args[3], "API build identity differs"
            (root / "evidence/build.json").write_text(json.dumps({"version": args[2], "commit": args[3], "platform": "linux/amd64", "native_linux_amd64": "not executed; required separately", "test_acceptance": "pending; build evidence is not acceptance"}, indent=2) + "\n")
    elif command == "input-version":
        for name in ("api.yaml", "migration.yaml", "web.json", "console.json", "tls/cert.pem"):
            path = Path(args[1]) / name
            assert path.is_file() and not path.is_symlink() and stat.S_IMODE(path.stat().st_mode) & 0o004, f"{name} must be a regular file readable by nonroot container users (for example0644)"
        for app in ("web", "console"):
            value = json.loads((Path(args[1]) / f"{app}.json").read_text())
            assert value["version"] == args[2], "public configuration version differs from explicit release"
    elif command == "model":
        model = json.loads(Path(args[1]).read_text())
        image_users = dict(line.split("\t", 1) for line in Path(args[1]).with_name("image-users.tsv").read_text().splitlines())
        validate_model(args[2], model, args[3], args[4], image_users)
    elif command == "smoke":
        root, domain, version, environment = Path(args[1]), args[2], args[3], args[4]
        context = ssl.create_default_context(cafile=str(root / "tls/cert.pem"))
        paths = ("/api/v1/ping", "/web/", "/console/", "/web/deep/route", "/console/deep/route", "/web/runtime-config.json", "/console/runtime-config.json", "/web/missing.js", "/console/missing.css", "/unknown")
        for path in paths:
            conn = http.client.HTTPSConnection(domain, 8443, context=context, timeout=8)
            # Share edge's network namespace; validate certificate against DOMAIN,
            # connect only loopback, never DNS or an environment proxy.
            conn.sock = context.wrap_socket(socket.create_connection(("127.0.0.1", 8443), timeout=8), server_hostname=domain)
            conn.request("GET", path, headers={"Host": domain})
            response = conn.getresponse()
            body = response.read(1024 * 1024)
            expected = 404 if path.endswith(("missing.js", "missing.css")) or path == "/unknown" else 200
            assert response.status == expected, f"TLS smoke {path}: HTTP {response.status}, expected {expected}"
            if path.endswith("runtime-config.json"):
                config = json.loads(body)
                assert config["version"] == version and config["environment"] == environment
                assert response.getheader("Cache-Control") == "no-store"
            if path == "/api/v1/ping":
                ping = json.loads(body)
                assert ping["version"] == version and ping["environment"] == environment
            if path in ("/web/", "/console/"):
                assert re.search(rb'/assets/[^" ]+\.js', body), "missing built asset reference"
            conn.close()
        print("TLS, routes, runtime configuration and API version smoke passed under maintenance")
    else:
        raise ValueError("unknown release check")


if __name__ == "__main__":
    try:
        run(sys.argv[1:])
    except (AssertionError, ValueError, KeyError, OSError) as exc:
        print(f"release check failed: {exc}", file=sys.stderr)
        sys.exit(2)
