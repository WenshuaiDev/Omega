"""Regression checks: final-model safety failures must be rejected."""
import copy
import unittest

from model_check import model


def valid_model():
    services = {}
    for name in ["api", "db", "web", "console", "edge", "migrate"]:
        services[name] = dict(image="omega:quality", platform="linux/amd64", pull_policy="never", read_only=True,
                              cap_drop=["ALL"], security_opt=["no-new-privileges:true"], healthcheck={"test": ["CMD", "health"]}, networks={"app": {}},
                              logging={"options": {"max-size": "10m", "max-file": "3"}})
    services["api"]["networks"]["data"] = {}
    services["db"]["networks"] = {"data": {}}
    return {"services": services, "networks": {"data": {"internal": True}}}


class FormalModelTests(unittest.TestCase):
    def test_valid_formal_topology(self):
        model("test", valid_model())

    def test_inherited_image_user_is_checked(self):
        from compose_policy import validate_model
        with self.assertRaises(ValueError):
            validate_model("prod", valid_model(), image_users={"omega:quality": ""})
        validate_model("prod", valid_model(), image_users={"omega:quality": "10001:10001"})

    def test_host_paths_are_compared_without_container_existence(self):
        from compose_policy import validate_model
        data = valid_model()
        data["services"]["api"]["volumes"] = [{"type":"bind", "source":"/instances/test/api.yaml", "target":"/etc/omega/app.yaml", "read_only":True}]
        validate_model("test", data, "/instances/test", "/releases/1.0.0/materials")
        with self.assertRaises(ValueError):
            validate_model("test", data, "/instances/prod", "/releases/1.0.0/materials")

    def test_realistic_unsafe_overrides_rejected(self):
        changes = [
            ("api", "user", "root"),
            ("api", "user", "0:10001"),
            ("api", "cap_add", ["SYS_ADMIN"]),
            ("api", "security_opt", []),
            ("api", "devices", ["/dev/sda:/dev/sda"]),
            ("api", "build", {"context": "."}),
            ("api", "volumes", [{"type": "bind", "source": "/quality-source/services", "target": "/workspace", "read_only": True}]),
            ("api", "volumes", [{"type": "bind", "source": "/var/run/docker.sock", "target": "/var/run/docker.sock"}]),
            ("db", "ports", [{"published": "5432", "target": 5432}]),
            ("api", "environment", {"DB_PASSWORD": "accidentally-inline"}),
            ("api", "pull_policy", "always"),
            ("web", "command", ["yarn", "dev"]),
            ("api", "privileged", True),
            ("api", "platform", "linux/arm64"),
            ("api", "image", "omega:latest"),
        ]
        for service, key, value in changes:
            with self.subTest(service=service, key=key):
                data = copy.deepcopy(valid_model())
                data["services"][service][key] = value
                with self.assertRaises(ValueError):
                    model("prod", data)


if __name__ == "__main__":
    unittest.main()
