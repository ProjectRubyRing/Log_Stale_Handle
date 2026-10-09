# -*- coding: utf-8 -*-
"""Markdown 版の生成（content.py から。Excel 版と同じ本文）"""
import unicodedata

import content as C


def esc(s):
    return str(s).replace("|", "\\|").replace("\n", "<br>")


def md_table(headers, rows, align=None):
    out = ["| " + " | ".join(esc(h) for h in headers) + " |"]
    seps = []
    for i in range(len(headers)):
        a = align[i] if align and i < len(align) else 'l'
        seps.append(":---:" if a == 'c' else "---")
    out.append("| " + " | ".join(seps) + " |")
    for r in rows:
        cells = [esc(r[i]) if i < len(r) else "" for i in range(len(headers))]
        out.append("| " + " | ".join(cells) + " |")
    return out


def boxes_to_text(rows):
    lines = []
    for row in rows:
        parts = []
        for kind, text, _w in row:
            t = text.replace("\n", " ")
            if kind in ('box', 'soft'):
                parts.append("[" + t + "]")
            elif kind == 'dark':
                parts.append("[[" + t + "]]")
            elif kind == 'arrow':
                parts.append(t)
            elif kind == 'note':
                parts.append("(" + t + ")")
        if parts:
            lines.append(" ".join(parts))
    return lines


def seq_to_md(lanes, rows):
    out_rows = []
    for kind, cells in rows:
        row = []
        for i, v in enumerate(cells):
            if v and i > 0 and kind == 'x':
                row.append("**✖ " + v + "**")
            elif v and i > 0 and kind == 'k':
                row.append("**" + v + "**")
            else:
                row.append(v)
        out_rows.append(row)
    return md_table(lanes, out_rows) + ["", "（太字 = 要所、✖ = 失敗・エラー）", ""]


def render_blocks(blocks):
    out = []
    for b in blocks:
        k = b[0]
        if k == 'sec':
            out += ["", "### " + b[1], ""]
        elif k == 'sub':
            out += ["", "#### " + b[1], ""]
        elif k == 'p':
            out += [b[1], ""]
        elif k == 'ul':
            out += ["- " + x for x in b[1]] + [""]
        elif k == 'table':
            _, headers, rows, _w, align = b[:5]
            opts = b[5] if len(b) > 5 else {}
            if opts.get('check'):   # Excel では ○/×/－ の選択欄。Markdown では空の箱を見せる
                rows = [["☐" if not r[0] else r[0]] + list(r[1:]) for r in rows]
            out += md_table(headers, rows, align) + [""]
        elif k == 'code':
            _, title, lines = b
            out += ["**" + title + "**", "", "```text"] + lines + ["```", ""]
        elif k == 'callout':
            out += ["> **" + b[1] + "**  ", "> " + b[2].replace("\n", "  \n> "), ""]
        elif k == 'flow':
            for no, t, d in b[1]:
                out.append("%s. **%s** — %s" % (no, t, d.replace("\n", " ")))
            out.append("")
        elif k == 'two':
            _, lt, ll, rt, rl = b
            n = max(len(ll), len(rl))
            rows = [[ll[i] if i < len(ll) else "", rl[i] if i < len(rl) else ""] for i in range(n)]
            out += md_table([lt, rt], rows) + [""]
        elif k == 'boxes':
            out += ["```text"] + boxes_to_text(b[1]) + ["```", ""]
        elif k == 'seq':
            out += seq_to_md(b[1], b[2])
        else:
            raise ValueError(k)
    return out


def anchor_of(name):
    ch = next(c for c in C.CHAPTERS if c['name'] == name)
    h = "%s. %s" % (ch['no'], ch['title'])
    # GitHub のアンカー規則: 小文字化し、文字(L)・結合文字(M)・数字(N)・連結句読点(Pc)・ハイフン以外を削除、空白は -
    keep = []
    for chx in h.lower():
        cat = unicodedata.category(chx)
        if chx == " ":
            keep.append("-")
        elif chx == "-" or cat[0] in "LMN" or cat == "Pc":
            keep.append(chx)
    return "".join(keep)


def build(path):
    out = ["# " + C.TITLE, "", "**" + C.SUBTITLE + "**  ", C.AS_OF, ""]
    out += ["## 00. 要約", ""]
    out += md_table(["質問", "答え"], [list(x) for x in C.COVER_SUMMARY]) + [""]
    out += ["### 目次", ""]
    for name, desc in C.TOC:
        if name == "00_表紙":
            continue
        no, title = name.split("_", 1)
        out.append("- [%s. %s](#%s) — %s" % (no, title.replace("_", " "), anchor_of(name), desc))
    out.append("")
    out += ["### 凡例", ""] + md_table(["表記", "意味"], [list(x) for x in C.LEGEND]) + [""]
    for ch in C.CHAPTERS:
        out += ["", "---", "", "## %s. %s" % (ch['no'], ch['title']), ""]
        if ch.get('lead'):
            out += ["> " + ch['lead'].replace("\n", "  \n> "), ""]
        out += render_blocks(ch['blocks'])
    out += ["", "---", "", "作成: %s ／ Excel 版（Meiryo UI・モノトーン）と同じ本文" % C.CREATED, ""]
    text = "\n".join(out).rstrip() + "\n"
    while "\n\n\n\n" in text:
        text = text.replace("\n\n\n\n", "\n\n\n")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    return len(text.splitlines())
