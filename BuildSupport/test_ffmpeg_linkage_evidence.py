"""Offline ARM64 load graph regression tests."""
import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("linkage", Path(__file__).with_name("ffmpeg-linkage-evidence.py"))
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)

class LinkageTests(unittest.TestCase):
    def test_load_commands_preserve_kind(self):
        lines = ["fixture:"]
        for i, kind in enumerate(sorted(ev.LOADS)):
            lines.extend([f"Load command {i}", "      cmd " + kind,
                          "  cmdsize 48", "     name @rpath/libavcodec.dylib (offset 24)"])
        lines.extend(["Load command 5", "      cmd LC_RPATH", "  cmdsize 40",
                      "     path @loader_path (offset 12)", "Load command 6",
                      "      cmd LC_ID_DYLIB", "     name ignored (offset 24)"])
        loads, rpaths = ev.parse_commands("\n".join(lines))
        self.assertEqual({x["kind"] for x in loads}, ev.LOADS)
        self.assertEqual(rpaths, ["@loader_path"])
        with self.assertRaises(ValueError):
            ev.parse_commands("Load command 0\n cmd LC_LOAD_DYLIB\n")
        with self.assertRaises(ValueError):
            ev.parse_commands("not Mach-O")

    def test_plugin_root_and_transitive_consumers(self):
        plugin = ev.PLUGIN_PREFIX + "libgstlibav.dylib"
        def node(component, *targets):
            return {"component": component, "loads": [{"target": t} for t in targets]}
        nodes = {ev.MAIN: node("app", "spice"), ev.SCANNER: node("scanner"),
                 "spice": node("spice"), plugin: node("gstreamer", "avcodec"),
                 "avcodec": node("homebrew:ffmpeg@1", "avutil", "x264"),
                 "avutil": node("homebrew:ffmpeg@1", "avcodec"),
                 "x264": node("homebrew:x264@1")}
        result = ev.summarize(nodes)
        self.assertEqual(result["direct_non_ffmpeg_consumers"], [plugin])
        self.assertEqual(result["ffmpeg_dependencies_outside_ffmpeg"], ["x264"])
        self.assertEqual([r["root"] for r in result["root_closures"] if r["ffmpeg_libraries"]], [plugin])
        nodes[ev.MAIN]["loads"].append({"target": "absent"})
        with self.assertRaises(ValueError):
            ev.summarize(nodes)

if __name__ == "__main__":
    unittest.main()
