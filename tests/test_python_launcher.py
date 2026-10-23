"""Hermetic launcher tests; no backup, Docker, credentials or network required."""

import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import BytesIO, StringIO, TextIOWrapper
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from backfort import cli  # noqa: E402


class LauncherTests(unittest.TestCase):
    def test_literal_arguments_and_exec(self):
        arguments = [
            "-c",
            "/tmp/config with spaces.yaml",
            "quick",
            "$(not-a-command)",
            "; literal",
            "--to",
            "/tmp/backup directory",
            "--",
            "-file",
        ]
        with (
            patch.object(sys, "platform", "linux"),
            patch.object(cli.shutil, "which", return_value="/bin/bash"),
            patch.object(cli, "_resource_path", return_value=Path("/package/backfort.sh")),
            patch.object(cli.os, "execv") as execute,
        ):
            self.assertEqual(cli.main(arguments), 0)
        execute.assert_called_once_with(
            "/bin/bash", ["/bin/bash", str(Path("/package/backfort.sh")), *arguments]
        )

    def test_default_argv_and_empty_arguments(self):
        for arguments in ([], ["--version"]):
            with (
                self.subTest(arguments=arguments),
                patch.object(sys, "argv", ["backfort", *arguments]),
                patch.object(sys, "platform", "linux"),
                patch.object(cli.shutil, "which", return_value="/bin/bash"),
                patch.object(cli, "_resource_path", return_value=Path("/package/backfort.sh")),
                patch.object(cli.os, "execv") as execute,
            ):
                self.assertEqual(cli.main(), 0)
            self.assertEqual(execute.call_args.args[1][2:], arguments)

    def test_unsupported_platform(self):
        for platform in ("win32", "darwin", "freebsd"):
            with (
                self.subTest(platform=platform),
                patch.object(sys, "platform", platform),
                redirect_stderr(StringIO()) as output,
                patch.object(cli.os, "execv") as execute,
            ):
                self.assertEqual(cli.main(["--version"]), 2)
                self.assertIn("Linux is required", output.getvalue())
                execute.assert_not_called()

    def test_missing_bash(self):
        with (
            patch.object(sys, "platform", "linux"),
            patch.object(cli.shutil, "which", return_value=None),
            redirect_stderr(StringIO()) as output,
        ):
            self.assertEqual(cli.main(["run"]), 2)
            self.assertIn("Bash 4.3+", output.getvalue())

    def test_missing_engine(self):
        with (
            patch.object(sys, "platform", "linux"),
            patch.object(cli.shutil, "which", return_value="/bin/bash"),
            patch.object(cli, "_resource_path", side_effect=FileNotFoundError),
            redirect_stderr(StringIO()) as output,
        ):
            self.assertEqual(cli.main(["run"]), 2)
            self.assertIn("bundled Bash engine", output.getvalue())

    def test_exec_failure_does_not_leak_arguments(self):
        with (
            patch.object(sys, "platform", "linux"),
            patch.object(cli.shutil, "which", return_value="/bin/bash"),
            patch.object(cli, "_resource_path", return_value=Path("/package/backfort.sh")),
            patch.object(cli.os, "execv", side_effect=PermissionError),
            redirect_stderr(StringIO()) as output,
        ):
            self.assertEqual(cli.main(["a-private-synthetic-argument"]), 2)
            self.assertIn("permissions", output.getvalue())
            self.assertNotIn("a-private-synthetic-argument", output.getvalue())

    def test_print_example_without_linux_or_bash(self):
        with tempfile.TemporaryDirectory() as directory:
            resource = Path(directory) / "config.example.yaml"
            resource.write_text("version: 1\n", encoding="utf-8")
            with (
                patch.object(sys, "platform", "win32"),
                patch.object(cli, "_resource_path", return_value=resource),
                patch.object(cli.shutil, "which") as which,
                redirect_stdout(StringIO()) as output,
            ):
                self.assertEqual(cli.main(["--print-example-config"]), 0)
                self.assertEqual(output.getvalue(), "version: 1\n")
                which.assert_not_called()

    def test_unreadable_example(self):
        with (
            patch.object(cli, "_resource_path", side_effect=PermissionError),
            redirect_stderr(StringIO()) as output,
        ):
            self.assertEqual(cli.main(["--print-example-config"]), 2)
            self.assertIn("example configuration", output.getvalue())

    def test_utf8_example_ignores_console_encoding(self):
        contents = "# Synthetic Unicode: \u2603\nversion: 1\n"
        with (
            patch.object(cli, "_resource_path", return_value=Path("/package/example.yaml")),
            patch.object(Path, "read_text", return_value=contents),
            TextIOWrapper(BytesIO(), encoding="ascii") as output,
            patch.object(sys, "stdout", output),
        ):
            self.assertEqual(cli.main(["--print-example-config"]), 0)
            output.flush()
            self.assertEqual(output.buffer.getvalue(), contents.encode("utf-8"))

    def test_example_read_failure(self):
        with (
            patch.object(cli, "_resource_path", return_value=Path("/package/example.yaml")),
            patch.object(Path, "read_text", side_effect=PermissionError),
            redirect_stderr(StringIO()) as output,
        ):
            self.assertEqual(cli.main(["--print-example-config"]), 2)
            self.assertIn("example configuration", output.getvalue())

    def test_example_flag_is_not_removed_from_engine_arguments(self):
        arguments = ["run", "--print-example-config"]
        with (
            patch.object(sys, "platform", "linux"),
            patch.object(cli.shutil, "which", return_value="/bin/bash"),
            patch.object(cli, "_resource_path", return_value=Path("/package/backfort.sh")),
            patch.object(cli.os, "execv") as execute,
        ):
            cli.main(arguments)
            self.assertEqual(execute.call_args.args[1][2:], arguments)


class ResourceTests(unittest.TestCase):
    def make_package(self, directory, layout):
        package = Path(directory) / layout / "backfort"
        package.mkdir(parents=True)
        return package

    def test_installed_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            package = self.make_package(directory, "site-packages")
            (package / "_data").mkdir()
            script = package / "_data" / "backfort.sh"
            script.write_text("# packaged engine\n", encoding="utf-8")
            with patch.object(cli, "__file__", str(package / "cli.py")):
                self.assertEqual(cli._resource_path("backfort.sh"), script.resolve())

    def test_source_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = self.make_package(directory, "src")
            (root / "pyproject.toml").touch()
            script = root / "backfort.sh"
            script.write_text("# source engine\n", encoding="utf-8")
            with patch.object(cli, "__file__", str(package / "cli.py")):
                self.assertEqual(cli._resource_path("backfort.sh"), script.resolve())

    def test_missing_source_resource(self):
        with tempfile.TemporaryDirectory() as directory:
            package = self.make_package(directory, "src")
            (Path(directory) / "pyproject.toml").touch()
            with (
                patch.object(cli, "__file__", str(package / "cli.py")),
                self.assertRaises(FileNotFoundError),
            ):
                cli._resource_path("backfort.sh")

    def test_incomplete_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            package = self.make_package(directory, "src")
            with (
                patch.object(cli, "__file__", str(package / "cli.py")),
                self.assertRaises(FileNotFoundError),
            ):
                cli._resource_path("backfort.sh")

    def test_missing_installed_resource_never_uses_parent_script(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package = self.make_package(directory, "site-packages")
            (root / "backfort.sh").write_text("# unrelated engine\n", encoding="utf-8")
            (root / "pyproject.toml").touch()
            with (
                patch.object(cli, "__file__", str(package / "cli.py")),
                self.assertRaises(FileNotFoundError),
            ):
                cli._resource_path("backfort.sh")


if __name__ == "__main__":
    unittest.main()
