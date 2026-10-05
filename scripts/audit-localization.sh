#!/bin/bash
# 审计本地化有没有漏网之鱼。
#
# gen-xcstrings.py 只能看到「提取器认得」的键。有些坏掉的本地化它是看不见的——
# 字符串根本没进目录，运行时查表就会静默地返回英文。这类问题不会崩溃，
# 只是功能悄悄没了，所以必须靠形状检查兜住。
#
# 用法: scripts/audit-localization.sh
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0

# report <标题> <要排除的正则> <要找的坏形状>
# 排除项用来放过「有意保持英文」的地方，以及已经包在 L10n.*(...) 里的。
report() {
  local title="$1" exclude="$2" pattern="$3"
  local hits
  hits=$(grep -rnE "$pattern" Compositor/ --include='*.swift' 2>/dev/null | grep -v '^[^:]*:[0-9]*: *//')
  [ -n "$exclude" ] && hits=$(echo "$hits" | grep -vE "$exclude")
  if [ -n "$hits" ]; then
    echo "✗ $title"
    echo "$hits" | sed 's/^/    /'
    fail=1
  else
    echo "✓ $title"
  fi
}

echo "── 形状检查 ──────────────────────────────────────────────"

# 混合模式菜单曾按 NSMenuItem.title 反查模式，标题一翻译整个菜单就失效。
report "混合模式菜单没有用标题做身份" "" \
  'addItem\(withTitle: [a-zA-Z]*\.rawValue|selectItem\(withTitle: [a-zA-Z]*\.rawValue'

# 快捷键的 group/title 是 UserDefaults 存盘键，也是逻辑判据，必须永远保持英文。
# LevelsSheet 的 name 同样保持英文：它决定数值范围（Gamma 是 0.1–9.99），
# 也是 UI 测试的辅助功能标识符。两处都是有意保留的比较。
report "没有把英文标题当判据" \
  'name == "Gamma"|== "Menus"|== "Text Editing"|== "Canvas & Layers"' \
  '== "(Add Mask|Gamma|Purple|Left|Right|Up|Down|Menus|Text Editing|Canvas & Layers)"|contains\("(Purple|Gamma)"'

report "没有对存储/身份字符串做本地化" "" \
  '(name|group|title|rawValue): *String\(localized:|rawValue *= *String\(localized:'

# rawValue 直接送进显示位置：这类不进目录，查表永远命不中。
# CanvasPreset 的 title 是产品名（4K / iPhone 18 Pro），有��不译。
report "没有把 rawValue 直接当文案显示" 'CanvasPreset|\$0\.title' \
  'Text\([^)]*\.rawValue\)'

# 三元表达式在 Swift 里只能是 String，拿不到 LocalizedStringKey。
# 已包在 L10n.*(...) 里的、以及 ?? 运算符，都不算。
report "三元表达式没有绕过目录" 'L10n\.|\?\?' \
  '(Text|\.help|TextField|Button|Label|Toggle)\([^)]*\? *"'

# AppKit 的 setAccessibilityLabel 收的是 String，不走 LocalizedStringKey；
# SwiftUI 的 .accessibilityLabel("字面量") 走 LocalizedStringKey，是安全的。
# 已经包在 L10n.string(...) 里的也算过了。
report "AppKit 辅助功能标签没有绕过目录" 'L10n\.' \
  'setAccessibilityLabel\("|setAccessibilityLabel\([^)]*\? *"'

# 剪切 + 拼接出来的文案同样不进目录。
report "拼接出来的文案没有绕过目录" 'L10n\.' \
  'setAccessibilityLabel\([^)]*\+ [a-z]|Text\([^)]*\.rawValue\) \+'

# 测试钩子必须跨语言稳定，否则 UI 测试换台机器就找不到控件。
report "测试标识符没有依赖可翻译文本" "" \
  'accessibilityIdentifier\(".*(rawValue|\$\()'

echo
echo "── 目录一致性 ────────────────────────────────────────────"
if [ -f Compositor/Localizable.xcstrings ]; then
  echo "· 重新从源码提取并比对…"
  if python3 scripts/gen-xcstrings.py --check > /tmp/.l10n-check 2>&1; then
    echo "✓ 目录与源码一致，且全部键已翻译"
  else
    echo "✗ 有问题："
    sed 's/^/    /' /tmp/.l10n-check
    fail=1
  fi
else
  echo "✗ Compositor/Localizable.xcstrings 不存在"
  fail=1
fi

echo
[ $fail -eq 0 ] && echo "全部通过" || echo "有失败项（见上）"
exit $fail
