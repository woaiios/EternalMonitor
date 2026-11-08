#!/usr/bin/env python3
"""Generate .strings files from the existing catalog for the xtool preview."""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
LANGUAGES = ["en", "zh-Hans", "ja", "ko", "de", "fr", "es", "pt-BR", "ru", "ar", "hi"]


def quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r') + '"'


def main():
    resources = ROOT / "ios" / "EternalMonitor" / "Resources"
    target = ROOT / "ios" / "xtool-resources"
    for language in LANGUAGES:
        folder = target / f"{language}.lproj"
        folder.mkdir(parents=True, exist_ok=True)
        for catalog in ["Localizable", "InfoPlist"]:
            source = json.loads((resources / f"{catalog}.xcstrings").read_text(encoding="utf-8"))
            lines = ["/* Generated from the existing xcstrings catalog. */"]
            for key, item in sorted(source["strings"].items()):
                value = item.get("localizations", {}).get(language, {}).get("stringUnit", {}).get("value", key)
                lines.append(f"{quote(key)} = {quote(value)};")
            (folder / f"{catalog}.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print("Prepared xtool localization resources from the existing catalogs")


if __name__ == "__main__":
    main()
