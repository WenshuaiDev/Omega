"""Shared final Compose policy for manual checks and offline deployment.

All paths are normalized Docker-host paths, compared as data; they need not exist
inside the validating tools container. image_users maps exact image refs to the
imported image Config.User; deployment must supply it to verify inherited users.
"""
import re


def require(ok, message):
    if not ok:
        raise ValueError(message)


def validate_model(environment, data, input_root="/quality-input", materials_root="/quality-source", image_users=None):
    require(environment in {"dev", "test", "prod"}, "unknown environment")
    input_root, materials_root = input_root.rstrip("/"), materials_root.rstrip("/")
    services = data["services"]
    require(set(("api", "db", "web", "console", "edge", "migrate")) <= set(services), "required services absent")
    require(data["networks"]["data"].get("internal") is True, "database network must be internal")
    require(set(services["db"]["networks"]) == {"data"}, "database may only join data network")
    require(set(services["api"]["networks"]) == {"app", "data"}, "API must join app and data networks")
    require(services["api"]["image"] == services["migrate"]["image"], "API and omega must share image")
    for name, service in services.items():
        require(not service.get("privileged"), f"{name}: privileged is forbidden")
        require(not service.get("cap_add"), f"{name}: extra capabilities forbidden")
        require(not service.get("devices") and not service.get("device_cgroup_rules"), f"{name}: host devices forbidden")
        require(service.get("pid") != "host" and service.get("ipc") != "host", f"{name}: host namespaces forbidden")
        require(service.get("network_mode") != "host", f"{name}: host network is forbidden")
        if name != "edge":
            require(not service.get("ports"), f"{name}: only edge publishes ports")
        if name != "deps":
            require(service.get("logging", {}).get("options", {}).get("max-size") and service.get("logging", {}).get("options", {}).get("max-file"), f"{name}: bounded logging required")
        for mount in service.get("volumes", []):
            require("docker.sock" not in str(mount), f"{name}: Docker socket mount forbidden")
        if name not in {"db", "deps"}:
            require(service.get("read_only") is True, f"{name}: read-only root required")
            require("no-new-privileges:true" in service.get("security_opt", []) or "no-new-privileges" in service.get("security_opt", []), f"{name}: no-new-privileges required")
            require("ALL" in service.get("cap_drop", []), f"{name}: capabilities must be dropped")
            require(service.get("healthcheck") or name == "migrate", f"{name}: healthcheck required")
        if environment != "dev":
            require(service.get("platform") == "linux/amd64", f"{name}: formal platform must be linux/amd64")
            require(service.get("pull_policy") == "never", f"{name}: formal image pulls forbidden")
            require(not service.get("build") and not service.get("develop"), f"{name}: formal build/develop forbidden")
            image = service.get("image", "")
            require(":" in image and not image.endswith(":latest"), f"{name}: explicit version tag required")
            if name != "db":
                user = service.get("user")
                if user is None and image_users is not None:
                    require(image in image_users, f"{name}: image USER metadata missing")
                    user = image_users[image]
                if user is not None:
                    uid = str(user).split(":")[0]
                    require(uid not in {"", "0", "root"} and not (uid.isdigit() and int(uid) == 0), f"{name}: root application user forbidden")
            command = str(service.get("command", "")) + str(service.get("entrypoint", ""))
            require(not re.search(r"\b(vite|yarn|npm|go run|devwatch)\b", command), f"{name}: development command forbidden")
            for key, value in service.get("environment", {}).items():
                require(not re.search(r"(PASSWORD|SECRET|TOKEN)(?!.*_FILE$)", key, re.I), f"{name}: plaintext credential environment forbidden")
            for mount in service.get("volumes", []):
                if mount.get("type") != "bind":
                    continue
                source, target = mount["source"], mount["target"]
                require(".." not in source.split("/"), f"{name}: noncanonical source mount")
                require(target.startswith(("/etc/omega/", "/run/secrets/")) or target == "/etc/nginx/nginx.conf" or (name == "db" and target == "/docker-entrypoint-initdb.d/10-omega.sh"), f"{name}: unexpected formal bind target {target}")
                if name in {"web", "console"}:
                    require(not target.startswith("/run/secrets/"), f"{name}: frontend secret mount forbidden")
                require(source.startswith(input_root + "/") or (name == "db" and source == materials_root + "/infra/db/10-omega.sh"), f"{name}: unexpected formal host/source mount {source}")
                require(mount.get("read_only") is True, f"{name}: formal bind must be read-only")
        elif name == "edge":
            require(all(port.get("host_ip") == "127.0.0.1" for port in service.get("ports", [])), "dev ingress must bind loopback")
    print(f"{environment}: final Compose topology and deployment policies passed")

