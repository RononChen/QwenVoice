import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from scripts.check_localizations import (
    LocalizationContractError,
    SUPPORTED_LOCALIZATIONS,
    parse_strings,
    validate_localizations,
    validate_swift_language_list,
)


def quoted(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


class LocalizationContractTests(unittest.TestCase):
    def make_catalogs(self, root: Path, entries: dict[str, str]) -> None:
        for locale in SUPPORTED_LOCALIZATIONS:
            folder = root / f"{locale}.lproj"
            folder.mkdir(parents=True)
            values = entries if locale != "en" else {key: key for key in entries}
            body = "\n".join(f"{quoted(key)} = {quoted(value)};" for key, value in values.items())
            (folder / "Localizable.strings").write_text(body + "\n", encoding="utf-8")

    def test_complete_catalogs_pass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_catalogs(root, {"Ready": "就绪", "%lld clips": "%lld 个音频"})
            self.assertEqual(validate_localizations(root), 2)

    def test_missing_key_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_catalogs(root, {"Ready": "就绪", "Cancel": "取消"})
            path = root / "de.lproj" / "Localizable.strings"
            path.write_text(f'{quoted("Ready")} = {quoted("Bereit")};\n', encoding="utf-8")
            with self.assertRaisesRegex(LocalizationContractError, "key set mismatch"):
                validate_localizations(root)

    def test_placeholder_change_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_catalogs(root, {"%@ of %lld": "%@ / %lld"})
            path = root / "fr.lproj" / "Localizable.strings"
            path.write_text(f'{quoted("%@ of %lld")} = {quoted("%lld")};\n', encoding="utf-8")
            with self.assertRaisesRegex(LocalizationContractError, "format placeholders changed"):
                validate_localizations(root)

    def test_placeholder_reordering_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_catalogs(root, {"%@ of %lld": "%@ / %lld"})
            path = root / "de.lproj" / "Localizable.strings"
            path.write_text(f'{quoted("%@ of %lld")} = {quoted("%lld von %@")};\n', encoding="utf-8")
            with self.assertRaisesRegex(LocalizationContractError, "format placeholders changed"):
                validate_localizations(root)

    def test_protected_product_term_change_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_catalogs(root, {"Restart Vocello": "重启 Vocello"})
            path = root / "ja.lproj" / "Localizable.strings"
            path.write_text(f'{quoted("Restart Vocello")} = {quoted("再起動")};\n', encoding="utf-8")
            with self.assertRaisesRegex(LocalizationContractError, "protected term"):
                validate_localizations(root)

    def test_model_control_artifact_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.make_catalogs(root, {"Tone": "语气"})
            path = root / "ru.lproj" / "Localizable.strings"
            path.write_text(f'{quoted("Tone")} = {quoted("Тон /no_think")};\n', encoding="utf-8")
            with self.assertRaisesRegex(LocalizationContractError, "forbidden model artifact"):
                validate_localizations(root)

    def test_duplicate_key_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Localizable.strings"
            path.write_text('"Ready" = "A";\n"Ready" = "B";\n', encoding="utf-8")
            with self.assertRaisesRegex(LocalizationContractError, "duplicate key"):
                parse_strings(path)

    def test_swift_language_list_must_match_contract_order(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "AppDisplayLanguage.swift"
            cases = "\n".join(
                f'case language{index} = "{locale}"'
                for index, locale in enumerate(SUPPORTED_LOCALIZATIONS)
            )
            path.write_text(cases + "\n", encoding="utf-8")
            validate_swift_language_list(path)
            path.write_text(cases.replace('"pt"', '"pt-BR"') + "\n", encoding="utf-8")
            with self.assertRaisesRegex(LocalizationContractError, "lists differ"):
                validate_swift_language_list(path)


if __name__ == "__main__":
    unittest.main()
