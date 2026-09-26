"""Container-only source, dependency and final Compose-model checks."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import subprocess

import yaml


def require(ok, message):
    if not ok:
        raise ValueError(message)


def manifests(root):
    names = {"go.mod", "go.sum", "go.work", "go.work.sum", "package.json", "yarn.lock", ".yarnrc.yml"}
    found = {}
    for directory, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in {"node_modules", ".git", ".yarn", ".quality-go", "artifacts", "dist"}]
        for name in files:
            if name in names:
                path = Path(directory) / name
                found[str(path.relative_to(root))] = hashlib.sha256(path.read_bytes()).hexdigest()
    return found


def snapshot(source, listing, destination, uid, gid):
    source, destination = Path(source), Path(destination)
    source_hashes = {}
    for name in set(Path(listing).read_bytes().split(b"\0")):
        if not name:
            continue
        relative = Path(os.fsdecode(name))
        require(not relative.is_absolute() and ".." not in relative.parts, "invalid tracked source path")
        path = source / relative
        # Deleted tracked files stay deleted in the current-code snapshot.
        if not path.exists():
            continue
        require(path.resolve().is_relative_to(source.resolve()), "source symlink escapes repository")
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if path.is_file():
            shutil.copy2(path, target)
            source_hashes[str(relative)] = hashlib.sha256(path.read_bytes()).hexdigest()
    (destination / ".quality-source.json").write_text(json.dumps(source_hashes, sort_keys=True))
    (destination / ".quality-manifests.json").write_text(json.dumps(manifests(destination), sort_keys=True))
    for directory, dirs, files in os.walk(destination):
        os.chown(directory, int(uid), int(gid))
        for name in files:
            os.chown(Path(directory) / name, int(uid), int(gid))
    print("Current nonignored source copied; original tree is mounted read-only.")


def model(environment, data):
    services = data["services"]
    require(set(("api", "db", "web", "console", "edge", "migrate")) <= set(services), "required services absent")
    require(data["networks"]["data"].get("internal") is True, "database network must be internal")
    require(set(services["db"]["networks"]) == {"data"}, "database may only join data network")
    require(set(services["api"]["networks"]) == {"app", "data"}, "API must join app and data networks")
    require(services["api"]["image"] == services["migrate"]["image"], "API and omega must share image")
    for name, service in services.items():
        require(not service.get("privileged"), f"{name}: privileged is forbidden")
        require(service.get("network_mode") != "host", f"{name}: host network is forbidden")
        if name != "edge":
            require(not service.get("ports"), f"{name}: only edge publishes ports")
        if name != "deps":
            require(service.get("logging", {}).get("options", {}).get("max-size") and service.get("logging", {}).get("options", {}).get("max-file"), f"{name}: bounded logging required")
        for mount in service.get("volumes", []):
            require("docker.sock" not in str(mount), f"{name}: Docker socket mount forbidden")
        if name not in {"db", "deps"}:
            require(service.get("read_only") is True, f"{name}: read-only root required")
            require("ALL" in service.get("cap_drop", []), f"{name}: capabilities must be dropped")
            require(service.get("healthcheck") or name == "migrate", f"{name}: healthcheck required")
        if environment != "dev":
            require(service.get("platform") == "linux/amd64", f"{name}: formal platform must be linux/amd64")
            require(service.get("pull_policy") == "never", f"{name}: formal image pulls forbidden")
            require(not service.get("build") and not service.get("develop"), f"{name}: formal build/develop forbidden")
            image = service.get("image", "")
            require(":" in image and not image.endswith(":latest"), f"{name}: explicit version tag required")
            command = str(service.get("command", "")) + str(service.get("entrypoint", ""))
            require(not re.search(r"\b(vite|yarn|npm|go run|devwatch)\b", command), f"{name}: development command forbidden")
            for key, value in service.get("environment", {}).items():
                require(not re.search(r"(PASSWORD|SECRET|TOKEN)$", key, re.I), f"{name}: plaintext credential environment forbidden")
            for mount in service.get("volumes", []):
                if mount.get("type") != "bind":
                    continue
                source = mount["source"]
                require(source.startswith("/quality-input/") or (name == "db" and source == "/quality-source/infra/db/10-omega.sh"), f"{name}: unexpected formal host/source mount {source}")
                require(mount.get("read_only") is True, f"{name}: formal bind must be read-only")
        elif name == "edge":
            require(all(port.get("host_ip") == "127.0.0.1" for port in service.get("ports", [])), "dev ingress must bind loopback")
    print(f"{environment}: final Compose topology and deployment policies passed")


def db_image():
    data = yaml.safe_load(Path("compose.yaml").read_text())
    expression = data["services"]["db"]["image"]
    match = re.fullmatch(r"\$\{OMEGA_DB_IMAGE:-([^}]+)\}", expression)
    require(match is not None, "database default must be an explicit pinned image")
    image = match.group(1)
    require(re.fullmatch(r"postgres:\d+\.\d+-alpine", image) is not None, "PostgreSQL version must be pinned")
    return image


def images():
    root = Path(".")
    for dockerfile in sorted(root.glob("services/*/Dockerfile")):
        require("AS production" in dockerfile.read_text(), f"{dockerfile}: production target required")
        print(f"{dockerfile.parent.name}|{dockerfile}|production|")
    for package in sorted(root.glob("apps/*/package.json")):
        print(f"{package.parent.name}|apps/Dockerfile|production|{package.parent.name}")
    for dockerfile in sorted(root.glob("infra/*/Dockerfile")):
        print(f"{dockerfile.parent.name}|{dockerfile}||")
    # Every explicit service directory needs its own production image.
    for module in root.glob("services/*/go.mod"):
        require((module.parent / "Dockerfile").exists(), f"{module.parent}: missing production Dockerfile")


def toolchain():
    tools = Path("infra/tools/Dockerfile").read_text()
    require(f"FROM python:{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}-" in tools, "Python runtime differs from tools image pin")
    require(f"PyYAML=={yaml.__version__}" in tools, "PyYAML runtime differs from image pin")
    ssl = subprocess.check_output(["openssl", "version"], text=True).split()[1]
    require(f"openssl={ssl}-" in tools, "OpenSSL runtime differs from image pin")
    nginx = set()
    for dockerfile in Path(".").rglob("Dockerfile"):
        if any(part in {"node_modules", ".quality-go", ".yarn"} for part in dockerfile.parts):
            continue
        for line in dockerfile.read_text().splitlines():
            if line.upper().startswith("FROM "):
                image = line.split()[1]
                if image == "scratch" or ":" not in image:
                    continue  # A named earlier stage, not an external base.
                require(re.search(r":\d+\.\d+\.\d+(?:[-@]|$)", image), f"{dockerfile}: base image must have exact version: {image}")
                if image.startswith("nginx:"):
                    nginx.add(image)
    require(len(nginx) == 1, "app and edge Nginx versions differ")
    print(f"tools runtime pins verified: Python {sys.version.split()[0]}, PyYAML {yaml.__version__}, OpenSSL {ssl}")


def main():
    command = sys.argv[1]
    if command == "snapshot":
        snapshot(*sys.argv[2:])
    elif command == "model":
        model(sys.argv[2], json.loads(Path(sys.argv[3]).read_text()))
    elif command == "unchanged":
        require(json.loads(Path(".quality-manifests.json").read_text()) == manifests(Path(".")), "dependency manifests/locks changed or appeared during checks")
        for relative, digest in json.loads(Path(".quality-source.json").read_text()).items():
            path = Path("/source") / relative
            require(path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == digest, f"source changed during checks: {relative}")
        print("All dependency manifests/locks and original source unchanged")
    elif command == "db-image":
        print(db_image())
    elif command == "images":
        images()
    elif command == "toolchain":
        toolchain()
    elif command == "cli-version":
        value = json.loads(Path(sys.argv[2]).read_text())
        require(value["version"] == "quality" and value["commit"] == sys.argv[3], "CLI binary version differs from release labels")
    else:
        raise ValueError("unknown checker command")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError) as error:
        print(f"quality: {error}", file=sys.stderr)
        sys.exit(1)
