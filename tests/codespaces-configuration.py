"""Validate the multi-repo GitHub Codespaces devcontainer configuration across Laplace-Operations and Laplace."""
import json
from pathlib import Path
import unittest

OPS_ROOT = Path(__file__).resolve().parents[1]
WORKSPACE_ROOT = OPS_ROOT.parent


class CodespacesConfigurationTests(unittest.TestCase):
    EXPECTED_REPOS = {
        "SaltyPatron/Laplace",
        "SaltyPatron/Laplace-Native",
        "SaltyPatron/Laplace-postgres",
        "SaltyPatron/Laplace-Engine",
        "SaltyPatron/Laplace-MCP",
        "SaltyPatron/Laplace-UCI",
        "SaltyPatron/Laplace-Operations",
        "SaltyPatron/Laplace-Prototype",
        "SaltyPatron/Laplace-Wiki",
        "SaltyPatron/Laplace-Conventional",
    }

    def check_devcontainer_dir(self, devcontainer_dir: Path):
        config_path = devcontainer_dir / "devcontainer.json"
        dockerfile_path = devcontainer_dir / "Dockerfile"
        bootstrap_path = devcontainer_dir / "bootstrap-codespace.sh"

        self.assertTrue(config_path.is_file(), f"Missing {config_path}")
        self.assertTrue(dockerfile_path.is_file(), f"Missing {dockerfile_path}")
        self.assertTrue(bootstrap_path.is_file(), f"Missing {bootstrap_path}")

        config = json.loads(config_path.read_text(encoding="utf-8"))
        self.assertEqual(config["workspaceFolder"], "/workspaces")
        self.assertEqual(config["containerEnv"]["LAPLACE_DATA"], "/vault/Data")
        self.assertEqual(config["containerEnv"]["LAPLACE_MODELS"], "/vault/Models")
        self.assertEqual(config["containerEnv"]["LAPLACE_PG_DIR"], "/usr/local/pgsql")
        self.assertEqual(config["containerEnv"]["PAGER"], "")
        self.assertEqual(config["containerEnv"]["GIT_PAGER"], "")

        for port in (5187, 5188, 5432, 8080):
            self.assertIn(port, config["forwardPorts"])

        repos = config["customizations"]["codespaces"]["repositories"]
        self.assertEqual(set(repos.keys()), self.EXPECTED_REPOS)
        for repo, perm in repos.items():
            self.assertEqual(perm.get("permissions"), "write-all", f"Missing write-all for {repo}")

        dockerfile = dockerfile_path.read_text(encoding="utf-8")
        for token in (
            "intel-oneapi-compiler-dpcpp-cpp",
            "intel-oneapi-mkl-devel",
            "dotnet-sdk-9.0",
            "release-78.3",
            "REL_18_STABLE",
            "/etc/laplace/machine.env",
        ):
            self.assertIn(token, dockerfile)

        bootstrap = bootstrap_path.read_text(encoding="utf-8")
        self.assertIn("pg_ctl", bootstrap)
        self.assertIn("laplace.code-workspace", bootstrap)

    def test_operations_devcontainer_contract(self):
        self.check_devcontainer_dir(OPS_ROOT / ".devcontainer")

    def test_monorepo_devcontainer_contract_when_present(self):
        mono_devcontainer = WORKSPACE_ROOT / "Laplace" / ".devcontainer"
        if mono_devcontainer.is_dir():
            self.check_devcontainer_dir(mono_devcontainer)


if __name__ == "__main__":
    unittest.main()
