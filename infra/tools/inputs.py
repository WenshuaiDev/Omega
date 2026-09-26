#!/usr/bin/env python3
"""Instance input validation and edge generation; never executes input as code."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import subprocess
import sys
import yaml


class StrictLoader(yaml.SafeLoader):
    pass


def mapping(loader, node, deep=False):
    result = {}
    for k, v in node.value:
        key = loader.construct_object(k, deep=deep)
        if key in result:
            raise ValueError("duplicate YAML field")
        result[key] = loader.construct_object(v, deep=deep)
    return result


StrictLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)


def read_instance(root, environment):
    data = {}
    for line in (root / "instance.env").read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep or key in data or key not in {"ENVIRONMENT", "INSTANCE_ID", "HTTP_PORT", "HTTPS_PORT", "DOMAIN"}:
            raise ValueError("invalid or duplicate instance.env field")
        data[key] = value
    if set(data) != {"ENVIRONMENT", "INSTANCE_ID", "HTTP_PORT", "HTTPS_PORT", "DOMAIN"}:
        raise ValueError("instance.env requires ENVIRONMENT, INSTANCE_ID, HTTP_PORT, HTTPS_PORT, DOMAIN")
    if environment not in {"dev", "test", "prod"} or data["ENVIRONMENT"] != environment:
        raise ValueError("explicit environment differs from instance.env")
    if not re.fullmatch(r"[a-z][a-z0-9-]{5,47}", data["INSTANCE_ID"]):
        raise ValueError("invalid instance ID (6-48 lowercase alphanumeric/hyphen characters, starting with letter)")
    for key in ["HTTP_PORT", "HTTPS_PORT"]:
        if not data[key].isdigit() or not 1 <= int(data[key]) <= 65535:
            raise ValueError(f"invalid {key}")
    if data["HTTP_PORT"] == data["HTTPS_PORT"]:
        raise ValueError("HTTP and HTTPS ports must differ")
    if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?", data["DOMAIN"]):
        raise ValueError("invalid DOMAIN")
    return data


def init(root, environment):
    if environment != "dev":
        raise ValueError("automatic initialization is only available for dev")
    data = read_instance(root, environment)
    (root / "secrets").mkdir(mode=0o700, exist_ok=True)
    for role in ("admin", "migrator", "runtime"):
        path = root / "secrets" / role
        if not path.exists():
            with path.open("x") as f:
                os.chmod(path, 0o600)
                f.write(secrets.token_hex(32) + "\n")
    for filename, role in (("api.yaml", "runtime"), ("migration.yaml", "migrator")):
        path = root / filename
        if not path.exists():
            config = {"environment": environment, "instance_id": data["INSTANCE_ID"], "http": {"address": ":8080", "shutdown_timeout": "10s"}, "database": {"host": "db", "port": 5432, "name": "omega", "user": f"omega_{role}", "password_file": "/run/secrets/db_password", "sslmode": "disable", "connect_timeout": "5s"}, "operation_timeout": "60s"}
            path.write_text(yaml.safe_dump(config, sort_keys=False))
    for app in ("web", "console"):
        path = root / f"{app}.json"
        if not path.exists():
            path.write_text(json.dumps({"schemaVersion": 1, "appId": app, "environment": environment, "version": "dev", "apiBaseUrl": "/api"}, indent=2) + "\n")


def exact(value, fields, label):
    if not isinstance(value, dict) or set(value) != set(fields):
        raise ValueError(f"{label} requires exactly: {', '.join(fields)}")


def json_object(pairs):
    result = {}
    for k, v in pairs:
        if k in result:
            raise ValueError("duplicate JSON field")
        result[k] = v
    return result


def validate(root, environment):
    data = read_instance(root, environment)
    for filename, role in (("api.yaml", "runtime"), ("migration.yaml", "migrator")):
        config = yaml.load((root / filename).read_text(), Loader=StrictLoader)
        exact(config, ["environment", "instance_id", "http", "database", "operation_timeout"], filename)
        if config["environment"] != environment or config["instance_id"] != data["INSTANCE_ID"]:
            raise ValueError(f"{filename}: environment/instance mismatch")
        exact(config["http"], ["address", "shutdown_timeout"], filename + ".http")
        exact(config["database"], ["host", "port", "name", "user", "password_file", "sslmode", "connect_timeout"], filename + ".database")
        db = config["database"]
        if db["host"] != "db" or type(db["port"]) is not int or db["port"] != 5432 or db["name"] != "omega" or db["user"] != f"omega_{role}" or db["password_file"] != "/run/secrets/db_password" or db["sslmode"] != "disable":
            raise ValueError(f"{filename}: database target or role differs from Compose contract")
        if config["http"]["address"] != ":8080":
            raise ValueError(f"{filename}: http.address must be :8080")
        for index, duration in enumerate((config["operation_timeout"], config["http"]["shutdown_timeout"], db["connect_timeout"])):
            if not isinstance(duration, str) or not re.fullmatch(r"(?:[0-9]+(?:\.[0-9]+)?(?:ms|s|m|h))+", duration) or not re.search(r"[1-9]", duration):
                raise ValueError(f"{filename}: invalid duration")
            duration_seconds = sum(float(value) * {"ms": .001, "s": 1, "m": 60, "h": 3600}[unit] for value, unit in re.findall(r"([0-9]+(?:\.[0-9]+)?)(ms|s|m|h)", duration))
            if duration_seconds > 300 or (index == 1 and duration_seconds >= 30):
                raise ValueError(f"{filename}: duration exceeds operation/shutdown budget")
    for app in ("web", "console"):
        config = json.loads((root / f"{app}.json").read_text(), object_pairs_hook=json_object)
        exact(config, ["schemaVersion", "appId", "environment", "version", "apiBaseUrl"], app)
        if type(config["schemaVersion"]) is not int or config["schemaVersion"] != 1 or config["appId"] != app or config["environment"] != environment or config["apiBaseUrl"] != "/api" or not isinstance(config["version"], str) or not config["version"].strip():
            raise ValueError(f"invalid public config: {app}")
    for role in ("admin", "migrator", "runtime"):
        path = root / "secrets" / role
        if path.is_symlink() or not path.is_file() or stat.S_IMODE(path.stat().st_mode) != 0o600:
            raise ValueError(f"secret {role} must be a regular file with mode 0600")
        secret = path.read_text().rstrip("\n")
        if len(secret) < 32 or "\n" in secret or "\r" in secret or "\x00" in secret:
            raise ValueError(f"secret {role} must be a single line with at least 32 characters")
    if environment != "dev":
        cert, key = root / "tls/cert.pem", root / "tls/key.pem"
        if key.is_symlink() or stat.S_IMODE(key.stat().st_mode) != 0o600:
            raise ValueError("TLS key must be a regular file with mode 0600")
        def openssl(*args):
            return subprocess.check_output(["openssl", *args], stderr=subprocess.DEVNULL)
        openssl("x509", "-in", str(cert), "-noout", "-checkend", "86400")
        not_before = openssl("x509", "-in", str(cert), "-noout", "-startdate").decode().strip().partition("=")[2]
        if datetime.strptime(not_before, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc) > datetime.now(timezone.utc):
            raise ValueError("TLS certificate is not yet valid")
        host_check = openssl("x509", "-in", str(cert), "-noout", "-checkhost", data["DOMAIN"])
        if b"does match certificate" not in host_check or b"does NOT match" in host_check:
            raise ValueError("TLS certificate hostname does not match DOMAIN")
        if openssl("x509", "-in", str(cert), "-pubkey", "-noout") != openssl("pkey", "-in", str(key), "-pubout"):
            raise ValueError("TLS certificate and private key do not match")
    return data


def render(root, output, environment, uid, gid):
    data = validate(root, environment)
    owner = root.stat()
    output.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(output, 0o755)
    os.chown(output, owner.st_uid, owner.st_gid)
    staged = root / ".runtime-secrets"
    staged.mkdir(mode=0o700, exist_ok=True)
    os.chmod(staged, 0o700)
    os.chown(staged, owner.st_uid, owner.st_gid)
    entries = [(f"db-{role}", root / "secrets" / role, 70, 70) for role in ("admin", "migrator", "runtime")]
    entries += [(f"api-{role}", root / "secrets" / role, uid, gid) for role in ("runtime", "migrator")]
    if environment != "dev":
        entries += [("tls-key.pem", root / "tls/key.pem", 101, 101)]
    for name, source, target_uid, target_gid in entries:
        target = staged / name
        if target.is_symlink():
            raise ValueError("staged secret symlinks are not permitted")
        # Bind mounts retain this inode. Replacing it breaks live mounts on Desktop.
        same_content = target.exists() and target.read_bytes() == source.read_bytes()
        if target.exists() and not same_content and name != "tls-key.pem":
            raise ValueError("credential differs from prepared instance; explicit credential rotation is required")
        if not same_content:
            if name == "tls-key.pem" and target.exists():
                # Keep the old edge's bind-mounted key paired with its old
                # certificate until the explicit controlled recreation.
                replacement = staged / ".tls-key.pending"
                if replacement.exists() or replacement.is_symlink():
                    raise ValueError("pending TLS staging file requires operator inspection")
                with replacement.open("xb") as stream:
                    os.chmod(replacement, 0o400)
                    stream.write(source.read_bytes())
                os.chown(replacement, target_uid, target_gid)
                replacement.replace(target)
            else:
                shutil.copyfile(source, target)
        os.chmod(target, 0o400)
        os.chown(target, target_uid, target_gid)
    template = Path("/tools/nginx.conf.template").read_text()
    tls = ""
    listen = "listen 8080;"
    if environment != "dev":
        listen = "listen 8443 ssl;"
        tls = "ssl_certificate /etc/omega/cert.pem;\n        ssl_certificate_key /run/secrets/tls-key.pem;\n        ssl_protocols TLSv1.2 TLSv1.3;"
        template = template.replace("# REDIRECT_SERVER", "server { listen 8080; server_name " + data["DOMAIN"] + "; return 308 https://" + data["DOMAIN"] + (":" + data["HTTPS_PORT"] if data["HTTPS_PORT"] != "443" else "") + "$request_uri; }")
    template = template.replace("@@LISTEN@@", listen).replace("@@TLS@@", tls).replace("@@DOMAIN@@", data["DOMAIN"]).replace("@@APP_PORT@@", "5173" if environment == "dev" else "8080")
    target = output / "nginx.conf"
    target.write_text(template)
    os.chmod(target, 0o644)
    os.chown(target, owner.st_uid, owner.st_gid)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["init", "validate", "render"])
    parser.add_argument("input", type=Path)
    parser.add_argument("args", nargs="+")
    opts = parser.parse_args()
    if opts.command == "init":
        init(opts.input, opts.args[0])
    elif opts.command == "validate":
        validate(opts.input, opts.args[0])
        print("instance inputs valid")
    else:
        if len(opts.args) not in (2, 4):
            parser.error("render INPUT OUTPUT ENV [API_UID API_GID]")
        render(opts.input, Path(opts.args[0]), opts.args[1], int(opts.args[2]) if len(opts.args) == 4 else 10001, int(opts.args[3]) if len(opts.args) == 4 else 10001)
        print("edge config and role-specific secret mounts ready")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, yaml.YAMLError, subprocess.CalledProcessError) as exc:
        # Never print parser snippets which could contain accidentally embedded secrets.
        print("input operation failed: " + (str(exc) if isinstance(exc, ValueError) else type(exc).__name__), file=sys.stderr)
        sys.exit(2)
