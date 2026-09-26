"""Regression checks: final-model safety failures must be rejected."""
import copy
import unittest

from model_check import model


def valid_model():
    services = {}
    for name in ["api", "db", "web", "console", "edge", "migrate"]:
        services[name] = dict(image="omega:quality", platform="linux/amd64", pull_policy="never", read_only=True,
                              cap_drop=["ALL"], healthcheck={"test": ["CMD", "health"]}, networks={"app": {}},
                              logging={"options": {"max-size": "10m", "max-file": "3"}})
    services["api"]["networks"]["data"] = {}
    services["db"]["networks"] = {"data": {}}
    return {"services": services, "networks": {"data": {"internal": True}}}


class FormalModelTests(unittest.TestCase):
    def test_valid_formal_topology(self):
        model("test", valid_model())

    def test_realistic_unsafe_overrides_rejected(self):
        changes = [
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
