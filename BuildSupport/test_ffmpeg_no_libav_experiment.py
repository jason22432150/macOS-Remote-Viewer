"""Test isolated removal plan with no macOS dependencies."""
import importlib.util
import unittest
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("experiment", Path(__file__).with_name("ffmpeg-no-libav-experiment.py"))
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)

class RemovalTests(unittest.TestCase):
    def test_probe_requires_exact_bundled_direct_libraries(self):
        with tempfile.TemporaryDirectory() as raw:
            app = Path(raw) / "Test.app"
            frameworks = app / "Contents/Frameworks"
            frameworks.mkdir(parents=True)
            for name in ev.PROBE_LIBRARIES:
                (frameworks / name).write_bytes(b"fixture")
            self.assertEqual([p.name for p in ev.probe_libraries(app)],
                             list(ev.PROBE_LIBRARIES))
            missing = frameworks / "libgobject-2.0.0.dylib"
            missing.unlink()
            with self.assertRaisesRegex(ValueError, "libgobject"):
                ev.probe_libraries(app)
            external = Path(raw) / "external.dylib"
            external.write_bytes(b"fixture")
            missing.symlink_to(external)
            with self.assertRaisesRegex(ValueError, "unsafe"):
                ev.probe_libraries(app)

    def test_plan_and_unexpected_consumer(self):
        def node(component, *targets):
            return {"component": component, "loads": [{"target": target} for target in targets]}
        nodes = {ev.linkage.MAIN: node("app"), ev.linkage.SCANNER: node("scanner"),
                 ev.LIBAV: node("gstreamer", "avcodec"), "avcodec": node("homebrew:ffmpeg@1", "x264"),
                 "x264": node("homebrew:x264@1")}
        evidence = {"scope": "candidate-test-only", "release_ready": False, "nodes": nodes,
                    "summary": ev.linkage.summarize(nodes)}
        self.assertEqual(ev.removal_plan(evidence), sorted([ev.LIBAV, "avcodec"]))
        nodes[ev.linkage.MAIN]["loads"].append({"target": "avcodec"})
        evidence["summary"] = ev.linkage.summarize(nodes)
        with self.assertRaises(ValueError):
            ev.removal_plan(evidence)

if __name__ == "__main__":
    unittest.main()
