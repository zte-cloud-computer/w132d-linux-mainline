#!/usr/bin/env python3
# SPDX-License-Identifier: (GPL-2.0+ OR MIT)
"""【一次性导入工具，不在构建路径上】从上游板级 DTS 生成去显示版。

板级 DTS 现在由本仓库自己拿着（userpatches/board/rk3528-w132d.dts，已入库），
这个脚本保留下来只为**记录它是怎么来的** —— 出处、做了哪些变换、每处变换的理由。
日常构建不跑它。

上游 zte-cloud-computer/w132d-linux-mainline 已经往我们不跟的方向走了（把 eMMC
从 HS400 降回 52MHz），所以不再作为构建依赖。真要重新同步上游改动时才跑这个。

---

原说明：从上游板级 DTS 生成不含显示路径的 rk3528-w132d.dts。

## 为什么要去掉显示

主线 7.2.2 对 RK3528 显示链**一点支持都没有**（实测：`rockchip_vop2_reg.c`、
`rockchip_drm_vop2.c`、`dw_hdmi-rockchip.c`、`phy-rockchip-inno-hdmi.c` 里
rk3528 命中数全为 0，`rk3528.dtsi` 里也没有 vop/hdmi/hdmiphy 节点）。整条路要靠
上游板级仓库那 25 个 HDMI/VOP2 补丁带，而它们是按 7.1 锚定的，其中 12 个打不到
7.2.2 上。

而 HDMI 在本项目里的定性一直是「实验性：connector 与 CEC 可枚举，尚未验证真实
显示器出图」。所以第一版 Armbian 板级支持不带它 —— 剩下的 eMMC/USB/音频/GPU/
VDEC/红外/LED/ramoops 全都不受影响，补丁数从 31 个降到 4 个。

显示以后作为独立补丁系列补回来，那时也更适合单独提 PR。

## 用法

    patches-src/import-board-dts.py <上游DTS> userpatches/board/rk3528-w132d.dts

每一处删除都断言"确实删掉了、且只删了一处"，漏删或多删立即失败 —— 否则会产出一份
"看着能编、实际引用了不存在节点"的 DTS。
"""
import re
import sys


def cut_toplevel_containing(text, marker, what):
    """删掉**包含 marker 的那个顶层块**（`&xxx {` / `/ {` 起，到配平的 `};` 止）。

    显示相关的 vop / hdmiphy / hdmi 是同一个 `&{/soc}` 块里的兄弟节点，而文件里有
    好几个 `&{/soc} {`，光靠起始行认不出是哪一个 —— 所以从 marker 往回找最近的
    顶层块开头。
    """
    idx = text.find(marker)
    if idx < 0:
        sys.exit(f"❌ {what}：找不到标记 {marker!r}，上游 DTS 变了")
    if text.find(marker, idx + 1) >= 0:
        sys.exit(f"❌ {what}：标记 {marker!r} 出现多次，无法确定删哪个")
    # 往回找列 0 起的顶层块开头
    start = None
    for m in re.finditer(r"^[&/][^\n]*\{[ \t]*$", text[:idx], re.M):
        start = m.start()
    if start is None:
        sys.exit(f"❌ {what}：marker 之前找不到顶层块开头")
    return _cut_from(text, start, what)


def cut_block(text, opener, what):
    """删掉以 opener 那一行开头的整个 `{ ... };` 块（按花括号配平），连同紧邻其上的
    注释块。opener 必须在全文中唯一。"""
    idx = text.find(opener)
    if idx < 0:
        sys.exit(f"❌ {what}：找不到起始行 {opener!r}，上游 DTS 变了")
    if text.find(opener, idx + 1) >= 0:
        sys.exit(f"❌ {what}：起始行 {opener!r} 出现多次，无法确定删哪个")
    return _cut_from(text, idx, what)


def _cut_from(text, idx, what):
    """从 idx 处的块开头出发，配平花括号删到 `};`，并吃掉紧邻其上的注释块。"""
    # 块开始的那个 `{` 是**该行最后一个** `{`。不能取第一个：`&{/soc} {` 里第一个
    # 花括号是路径引用的括号，从它起算会立刻配平完，只切掉一小段。
    eol = text.index("\n", idx)
    i = text.rindex("{", idx, eol)
    depth, j = 0, i
    while j < len(text):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                break
        j += 1
    else:
        sys.exit(f"❌ {what}：花括号不配平")
    end = text.index(";", j) + 1
    while end < len(text) and text[end] == "\n":
        end += 1

    # 向前吃掉紧邻的注释块与空行。
    # 不能用 `/\*.*?\*/\Z` 这种正则：re.S 下最左匹配会从文件顶部那条注释开始，
    # 一路吞到这里的 `*/`，把中间的代码和花括号一起删掉（实测差点就这么产出一份
    # 缺了 model/compatible 的 DTS）。所以显式反向定位。
    start = idx
    prefix = text[:idx].rstrip(" \t\n")
    if prefix.endswith("*/"):
        open_at = prefix.rfind("/*")
        if open_at >= 0 and "*/" not in prefix[open_at + 2:-2]:
            line_start = prefix.rfind("\n", 0, open_at) + 1
            if prefix[line_start:open_at].strip() == "":
                start = line_start
    while start > 0 and text[start - 1] == "\n" and text[start - 2:start - 1] == "\n":
        start -= 1
    return text[:start] + text[end:]


def main():
    if len(sys.argv) != 3:
        raise SystemExit(f"用法: {sys.argv[0]} <上游DTS> <输出DTS>")
    src, dst = sys.argv[1], sys.argv[2]
    text = open(src, encoding="utf-8").read()
    n0 = len(text.splitlines())

    # vop2 的 dt-bindings 只被显示节点用到
    old = "#include <dt-bindings/soc/rockchip,vop2.h>\n"
    if text.count(old) != 1:
        sys.exit(f"❌ vop2 include：期望 1 处，实际 {text.count(old)} 处")
    text = text.replace(old, "")

    text = cut_block(text, "\tdisplay_subsystem: display-subsystem {", "DRM master 节点")
    text = cut_toplevel_containing(text, "vop: vop@ff840000 {", "VOP2 / HDMI / HDMI PHY 整块")
    text = cut_toplevel_containing(text, "hdmi_w132d {", "HDMI HPD 引脚组所在的 &pinctrl 块")

    # ── USB2 PHY 标签改名 ───────────────────────────────────────────────
    # 上游板级 DTS 用的是 `u2phy` / `u2phy_host` / `u2phy_otg` —— 那是它自带的
    # rk3528-usb-dtsi 补丁往 rk3528.dtsi 里加节点时用的名字。
    # 主线 7.2 已经自己带了这些节点（`usb2phy: usb2phy@ffdf0000` 及其两个子端口），
    # 标签叫 `usb2phy` / `usb2phy_host` / `usb2phy_otg`，所以那个补丁不再需要，
    # 但板级 DTS 里的引用必须跟着改名，否则 dtc 直接报 "Label or path not found"。
    n = len(re.findall(r"(?<![A-Za-z0-9_])u2phy", text))
    if n != 4:
        sys.exit(f"❌ USB2 PHY 标签：期望 4 处引用，实际 {n} 处 —— 上游 DTS 变了")
    text = re.sub(r"(?<![A-Za-z0-9_])u2phy", "usb2phy", text)

    # 收尾断言：不能再有任何显示相关的残留引用
    leftovers = []
    for pat, why in [
        (r"\bvop\b", "VOP 引用"),
        (r"hdmi", "HDMI 引用"),
        (r"VOP2", "VOP2 绑定常量"),
        (r"display-subsystem", "DRM master"),
    ]:
        for m in re.finditer(pat, text, re.I):
            line = text[:m.start()].count("\n") + 1
            leftovers.append(f"    第 {line} 行 [{why}]: {text.splitlines()[line-1].strip()[:70]}")
    if leftovers:
        sys.exit("❌ 仍有显示相关残留：\n" + "\n".join(dict.fromkeys(leftovers)))

    # 顶层块的花括号必须配平（cut_block 出错时最先在这里暴露）
    if text.count("{") != text.count("}"):
        sys.exit(f"❌ 花括号不配平：{text.count('{')} 个 {{ vs {text.count('}')} 个 }}")

    # SPDX 必须在第一行（内核约定，也是各类许可证检查的判据），所以说明头插在它后面
    lines = text.split("\n")
    if not lines[0].startswith(("// SPDX-License-Identifier:", "/* SPDX-License-Identifier:")):
        sys.exit(f"❌ 上游 DTS 首行不是 SPDX：{lines[0]!r}")
    header = (
        "/*\n"
        " * 出处：由 patches-src/import-board-dts.py 从上游板级 DTS 一次性导入。\n"
        " * 上游：zte-cloud-computer/w132d-linux-mainline board/rk3528-w132d.dts\n"
        " * 改动：移除显示路径（VOP2 / HDMI / HDMI PHY）——主线 7.2 对 RK3528 显示链\n"
        " *       零支持，相关补丁按 7.1 锚定且多数打不上，见生成器抬头。\n"
        " */\n"
    )
    text = lines[0] + "\n" + header + "\n".join(lines[1:])
    open(dst, "w", encoding="utf-8").write(text)
    n1 = len(text.splitlines())
    print(f"✅ {dst}：{n0} 行 → {n1} 行（去掉 {n0 - n1 + header.count(chr(10))} 行显示相关）")


if __name__ == "__main__":
    main()
