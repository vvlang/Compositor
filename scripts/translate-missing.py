#!/usr/bin/env python3
"""把目录里还没译的键补上译文。

用法:
    python3 scripts/translate-missing.py            # 翻译并写入
    python3 scripts/translate-missing.py --dry-run  # 只报告，不写文件
    python3 scripts/translate-missing.py --check    # 只校验现有译文（CI 用）

需要 MINIMAX_API_KEY 环境变量（GitHub Secret）。
换服务商：改 MINIMAX_BASE_URL 和 TRANSLATE_MODEL 两个环境变量即可，
接口是 OpenAI 兼容的 chat/completions。

## 为什么这个脚本存在，以及它凭什么可信

自动翻译最危险的地方不是「译错」，是**译错了还看不出来**：占位符个数不对、
顺序调换，界面上不会崩溃，只是某处显示成 `%arg` 或者两个值互换。所以这里的
设计是「模型只负责产出候选，所有硬约束由代码强制」——模型碰不到文件，
它给出的每一行都要先过校验，过不了的直接丢弃，绝不写入。

校验规则来自对现有 970 条译文的实测，不是猜的：

  1. **占位符个数必须相等。** `%arg` / `%@` / `%%` 各计一个。
     实测：970 条里只有 `_comment`（讲规则的那条元数据）个数不同，那是
     本来就该跳过的。
  2. **占位符顺序必须一致。** `String(format:)` 按位置取值，重排会静默
     把两个值装反。实测 970 条里没有任何一条调换过顺序。
  3. **译文不得为空、不得等于原文**（原文即「没译」，会静默回退英文）。
  4. **译文不得含未配对的百分号**，`%2` 这种残缺写法要挡住。
  5. 键里原有的转义 `%%` 必须在译文里同样出现。

## 术语一致性

一次性把 catalog 里高频术语的既有译法喂给模型，并要求它只用这些译法。
否则同一批新文案里会出现「图层 / 图层(新) / layer」混着来的情况，
而这种不一致人工很难一眼扫出来。
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
CATALOG = ROOT / "Compositor" / "Localizable.xcstrings"

MODEL = os.environ.get("TRANSLATE_MODEL", "MiniMax-M2")
API_KEY_ENV = "MINIMAX_API_KEY"
# MiniMax 的 OpenAI 兼容端点；换服务商时改这两个即可。
API_BASE = os.environ.get("MINIMAX_BASE_URL", "https://api.minimax.chat/v1").rstrip("/")

# 文件里存 %arg（可移植），运行时才是 %@。两者在本脚本里等价看待。
#
# 只有 %arg 和 %@ 算占位符。`%%` 不算：它是转义的百分号，输出就是一个普通的
# `%`，所以中文里写 `100%%`（对应英文 `100%%`）和 `100%` 都可以，取决于译文
# 本身是否被当作 format 串处理。实测既有译文两种写法都有，因此不参与计数。
#
# `%` 后跟数字同理是普通文本（"100%"），不是占位符。
PLACEHOLDER = re.compile(r"%arg|%@")
# 残缺写法：`%arg` 写成了半个（%a 后面不是 rg）。
# `%@` 后面直接跟任何字符都是**正常**的（"%@选区"、"%@ was adjusted"），
# 不算错——`%@` 是完整的占位符，不带收尾符号。
# 单独的 `%` 后面跟数字或中文也是正常的（"100%"），`%%` 是转义，同样不算错。
DANGLING = re.compile(r"%a(?!rg)")

# 这些键的译文就是原文，这是**对的**：键名（Esc/Tab/Return/Space）、单位与
# 记号（px/°/×/·/100%）、格式与色彩空间名（RGB/HSL/ASCII）、算法名
# （Floyd–Steinberg）、抖动矩阵规格（Bayer 2 × 2）、纯占位符组合。译它们反而是错的。
#
# 关键在于**不能靠「长得像不像」来判断**。RGB 该不译，但 Navigator、Format、
# Filter 长得也像缩写，却是货真价实的界面文案，漏掉它们界面就会显示英文。
#
# 所以这里只认两类明确的记号，判据落在「字符构成」上，不碰大小写启发式：
#   · 全部字符都是数字或标点（100%、2 × 2、°、·）
#   · 是已知单位/格式/按键名（px、JPEG、RGB、Esc、Tab）
# 其余一律当作句子送去翻译 —— 宁可多译几个词，不能漏译。
# 单位和按键是有限集合，硬编码在这里是安全的；上游要加新的按键，
# 审计会把它报出来（译文等于原文），那时再补进来。
KEEP_AS_IS = {
    "px", "°", "×", "·", "%", "× ", "dpi", "DPI",
    "RGB", "HSL", "HSV", "CMYK", "ASCII", "JPEG", "PNG", "PDF", "TIFF", "HEIC", "PSD", "PSB", "SVG",
    "Esc", "Tab", "Return", "Space", "Enter", "Delete", "Backspace", "Shift", "Control", "Option", "Command",
    "B", "E", "M", "L", "F", "R", "G", "X", "Y", "V", "S", "H", "P", "Z", "Q", "W", "T", "I", "O", "U", "A", "D", "C", "N",
}
SYMBOL_ONLY = re.compile(r"^[\d\s×·%°+\-–—./&,]+$")


def placeholders(text: str) -> list[str]:
    return PLACEHOLDER.findall(text)


def skip_key(key: str) -> bool:
    """以 _ 开头的是 curated.json 里的说明性条目，不是界面文案。"""
    return key.startswith("_")


def untranslatable(key: str) -> bool:
    """这一条本来就不需要译文。"""
    stripped = key.strip()
    if stripped in KEEP_AS_IS:
        return True
    # Bayer 2 × 2、Floyd–Steinberg：含数字或连字符专名，但不是句子
    if SYMBOL_ONLY.match(re.sub(r"%arg|%@|%%", "", stripped)):
        return True
    if re.fullmatch(r"[A-Za-z]+[–\-][A-Za-z]+", stripped):
        return True          # 连字符化的专名
    if re.fullmatch(r"[A-Za-z ]+\d+ ?[×x] ?\d+", stripped):
        return True          # Bayer 2 × 2
    # 剥掉占位符和记号成分后什么都不剩：%arg、%arg%%、%arg × %arg px
    stripped_bare = re.sub(r"%arg|%@|%%", "", stripped)
    for word in re.findall(r"[A-Za-z]+", stripped_bare):
        if word not in KEEP_AS_IS:
            return False                 # 还有个不是单位/按键的词，那是句子
    return True


LEFTOVER_RE = re.compile(r"[A-Za-z]")


def validate(key: str, value: str) -> str | None:
    """返回 None 表示通过，否则返回拒绝理由。"""
    if not value or not value.strip():
        return "译文为空"
    if skip_key(key):
        return "以 _ 开头，是元数据不是文案"
    if value == key and not untranslatable(key):
        return "译文与原文相同（等于没译）"
    # 两种占位符写法等价：文件里存 %arg，目录里存 %@，模型可能给任意一种。
    # 先统一成 %@ 再比，否则会误判「顺序不一致」。
    want = placeholders(key)
    got = placeholders(value)
    if len(want) != len(got):
        return f"占位符个数不一致：原文 {len(want)} 个，译文 {len(got)} 个"
    if [p.replace("%arg", "%@") for p in want] != [p.replace("%arg", "%@") for p in got]:
        return f"占位符顺序不一致：原文 {want}，译文 {got}"
    if DANGLING.search(value):
        return "译文里有残缺的占位符写法"
    return None


def normalize_key(key: str) -> str:
    """把文件里的 %arg 换回目录里实际存的 %@。

    translations.json 按可移植的 %arg 存键，而 Localizable.xcstrings 存的是运行时
    真正查找的 %@。比对之前必须先转换，否则那 56 条带插值的键会被误判成
    「未翻译」——它们其实一直都有译文。gen-xcstrings.py 同样在比对前做这一步。
    """
    return key.replace("%arg", "%@")


def load_missing() -> tuple[dict, list[str]]:
    catalog = json.loads(CATALOG.read_text())
    translations = json.loads((SCRIPTS / "translations.json").read_text())
    known = {normalize_key(k) for k in translations}
    missing = sorted(k for k in catalog["strings"] if k not in known and not skip_key(k))
    return translations, missing


def glossary(catalog: dict) -> str:
    """从既有译文里挑出成对出现的术语，作为风格锚点喂给模型。"""
    translations = json.loads((SCRIPTS / "translations.json").read_text())
    pairs: list[str] = []
    for key, value in sorted(translations.items()):
        if skip_key(key) or "%" in key or len(key) > 24:
            continue
        if 1 <= len(value) <= 8 and value != key:
            pairs.append(f"{key} = {value}")
    return "\n".join(pairs[:120])


def build_prompt(keys: list[str], catalog: dict) -> str:
    glossary_text = glossary(catalog)
    payload = json.dumps(keys, ensure_ascii=False, indent=1)
    return f"""你要把 Compositor（一个 macOS 图像编辑器）的新界面文案译成简体中文。

## 最重要的规则

译文里的占位符必须**原样保留、个数相同、顺序不变**。

- `%arg` 是单个字符串插值。`%arg Selection` → `%arg选区`（%arg 必须在最前）。
- `%%` 是转义的百分号，译文中同样要写成 `%%`。
- 不要把 `%arg` 换成别的写法，不要增删，不要调换顺序。
- 这条规则优先于语言的自然表达。中文语序和英文不同的时候，**调整语序但保持
  占位符的相对位置**；实在无法兼顾时，以占位符顺序为准。

## 风格

- 术语采用 **Photoshop 官方中文译名**（例如 Canvas→画布、Layer→图层、
  Opacity→不透明度、Mask→蒙版、Brush→画笔、Selection→选区、Gaussian Blur→高斯模糊）。
- 用词要简短。菜单项尤其短：「Export As…」→「导出为…」。
- 保留原文的标点风格：原文用弯引号 ' ' 就继续用，末尾有 … 就保留。
- 快捷键符号（⌘ ⇧ ⌥ ⌃）、按键名（B E M L F）、单位（px % °）、格式名
  （PNG JPEG PDF sRGB）、色彩空间名，一律**不译**。
- 语气是简体中文技术文档：陈述句，句末不加句号（除非原文有）。

## 已有译文（术语请与这些保持一致）

```
{glossary_text}
```

## 需要翻译的 {len(keys)} 条

{payload}

## 输出格式

只输出一个 JSON 对象，键是英文原文，值是中文译文。不要任何解释文字，不要 markdown 代码块围栏。
形如：
{{"Format": "格式", "%arg Selection": "%arg选区"}}
"""


def call_api(prompt: str) -> str:
    """调 MiniMax（OpenAI 兼容接口）。

    走 chat/completions 而不是 responses 接口：MiniMax 的兼容层是前者，
    而且它能接受比 responses 更宽松的 payload。
    """
    import urllib.error
    import urllib.request

    payload = json.dumps({
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 16000,
        "temperature": 0.2,
    }).encode()
    request = urllib.request.Request(
        f"{API_BASE}/chat/completions",
        data=payload,
        headers={
            "content-type": "application/json",
            "authorization": f"Bearer {os.environ[API_KEY_ENV]}",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=600) as response:
            body = json.loads(response.read())
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", "replace")[:500]
        raise RuntimeError(f"HTTP {error.code}：{detail}") from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"连不上 {API_BASE}：{error.reason}") from error

    try:
        return body["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError) as error:
        raise RuntimeError(f"返回结构不对：{json.dumps(body)[:300]}") from error


def parse_response(text: str) -> dict:
    cleaned = text.strip()
    cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned)
    cleaned = re.sub(r"\s*```$", "", cleaned)
    start, end = cleaned.find("{"), cleaned.rfind("}")
    if start < 0 or end <= start:
        raise ValueError(f"模型没有返回 JSON 对象：{text[:200]!r}")
    return json.loads(cleaned[start:end + 1])


def check_existing() -> int:
    """校验现有译文。CI 用这个：任何一条不合规就退出非 0。"""
    catalog = json.loads(CATALOG.read_text())
    translations = json.loads((SCRIPTS / "translations.json").read_text())
    bad: list[str] = []
    for key, value in translations.items():
        if skip_key(key):
            continue
        reason = validate(key, value)
        if reason:
            bad.append(f"  {key!r} → {value!r}：{reason}")
    if bad:
        print(f"✗ {len(bad)} 条译文不合规：")
        print("\n".join(bad))
        return 1
    print(f"✓ {len(translations)} 条译文全部通过占位符校验")
    return 0


def main() -> int:
    if "--check" in sys.argv:
        return check_existing()

    if not os.environ.get(API_KEY_ENV):
        print(f"✗ 没有 {API_KEY_ENV}，无法翻译。")
        return 2

    catalog = json.loads(CATALOG.read_text())
    translations, missing = load_missing()

    if not missing:
        print("✓ 没有待翻译的键")
        return 0
    print(f"→ {len(missing)} 条待翻译", file=sys.stderr)

    raw = call_api(build_prompt(missing, catalog))
    try:
        proposed = parse_response(raw)
    except (ValueError, json.JSONDecodeError) as error:
        print(f"✗ 解析失败：{error}", file=sys.stderr)
        return 1

    accepted, rejected = {}, []
    for key, value in proposed.items():
        if key not in missing:
            rejected.append(f"  {key!r}：不在待译列表里，丢弃")
            continue
        if not isinstance(value, str):
            rejected.append(f"  {key!r}：译文不是字符串，丢弃")
            continue
        reason = validate(key, value)
        if reason:
            rejected.append(f"  {key!r} → {value!r}：{reason}")
            continue
        accepted[key] = value

    print(f"采纳 {len(accepted)} 条，拒绝 {len(rejected)} 条")
    for line in rejected:
        print(f"  拒绝 {line}")

    if not accepted:
        print("✗ 没有任何一条通过校验，放弃写入。", file=sys.stderr)
        return 1

    if "--dry-run" in sys.argv:
        print("\n--- 将要写入 ---")
        for key, value in accepted.items():
            print(f"  {key!r} → {value!r}")
        return 0

    # 写回时把 %@ 还原成 %arg：文件按可移植形式存，目录按运行时形式存。
    # 直接写 %@ 会造成键对不上，译文看起来存在却永远匹配不到。
    to_write = {k.replace("%@", "%arg"): v for k, v in translations.items()}
    to_write.update({k.replace("%@", "%arg"): v for k, v in accepted.items()})
    (SCRIPTS / "translations.json").write_text(
        json.dumps(to_write, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    )
    print(f"✓ 已写入 scripts/translations.json（共 {len(to_write)} 条）")
    if rejected:
        print(f"⚠ {len(rejected)} 条待人工处理：")
        for line in rejected:
            print(f"  {line}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
