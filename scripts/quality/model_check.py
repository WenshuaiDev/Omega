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

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "infra" / "tools"))
from compose_policy import validate_model as model


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
        if dockerfile.parent.name == "acceptance":
            continue  # This image simulates an operator host, not a released component.
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
                require(re.search(r":v?\d+\.\d+\.\d+(?:[-@]|$)", image), f"{dockerfile}: base image must have exact version: {image}")
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
    elif command == "image-users":
        reports = Path(sys.argv[2])
        users = dict(line.split("\t", 1) for line in (reports / "image-users.tsv").read_text().splitlines())
        for environment in ["test", "prod"]:
            model(environment, json.loads((reports / f"compose-{environment}.json").read_text()), image_users=users)
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
