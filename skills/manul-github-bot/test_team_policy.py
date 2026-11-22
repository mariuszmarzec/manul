import importlib.util
import tempfile
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("team_policy", Path(__file__).with_name("team-policy.py"))
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class TeamPolicyTests(unittest.TestCase):
    def test_legacy_config_defaults_to_github(self):
        self.assertEqual(module.resolve_trackers({}, {"agents": ["orchestrator"]}), ["github_issues"])

    def test_github_is_preferred_when_enabled(self):
        cfg = {"taskSources": [
            {"type": "github_issues", "enabled": True},
            {"type": "todo_remote_mcp", "enabled": True},
        ]}
        self.assertEqual(module.resolve_trackers({}, cfg), ["github_issues"])

    def test_disabled_github_falls_back_to_single_todo_provider(self):
        cfg = {"taskSources": [
            {"type": "github_issues", "enabled": False},
            {"type": "todo_remote_mcp", "enabled": True},
        ]}
        self.assertEqual(module.resolve_trackers({}, cfg), ["todo_remote_mcp"])

    def test_multiple_todo_providers_require_explicit_selection(self):
        cfg = {"taskSources": [
            {"type": "github_issues", "enabled": False},
            {"type": "todo_local_mcp", "enabled": True},
            {"type": "todo_remote_mcp", "enabled": True},
        ]}
        with self.assertRaisesRegex(ValueError, "multiple Todo providers"):
            module.resolve_trackers({}, cfg)

    def test_explicit_multiple_trackers_are_preserved(self):
        cfg = {"taskSources": [
            {"type": "github_issues", "enabled": True},
            {"type": "todo_remote_mcp", "enabled": True},
        ]}
        self.assertEqual(module.resolve_trackers(
            {"trackers": ["github_issues", "todo_remote_mcp"]}, cfg
        ), ["github_issues", "todo_remote_mcp"])

    def test_explicit_disabled_tracker_fails_closed(self):
        cfg = {"taskSources": [{"type": "github_issues", "enabled": False}]}
        with self.assertRaisesRegex(ValueError, "disabled or unavailable"):
            module.resolve_trackers({"trackers": ["github_issues"]}, cfg)

    def test_team_config_defaults_approval_to_human(self):
        with tempfile.TemporaryDirectory() as temp:
            self.assertEqual(module.read_team_config(Path(temp)), {})

    def test_team_config_parses_approval_and_multiple_trackers(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root / ".manul").mkdir()
            (root / ".manul/team.yaml").write_text(
                "version: 1\nprApprovedByMan: false\ntrackers:\n  - github_issues\n  - todo_remote_mcp\n"
            )
            result = module.read_team_config(root)
            self.assertIs(result["prApprovedByMan"], False)
            self.assertEqual(result["trackers"], ["github_issues", "todo_remote_mcp"])

    def test_team_config_rejects_duplicate_and_unknown_keys(self):
        for content, expected in [
            ("version: 1\nversion: 1\n", "duplicate"),
            ("version: 1\nunknown: yes\n", "unsupported"),
            ("version: 1\nprApprovedByMan: maybe\n", "must be true or false"),
        ]:
            with self.subTest(content=content), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                (root / ".manul").mkdir()
                (root / ".manul/team.yaml").write_text(content)
                with self.assertRaisesRegex(ValueError, expected):
                    module.read_team_config(root)


if __name__ == "__main__":
    unittest.main(verbosity=2)
