"""Test isolated removal plan with no macOS dependencies."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("experiment", Path(__file__).with_name("ffmpeg-no-libav-experiment.py"))
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)

class RemovalTests(unittest.TestCase):
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
