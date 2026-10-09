# -*- coding: utf-8 -*-
"""
Excel 生成用の共通スタイル部品 (render_xlsx.py から import する)

  フォント : Meiryo UI (全セル + ブック既定の「標準」スタイル)
  配色     : モノトーン (グレースケールのみ / 有彩色なし)
  数式     : 使わない（すべて値）
  列       : B 列から等幅グリッド (GRID_N 列) を敷き、表は結合セルで幅を割り当てる。
             表ごとに列幅を上書きしないので、1 枚のシートに列数の違う表を
             何枚置いても、見出し帯と表の右端が必ず揃う。

  元: ../Docker_HealthCheck_TimeSetting/build/xl_style.py（さらに元は ReadOnly_OpenTelemetry_Problem / ReadOnly_FileSystem）をそのまま流用
"""
import math
import os
import datetime
import unicodedata
from copy import copy
from openpyxl import Workbook
from openpyxl.styles import Font, PatternFill, Alignment, Border, Side
from openpyxl.utils import get_column_letter
from openpyxl.utils.indexed_list import IndexedList
from openpyxl.worksheet.datavalidation import DataValidation

# ---------------------------------------------------------------- 基本設定
FONT = "Meiryo UI"

# モノトーン パレット (ARGB)
WHITE = "FFFFFFFF"
G03 = "FFFAFAFA"
G07 = "FFF2F2F2"
G12 = "FFE6E6E6"
G18 = "FFD9D9D9"
G28 = "FFBFBFBF"
G45 = "FF8C8C8C"
G55 = "FF737373"
G70 = "FF4D4D4D"
G80 = "FF333333"
G90 = "FF1F1F1F"
INK = "FF1A1A1A"
INK2 = "FF595959"

GUTTER = 1    # A 列 = 余白
C0 = 2        # B 列 = 本文開始
SPAN = 24     # グリッドの列数 (B..Y)。見出し帯・本文はこの全幅を使う
GRID_W = 5.8  # グリッド 1 列の幅。24 x 5.8 = 139 単位 = A4 横にほぼ等倍で収まる


def F(size=10, bold=False, color=INK, italic=False):
    return Font(name=FONT, size=size, bold=bold, color=color, italic=italic,
                family=3, charset=128)


def new_workbook():
    """ブック既定の「標準」スタイルを Meiryo UI にした Workbook を返す。

    openpyxl の既定は Calibri (テーマフォント)。そのままだと
      - 値を持たない結合セルの従属側・未使用セルが Calibri になる
      - 利用者があとから入力したセルも Calibri になる
      - 列幅の単位 (既定フォントの '0' の幅) が Calibri 基準になる
    ため、スタイルを 1 つも作らないうちに差し替える。
    """
    wb = Workbook()
    base = F(10, color=None)
    wb._fonts = IndexedList([base])
    wb._named_styles["Normal"].font = copy(base)
    return wb


def alloc(weights, total=SPAN):
    """相対的な重みを、合計 total 列のグリッド幅 (各 1 列以上) に配分する (最大剰余法)"""
    n = len(weights)
    if n > total:
        raise ValueError("列数 %d がグリッド %d 列を超えている" % (n, total))
    wsum = float(sum(weights))
    raw = [total * w / wsum for w in weights]
    spans = [max(1, int(x)) for x in raw]
    while sum(spans) > total:                       # 1 列保証で溢れたぶんを削る
        i = max(range(n), key=lambda k: (spans[k] - raw[k], spans[k]))
        spans[i] -= 1
    order = sorted(range(n), key=lambda k: raw[k] - spans[k], reverse=True)
    k = 0
    while sum(spans) < total:
        spans[order[k % n]] += 1
        k += 1
    return spans


def FILL(argb):
    return PatternFill(fill_type="solid", fgColor=argb)


def _side(argb, style="thin"):
    return Side(style=style, color=argb)


B_BOX = Border(left=_side(G28), right=_side(G28), top=_side(G28), bottom=_side(G28))
B_BOX_M = Border(left=_side(G55, "medium"), right=_side(G55, "medium"),
                 top=_side(G55, "medium"), bottom=_side(G55, "medium"))
B_UNDER = Border(bottom=_side(G45, "medium"))
B_CALLOUT = Border(left=_side(G70, "thick"), top=_side(G28), bottom=_side(G28), right=_side(G28))

AL_CTR = Alignment(horizontal="center", vertical="center", wrap_text=True)


# ---------------------------------------------------------------- 行高の計算
#  Excel の列幅の単位は「既定フォントの '0' の幅」。日本語（全角）は 2 単位を
#  占めるため、文字数ではなく表示幅で折り返し行数を見積もらないと、
#  セルの高さが足りず文字が切れる。
LINE_H = 13.6          # 1 行あたりの高さ（pt）
PAD_H = 6.0            # 上下の余白


ASCII_W = 0.88   # Meiryo UI の半角英数字は平均で列幅単位の約 0.8〜0.9 倍 (等幅換算の 1 だと行高が過大になる)


def disp_width(s):
    """全角 = 2、半角 = ASCII_W として表示幅 (列幅単位) を返す"""
    w = 0.0
    for ch in s:
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F", "A") else ASCII_W
    return w


def col_units(ws, c0, span):
    """結合範囲の合計列幅（単位）"""
    total = 0.0
    for i in range(span):
        d = ws.column_dimensions.get(get_column_letter(c0 + i))
        total += (d.width if d is not None and d.width else 8.43)
    return total


def wrapped_lines(text, units, indent_units=2.0, safety=0.96):
    """折り返しを考慮した行数"""
    if not isinstance(text, str) or not text:
        return 1
    cap = max(4.0, (units - indent_units) * safety)
    n = 0
    for ln in text.split("\n"):
        n += max(1, int(math.ceil(disp_width(ln) / cap)))
    return n


def row_h(lines, line_h=LINE_H, pad=PAD_H, minimum=18.0):
    return max(minimum, lines * line_h + pad)


# --- 行高は「全シート構築後」に再計算する（2 パス方式） ----------------------
#  1 枚のシートに列数の異なる表を複数置くと、後の表が列幅を上書きするため、
#  構築時点の幅で高さを決めると実際の折り返しとずれる。
#  そこで折り返し対象セルを登録しておき、最後に確定した列幅で再計算する。
_HEIGHT_JOBS = []


def reg_h(ws, row, col, span, text, size, indent_units, pad=5.0, minimum=18.0):
    if isinstance(text, str) and text:
        _HEIGHT_JOBS.append((ws, row, col, span, text, size, indent_units, pad, minimum))


def finalize_heights():
    """登録済みセルについて、確定した列幅で行高を再計算する"""
    best = {}
    for (ws, row, col, span, text, size, iu, pad, minimum) in _HEIGHT_JOBS:
        lines = wrapped_lines(text, col_units(ws, col, span), indent_units=iu)
        h = max(minimum, lines * (size * 1.45) + pad)
        key = (id(ws), row)
        if h > best.get(key, (0.0, None))[0]:
            best[key] = (h, ws)
    for key, (h, ws) in best.items():
        ws.row_dimensions[key[1]].height = h
    n = len(_HEIGHT_JOBS)
    del _HEIGHT_JOBS[:]
    return n


def _merge(ws, r, c0=C0, span=SPAN):
    if span > 1:
        ws.merge_cells(start_row=r, start_column=c0, end_row=r, end_column=c0 + span - 1)
    return ws.cell(row=r, column=c0)


def _paint(ws, r, c0, span, fill=None, border=None):
    for i in range(span):
        cc = ws.cell(row=r, column=c0 + i)
        if fill is not None:
            cc.fill = fill
        if border is not None:
            cc.border = border


# ---------------------------------------------------------------- 部品
def sheet_setup(ws, tab=G55, gridlines=False, zoom=100, landscape=True):
    ws.sheet_view.showGridLines = gridlines
    ws.sheet_view.zoomScale = zoom
    ws.sheet_properties.tabColor = tab
    ws.column_dimensions[get_column_letter(GUTTER)].width = 2.2
    for i in range(SPAN):
        ws.column_dimensions[get_column_letter(C0 + i)].width = GRID_W
    ws.column_dimensions[get_column_letter(C0 + SPAN)].width = 2.2   # 右余白
    ws.page_setup.paperSize = ws.PAPERSIZE_A4
    ws.page_setup.orientation = "landscape" if landscape else "portrait"
    ws.page_setup.fitToWidth = 1
    ws.page_setup.fitToHeight = 0
    ws.sheet_properties.pageSetUpPr.fitToPage = True
    ws.page_margins.left = 0.4
    ws.page_margins.right = 0.4
    ws.page_margins.top = 0.55
    ws.page_margins.bottom = 0.55
    ws.oddFooter.center.text = "&A    -  &P / &N  -"
    ws.oddFooter.center.size = 8
    ws.oddFooter.center.font = FONT


def head(ws, r, no, title, lead=None, span=SPAN):
    _paint(ws, r, C0, span, FILL(G80))
    c = _merge(ws, r, span=span)
    c.value = "%s   %s" % (no, title)
    c.font = F(15, True, WHITE)
    c.alignment = Alignment(horizontal="left", vertical="center", indent=1)
    ws.row_dimensions[r].height = 34
    r += 1
    if lead:
        _paint(ws, r, C0, span, FILL(G12))
        c = _merge(ws, r, span=span)
        c.value = lead
        c.font = F(10, False, INK2)
        c.alignment = Alignment(horizontal="left", vertical="center", indent=1, wrap_text=True)
        ws.row_dimensions[r].height = 26
        reg_h(ws, r, C0, span, lead, 10, 3.0, pad=10, minimum=26)
        r += 1
    return r + 1


def sec(ws, r, title, span=SPAN):
    _paint(ws, r, C0, span, FILL(G18), B_UNDER)
    c = _merge(ws, r, span=span)
    c.value = "■ " + title
    c.font = F(11.5, True, INK)
    c.alignment = Alignment(horizontal="left", vertical="center", indent=1)
    ws.row_dimensions[r].height = 24
    return r + 1


def sub(ws, r, title, span=SPAN):
    c = _merge(ws, r, span=span)
    c.value = "▸ " + title
    c.font = F(10.5, True, G70)
    c.alignment = Alignment(horizontal="left", vertical="center", indent=1)
    ws.row_dimensions[r].height = 21
    return r + 1


def body(ws, r, text, span=SPAN, h=None, indent=1, size=10, bold=False, color=INK):
    c = _merge(ws, r, span=span)
    c.value = text
    c.font = F(size, bold, color)
    c.alignment = Alignment(horizontal="left", vertical="top", wrap_text=True, indent=indent)
    if h:
        ws.row_dimensions[r].height = h
    else:
        ws.row_dimensions[r].height = 17
        reg_h(ws, r, C0, span, text, size, indent * 2 + 1, pad=4, minimum=17)
    return r + 1


def gap(ws, r, h=6):
    ws.row_dimensions[r].height = h
    return r + 1


def callout(ws, r, label, text, span=SPAN, fill=G12):
    _paint(ws, r, C0, span, FILL(fill), B_CALLOUT)
    c = _merge(ws, r, span=span)
    c.value = "%s  %s" % (label, text)
    c.font = F(10, False, INK)
    c.alignment = Alignment(horizontal="left", vertical="center", wrap_text=True, indent=1)
    ws.row_dimensions[r].height = 23
    reg_h(ws, r, C0, span, "%s  %s" % (label, text), 10, 3.0, pad=10, minimum=23)
    return r + 1


def _cell(ws, r, c0, span, value, font, fill, border, alignment):
    """span 列ぶんを結合した 1 セルを置く (罫線・塗りは結合範囲の全セルに付ける)"""
    _paint(ws, r, c0, span, fill, border)
    c = _merge(ws, r, c0=c0, span=span)
    c.value = value
    c.font = font
    c.alignment = alignment
    return c


def table(ws, r, headers, rows, widths=None, zebra=True, header_fill=G55,
          align=None, hrow=24, size=9.5, check=False):
    """表。widths は列の相対的な重み (グリッドへ比例配分する)。

    check=True なら先頭列を「○ / × / －」の入力規則つきチェック欄にする。
    """
    n = len(headers)
    spans = alloc(widths if widths else [1] * n)
    starts = [C0 + sum(spans[:i]) for i in range(n)]
    for i, htxt in enumerate(headers):
        _cell(ws, r, starts[i], spans[i], htxt, F(10, True, WHITE), FILL(header_fill), B_BOX, AL_CTR)
        reg_h(ws, r, starts[i], spans[i], htxt, 10, 1.5, pad=8, minimum=hrow)
    ws.row_dimensions[r].height = hrow
    r += 1
    first = r
    for j, row in enumerate(rows):
        f = FILL(G03) if (zebra and j % 2 == 1) else FILL(WHITE)
        for i in range(n):
            v = row[i] if i < len(row) else ""
            a = (align[i] if align and i < len(align) else "l")
            if a == "c":
                al = Alignment(horizontal="center", vertical="center", wrap_text=True)
            else:
                al = Alignment(horizontal="left", vertical="top", wrap_text=True, indent=1)
            _cell(ws, r, starts[i], spans[i], v, F(size), f, B_BOX, al)
            if isinstance(v, str):
                reg_h(ws, r, starts[i], spans[i], v, size, 1.5 if a == "c" else 3.0,
                      pad=5, minimum=19)
        ws.row_dimensions[r].height = 19
        r += 1
    if check and rows:
        dv = DataValidation(type="list", formula1='"○,×,－"', allow_blank=True)
        dv.promptTitle = "チェック"
        dv.prompt = "○ = 済 / × = 未 / － = 対象外"
        dv.showInputMessage = True
        ws.add_data_validation(dv)
        for rr in range(first, r):
            cc = ws.cell(row=rr, column=starts[0])
            cc.font = F(12, True, INK)
            dv.add(cc.coordinate)
    return r


def boxes(ws, r, parts, h=30, bg=None, size=10.5):
    """セルで描く図の 1 行ぶん。プロポーショナルフォントでも崩れない。

    parts: [(kind, text, weight), ...]  weight はグリッドへの相対幅
      kind = box   白地 + 太枠        (主役)
             soft  薄灰地 + 太枠      (相手・外部)
             dark  濃灰地 + 白字      (強調)
             arrow 矢印などの記号     (枠なし・中央)
             note  補足の小さな文字   (枠なし)
             space 何も置かない
    bg: 行全体の背景 (枠の「中」であることを示す)
    """
    spans = alloc([p[2] for p in parts])
    if bg:
        _paint(ws, r, C0, SPAN, FILL(bg))
    col = C0
    for (kind, text, _w), sp in zip(parts, spans):
        if kind in ("box", "soft", "dark"):
            fill = {"box": WHITE, "soft": G07, "dark": G70}[kind]
            font = F(size, True, WHITE if kind == "dark" else INK)
            _cell(ws, r, col, sp, text, font, FILL(fill), B_BOX_M, AL_CTR)
            reg_h(ws, r, col, sp, text, size, 1.5, pad=12, minimum=h)
        elif kind == "arrow":
            _cell(ws, r, col, sp, text, F(12, True, G55), None, None, AL_CTR)
        elif kind == "note":
            _cell(ws, r, col, sp, text, F(9, False, INK2), None, None,
                  Alignment(horizontal="left", vertical="center", wrap_text=True, indent=1))
            reg_h(ws, r, col, sp, text, 9, 3.0, pad=8, minimum=h)
        col += sp
    ws.row_dimensions[r].height = h
    return r + 1


def code(ws, r, lines, span=SPAN, title=None, size=9):
    if title:
        _paint(ws, r, C0, span, FILL(G45))
        c = _merge(ws, r, span=span)
        c.value = "  " + title
        c.font = F(9.5, True, WHITE)
        c.alignment = Alignment(horizontal="left", vertical="center", indent=1)
        ws.row_dimensions[r].height = 20
        r += 1
    top = r
    for ln in lines:
        _paint(ws, r, C0, span, FILL(G07))
        c = _merge(ws, r, span=span)
        c.value = ln if ln else None
        c.font = F(size, False, G90)
        # 長いコマンドは折り返して見せる (セルの値は 1 行のままなので、コピーしてそのまま実行できる)
        c.alignment = Alignment(horizontal="left", vertical="center", wrap_text=True, indent=1)
        ws.row_dimensions[r].height = 15.0
        reg_h(ws, r, C0, span, ln, size, 2.0, pad=2, minimum=15.0)
        r += 1
    for rr in range(top, r):
        for i in range(span):
            cc = ws.cell(row=rr, column=C0 + i)
            cc.border = Border(
                left=_side(G28) if i == 0 else None,
                right=_side(G28) if i == span - 1 else None,
                top=_side(G28) if rr == top else None,
                bottom=_side(G28) if rr == r - 1 else None)
    return r


def flow(ws, r, steps, span=SPAN):
    for k, (no, t, d) in enumerate(steps):
        _paint(ws, r, C0, span, FILL(WHITE), B_BOX_M)
        c = _merge(ws, r, span=span)
        c.value = "  %s   %s" % (no, t)
        c.font = F(10.5, True, INK)
        c.alignment = Alignment(horizontal="left", vertical="center", indent=1)
        ws.row_dimensions[r].height = 22
        r += 1
        _paint(ws, r, C0, span, FILL(G03),
               Border(left=_side(G28), right=_side(G28), bottom=_side(G28)))
        c = _merge(ws, r, span=span)
        c.value = d
        c.font = F(9.5, False, INK2)
        c.alignment = Alignment(horizontal="left", vertical="top", wrap_text=True, indent=2)
        ws.row_dimensions[r].height = 18
        reg_h(ws, r, C0, span, d, 9.5, 5.0, pad=6, minimum=18)
        r += 1
        if k != len(steps) - 1:
            c = _merge(ws, r, span=span)
            c.value = "▼"
            c.font = F(11, True, G45)
            c.alignment = AL_CTR
            ws.row_dimensions[r].height = 18
            r += 1
    return r


def twocol(ws, r, left_title, left_lines, right_title, right_lines, lw=4, rw=3):
    """左右対比ブロック。lw : rw はグリッドへの相対幅"""
    ls, rs = alloc([lw, rw])
    _cell(ws, r, C0, ls, "  " + left_title, F(10, True, WHITE), FILL(G70), None,
          Alignment(horizontal="left", vertical="center", indent=1))
    _cell(ws, r, C0 + ls, rs, "  " + right_title, F(10, True, INK), FILL(G28), None,
          Alignment(horizontal="left", vertical="center", indent=1))
    ws.row_dimensions[r].height = 21
    r += 1
    n = max(len(left_lines), len(right_lines))
    top = r
    for i in range(n):
        lv = left_lines[i] if i < len(left_lines) else None
        rv = right_lines[i] if i < len(right_lines) else None
        _cell(ws, r, C0, ls, lv, F(9.5), FILL(WHITE), None,
              Alignment(horizontal="left", vertical="center", indent=1, wrap_text=True))
        _cell(ws, r, C0 + ls, rs, rv, F(9.5), FILL(G07), None,
              Alignment(horizontal="left", vertical="center", indent=1, wrap_text=True))
        ws.row_dimensions[r].height = 17.0
        reg_h(ws, r, C0, ls, lv, 9.5, 3.0, pad=4, minimum=17)
        reg_h(ws, r, C0 + ls, rs, rv, 9.5, 3.0, pad=4, minimum=17)
        r += 1
    for rr in range(top, r):
        for i in range(SPAN):
            cc = ws.cell(row=rr, column=C0 + i)
            cc.border = Border(
                left=_side(G28) if i in (0, ls) else None,
                right=_side(G28) if i in (ls - 1, SPAN - 1) else None,
                top=_side(G28) if rr == top else None,
                bottom=_side(G28) if rr == r - 1 else None)
    return r
