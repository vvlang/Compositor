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
import re
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

# 译文与原文相同是正常的这些:单位、颜色模式缩写、算法名、品牌名。
# 它们不是"漏翻",所以从"译文与原文相同"的告警里排除。
VERBATIM_OK = {
    "%@", "%@%%", "%@ × %@ px", "%@ × %@ px · sRGB", "%@°  %@",
    "100%", "px", "pixels", "pixels/inch",
    "RGB", "HSL", "ASCII",
    "Bayer 2 × 2", "Bayer 4 × 4", "Bayer 8 × 8", "Floyd–Steinberg",
    "Atkinson (Classic Mac)", "Scanlines (CRT)", "Halftone Dots", "Halftone Lines",
    "Halftone Diamonds", "Mac Patterns",
    "Compositor", "sRGB · Transparent", "45°",
    # 中文 macOS 上这几个键名本来就是英文，翻译反而不一致
    "Esc", "Return", "Space", "Tab", "Delete",
    # 坐标轴标签，字母本身就通用
    "X", "Y", "°", "R", "G", "B",
}

# 有些标题是运行时用插值拼出来的("Nudge \(direction) 1 px")。它们同时是
# ShortcutDefinition.id 的一部分,所以必须保持英文,也必须逐个展开成完整短语——
# 目录里不可能有一个叫 "Nudge %@ 1 px" 的键,因为运行时会先填进 "Left" 再查表。
LAYER_EFFECT_KINDS = ["Stroke", "Drop Shadow", "Color Overlay", "Inner Shadow", "Outer Glow", "Inner Glow"]
ADJUSTMENT_KINDS = ["Hue/Saturation", "Levels", "Curves", "Exposure", "Gradient Map", "Grain",
                    "Add Noise", "Gaussian Blur", "Motion Blur", "Invert", "Black & White", "Color Balance"]
DIRECTIONS = ["Left", "Right", "Up", "Down"]

# 这些是 UI/ 里的私有 helper，形参类型是 String.LocalizationValue —— 它们不是
# 苹果已知的本地化 API，xcstringstool 认不出来，所以调用点的字面量要单独扫。
# 形参一律是第一个位置参数。
HELPER_CALLS = [
    "control", "slider", "pointSlider", "colorSlider", "familySlider",
    "sharpenSlider", "opticsSlider", "geometrySlider", "calibrationSlider",
    "amount", "wheel", "modifyControl", "sharpenField", "opticsField",
    "dimension", "field", "swatch", "eye", "targetButton",
]

# 传给这些 helper 的第一个字符串字面量，以及 help: 标签后面的那个。
HELPER_LITERAL = re.compile(
    r"\b(" + "|".join(HELPER_CALLS) + r")\s*\(\s*\"((?:[^\"\\\n]|\\.)*)\""
    r"|help:\s*\"((?:[^\"\\\n]|\\.)*)\""
)


# xcstringstool 提取出来的插值占位符是 %arg,但那是给「可移植」用的中间形式:
# 实测 xcstringstool compile 不会把它转成运行时真正查找的形态,而
# String(localized:) 在运行时查的是字面的 %@。substitutions 里的 formatSpecifier
# 只影响译文一侧,不影响键。
#
# 所以目录里的键和译文都必须用 %@。这行是全部 920 个键里最容易静默出错的地方:
# 键对不上时 String(localized:) 不会报错,只是原样返回英文。
PLACEHOLDER = "%arg"
RUNTIME_PLACEHOLDER = "%@"


def normalize_key(key: str) -> str:
    """把可移植的 %arg 换成运行时真正查找的 %@。"""
    return key.replace(PLACEHOLDER, RUNTIME_PLACEHOLDER)


# L10n 的三个取词函数收 String.LocalizationValue,不是 NSLocalizedString 的签名,
# 所以 xcstringstool 的 -s 登记不了它们,里面的字面量必须自己扫。
# 插值一律还原成 %arg —— 本仓库里这些插值全是 String 类型。
L10N_CALL = re.compile(r"L10n\.(?:string|name|text)\s*\(")
# 参数里可能出现的字符串字面量。插值 \(…) 在目录里就是 %arg。
STRING_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
INTERPOLATION = re.compile(r"\\\((?:[^()\\]|\\.|\([^()]*\))*\)")


def _collapse_interpolations(literal: str) -> str:
    """把 Swift 字符串插值 \\(…) 换成 %arg。

    正则处理不了 \\(Double(x).formatted(.precision(.fractionLength(0...2)))) 这种
    多层嵌套，所以这里按括号配对扫描。配对不上（说明是残片）就原样返回。
    """
    out, i = [], 0
    while i < len(literal):
        if literal[i] == "\\" and i + 1 < len(literal) and literal[i + 1] == "(":
            depth, j = 0, i + 1
            while j < len(literal):
                if literal[j] == "(":
                    depth += 1
                elif literal[j] == ")":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            if j >= len(literal):
                return literal
            out.append(PLACEHOLDER)
            i = j + 1
            continue
        out.append(literal[i])
        i += 1
    return "".join(out)


def _balanced_arg(text: str, open_paren: int) -> str | None:
    """从 '(' 处取到配对的 ')'，返回中间的内容。"""
    depth, i, in_str = 0, open_paren, False
    while i < len(text):
        ch = text[i]
        if in_str:
            if ch == "\\":
                i += 2
                continue
            if ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return text[open_paren + 1:i]
        i += 1
    return None


def scan_l10n_calls() -> set[str]:
    """扫出 L10n.string / L10n.name / L10n.text 的参数里出现的所有字符串字面量。

    参数不一定是单个字面量。三元 `L10n.text(cond ? "A" : "B")` 在运行时查的是
    A 和 B **两个键**；早先只按「一个引号对」去抓，拿到的是被截断的条件表达式，
    那两处就一直显示英文 —— 而目录、构建、测试、审计全是绿的，因为键「存在」，
    只是不是运行时真正查的那个。所以这里按括号配对取整个参数，再把里面所有
    字面量都收进来。
    """
    keys: set[str] = set()
    for path in (ROOT / "Compositor").rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        for m in L10N_CALL.finditer(text):
            open_paren = m.end() - 1
            arg = _balanced_arg(text, open_paren)
            if arg is None:
                continue
            for lit in STRING_LITERAL.finditer(arg):
                raw = lit.group(1)
                # 嵌套调用（参数里又调了 L10n.string）会扫出半截残片：
                # 引号配对在嵌套处断掉，剩下的是语法碎片而不是文案。
                if "L10n." in raw or "\\\\(" in raw or not re.search(r"[A-Za-z一-鿿]", raw):
                    continue
                keys.add(_collapse_interpolations(raw))
    return keys


def scan_helper_calls() -> set[str]:
    """扫出传给 helper 的标题字面量，以及形参位置上直接给的 help 文案。"""
    keys: set[str] = set()
    for path in (ROOT / "Compositor").rglob("*.swift"):
        text = path.read_text(encoding="utf-8")
        for line in text.splitlines():
            if line.strip().startswith("//"):
                continue
            for m in HELPER_LITERAL.finditer(line):
                literal = m.group(2) or m.group(3)
                if literal and ("(" not in literal or literal.startswith(".")):
                    keys.add(literal)
    return keys


def derived_keys() -> set[str]:
    """补上那些源码里靠插值拼出来、但提取器拼不出完整键的标题。

    两种情况必须分开：

    - 撤销步骤名走 `beginEdit(_ name: String.LocalizationValue)`，插值在查表之前
      就折叠成了占位符，运行时查的是 `Edit %arg Adjustment` 这种**模板键**，
      不是拼好的整句。
    - 快捷键标题先用英文片段拼成完整的 `title`（它同时是 UserDefaults 里的
      存储键，必须保持英文），之后才拿整句查表，所以这里要的是**具体短语**。
    """
    keys: set[str] = set()
    for verb in ["Add", "Cancel", "Edit", "Copy", "Hide", "Show", "Remove"]:
        keys.add(f"{verb} %arg")
    keys |= {"New %arg Adjustment", "Edit %arg Adjustment"}
    for d in DIRECTIONS:
        keys |= {f"Nudge {d} 1 px", f"Nudge {d} 10 px",
                 f"Move selected pixels {d} 1 px", f"Move selected pixels {d} 10 px"}
    keys |= {f"Opacity digit {n} (type two for exact %)" for n in range(10)}
    return keys


def swift_sources() -> list[str]:
    return sorted(str(p) for p in (ROOT / "Compositor").rglob("*.swift"))


def extract_base_keys() -> set[str]:
    """跑 xcstringstool,返回源码里能自动提取到的键。

    L10n 的三个取词函数是我们自己的包装,苹果不认识,必须用 -s 登记,
    否则里面所有的字面量都会被漏掉(而且不会报错,只是静默查不到表)。
    """
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(
            ["xcrun", "xcstringstool", "extract",
             "--SwiftUI", "--modern-localizable-strings",
             "-s", "L10n.string", "-s", "L10n.name", "-s", "L10n.text",
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
    base = {normalize_key(k) for k in extract_base_keys()}
    curated = load_json("curated.json")        # 提取器看不见的键
    # 带 _ 前缀的是分组注释，不是键
    translations = {k: v for k, v in load_json("translations.json").items()
                    if not k.startswith("_")}

    # curated.json 里带 _ 前缀的是分组注释,不是键
    curated_keys = {normalize_key(k) for k in curated if not k.startswith("_")}
    keys = (base | curated_keys | {normalize_key(k) for k in derived_keys()}
            | {normalize_key(k) for k in scan_l10n_calls()}
            | {normalize_key(k) for k in scan_helper_calls()}) - JUNK_KEYS
    # 译文里的占位符同样要规范化,否则值会带着 %arg 上线
    translations = {normalize_key(k): normalize_key(v) for k, v in translations.items()}
    strings: dict[str, dict] = {}
    for key in sorted(keys):
        # 带占位符的键标成 extracted：符号生成器无法为 %@ 推断 Swift 类型，
        # 标成 manual 会让构建报错。这些键都确实来自源码里的插值字面量。
        # 其余键保持 manual，免得用户在 Xcode 里跑一次「提取本地化字符串」
        # 就把 curated 里的枚举 rawValue 之类（源码中并非字面量）删掉。
        entry: dict = {"extractionState": "extracted" if RUNTIME_PLACEHOLDER in key else "manual"}
        zh = translations.get(key)
        # 未翻译时回退成键本身：state 是 needs_review，但 value 必须存在，
        # 否则 xcstringstool compile 会报 "Missing required key 'value'" 而构建失败。
        entry["localizations"] = {
            TARGET_LANG: {"stringUnit": {"state": "translated" if zh else "needs_review",
                                         "value": zh or key}}
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

    # 两类人眼很难发现的错误：
    # 1. 译文丢了格式符 —— 界面上会显示 "%arg" 或直接崩。
    # 2. 译文和原文一模一样 —— 说明查表根本没命中，只是碰巧没报错。
    spec = re.compile(r"%@|%arg|%%")
    mismatched, selfsame = [], []
    for key, value in translations.items():
        if key not in keys:
            continue
        if sorted(spec.findall(key)) != sorted(spec.findall(value)):
            mismatched.append(key)
        if value == key and re.search(r"[A-Za-z]", key) and key not in VERBATIM_OK:
            selfsame.append(key)
    if mismatched:
        print(f"\n⚠ 格式符不匹配: {len(mismatched)}")
        for k in mismatched[:20]:
            print("   ", repr(k))
    if selfsame:
        print(f"\n⚠ 译文与原文相同（查表可能没命中）: {len(selfsame)}")
        for k in selfsame[:20]:
            print("   ", repr(k))

    return 1 if (untranslated or mismatched or selfsame) else 0


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
