"""Offline Git source verification regression tests."""
import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("git_source", Path(__file__).with_name("homebrew-git-source-evidence.py"))
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)

class GitSourceTests(unittest.TestCase):
    def test_exact_recipe_revision(self):
        rev = "a" * 40
        formula = '  url "' + ev.REPO + '",\n      revision: "' + rev + '"\n'
        self.assertEqual(ev.pinned_revision(formula), rev)
        for text in (formula + formula, formula.replace(rev, "main"),
                     formula.replace(ev.REPO, "https://example.org/x264.git"),
                     formula.replace("revision:", "tag:")):
            with self.assertRaises(ValueError):
                ev.pinned_revision(text)

    def test_actual_git_tree_and_commit(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            def git(*args):
                return subprocess.check_output(["git", "-C", str(root), *args])
            git("init", "--object-format=sha1")
            git("config", "user.name", "fixture")
            git("config", "user.email", "fixture@example.invalid")
            (root / "file").write_text("one")
            (root / "dir").mkdir()
            (root / "dir/tool").write_text("two")
            (root / "dir/tool").chmod(0o755)
            (root / "link").symlink_to("file")
            git("add", ".")
            git("commit", "-m", "fixture")
            rev = git("rev-parse", "HEAD").decode().strip()
            commit = git("cat-file", "commit", rev)
            data = git("archive", "--format=tar", rev)
            self.assertEqual(ev.verify_git(data, commit, rev),
                             git("rev-parse", "HEAD^{tree}").decode().strip())
            with self.assertRaisesRegex(ValueError, "commit hash"):
                ev.verify_git(data, commit + b"x", rev)
            (root / "file").write_text("changed")
            git("add", ".")
            git("commit", "-m", "second")
            with self.assertRaisesRegex(ValueError, "tree hash"):
                ev.verify_git(git("archive", "--format=tar", "HEAD"), commit, rev)

if __name__ == "__main__":
    unittest.main()
