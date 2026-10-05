#!/usr/bin/env python3
"""生成 Compositor/Localizable.xcstrings。

流程:
  1. 用 xcstringstool 从 Swift 源码提取字符串(和 Xcode 提取的是同一套逻辑,
     键完全精确 —— 弯引号 U+2019、格式符 %@ 都不用我们猜)。
  2. 合并 curated.json —— 那些提取器看不见的键:枚举 rawValue、撤销步骤名、
     AppKit 菜单标题、含变量的三元表达式等。
  3. 填入 scripts/translations.json 里的简体中文译文。
  4. 报告:哪些键还没翻译,哪些译文已经用不上了(打错了)。

用法:
    python3 scripts/gen-xcstrings.py            # 生成目录
    python3 scripts/gen-xcstrings.py --check    # 只报告,不改文件(CI 用)
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Compositor" / "Localizable.xcstrings"
SCRIPTS = ROOT / "scripts"
SOURCE_LANG = "en"
TARGET_LANG = "zh-Hans"

# 提取器会顺带收进来的非文案键(单位符号、占位符)。留着无害,但会污染目录。
JUNK_KEYS = {"", "#", "%"}


def swift_sources() -> list[str]:
    return sorted(str(p) for p in (ROOT / "Compositor").rglob("*.swift"))


def extract_base_keys() -> set[str]:
    """跑 xcstringstool,返回源码里能自动提取到的键。"""
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(
            ["xcrun", "xcstringstool", "extract",
             "--SwiftUI", "--modern-localizable-strings",
             "--output-format", "xcstrings",
             "--output-directory", tmp, *swift_sources()],
            cwd=ROOT, check=True, capture_output=True, text=True,
        )
        extracted = json.loads((Path(tmp) / "Localizable.xcstrings").read_text())
    return set(extracted.get("strings", {}))


def load_json(name: str) -> dict:
    path = SCRIPTS / name
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def build() -> tuple[dict, dict, set[str]]:
    base = extract_base_keys()
    curated = load_json("curated.json")        # 提取器看不见的键
    translations = load_json("translations.json")

    keys = (base | set(curated)) - JUNK_KEYS
    strings: dict[str, dict] = {}
    for key in sorted(keys):
        entry: dict = {"extractionState": "manual"}
        zh = translations.get(key)
        if zh:
            entry["localizations"] = {
                TARGET_LANG: {"stringUnit": {"state": "translated", "value": zh}}
            }
        else:
            # 未翻译时显式标记,避免 Xcode 误以为漏了提取
            entry["localizations"] = {
                TARGET_LANG: {"stringUnit": {"state": "needs_review"}}
            }
        strings[key] = entry

    return {"sourceLanguage": SOURCE_LANG, "strings": strings, "version": "1.0"}, translations, base


def report(catalog: dict, translations: dict, base: set[str]) -> int:
    keys = set(catalog["strings"])
    untranslated = sorted(
        k for k, v in catalog["strings"].items()
        if v["localizations"][TARGET_LANG]["stringUnit"]["state"] != "translated"
    )
    unused = sorted(set(translations) - keys)
    print(f"总键数        : {len(keys)}")
    print(f"  源码可提取  : {len(base - JUNK_KEYS)}")
    print(f"  需手工补录  : {len(keys) - len(base - JUNK_KEYS)}")
    print(f"已翻译        : {len(keys) - len(untranslated)}")
    print(f"未翻译        : {len(untranslated)}")
    if untranslated:
        print("\n未翻译（前 40 条）:")
        for k in untranslated[:40]:
            print("   ", repr(k))
        if len(untranslated) > 40:
            print(f"    … 还有 {len(untranslated) - 40} 条")
    if unused:
        print(f"\n译文中有多余键（可能拼错了）: {len(unused)}")
        for k in unused[:20]:
            print("   ", repr(k))
    return 1 if untranslated else 0


def main() -> int:
    catalog, translations, base = build()
    code = report(catalog, translations, base)
    if "--check" in sys.argv:
        return code
    CATALOG.write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
    )
    print(f"\n已写入 {CATALOG.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
