from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "verify_ffmpeg_lgpl_component.py"
ROOT = SCRIPT.parent.parent
SPEC = importlib.util.spec_from_file_location("verify_ffmpeg_lgpl_component", SCRIPT)
assert SPEC and SPEC.loader
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class FFmpegLGPLComponentTests(unittest.TestCase):
    def test_shipping_config_is_minimal_lgpl_only(self) -> None:
        config = module.load_config(ROOT / "config/ffmpeg-lgpl-component.json")

        self.assertEqual(config["license"], "LGPL-2.1-or-later")
        self.assertIn("--disable-gpl", config["configureArguments"])
        self.assertIn("--disable-nonfree", config["configureArguments"])
        self.assertEqual(config["expectedCapabilities"]["protocols"], ["file"])
        self.assertEqual(config["expectedCapabilities"]["demuxers"], ["wav"])
        self.assertEqual(config["expectedCapabilities"]["encoders"], ["pcm_s16le"])
        self.assertIn("atempo", config["expectedCapabilities"]["filters"])

    def test_config_rejects_enabling_gpl(self) -> None:
        config = json.loads((ROOT / "config/ffmpeg-lgpl-component.json").read_text(encoding="utf-8"))
        config["configureArguments"].append("--enable-gpl")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "config.json"
            path.write_text(json.dumps(config), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "forbidden"):
                module.load_config(path)

    def test_capability_parsers_are_fail_closed(self) -> None:
        protocols = "Supported file protocols:\nInput:\n  file\nOutput:\n  file\n"
        codecs = "Decoders:\n ------\n A....D pcm_s16le\n"
        filters = "Filters:\n  | = Source or sink filter\n .. atempo A->A (null)\n .. abuffer |->A (null)\n"

        self.assertEqual(module.parse_protocols(protocols), {"file"})
        self.assertEqual(module.parse_table(codecs), {"pcm_s16le"})
        self.assertEqual(module.parse_filters(filters), {"atempo", "abuffer"})


if __name__ == "__main__":
    unittest.main()
