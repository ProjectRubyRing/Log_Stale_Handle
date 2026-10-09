# -*- coding: utf-8 -*-
"""lab/results/ の検証結果を読み、資料に載せる形にする

  SUMMARY : summary.tsv の行（ケース / NFS / 条件 / 期待 / 観測 / 判定）
  META    : meta.txt の行（実行日時・Docker・カーネル・UBI・Java・Log4j・NFS サーバ）
  excerpt(ケース, 正規表現, 最大行数) : 実行記録から要所の行だけを抜き出す
  ファイルが無い（検証を流していない）ときは空のまま資料を作る。
"""
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.abspath(os.path.join(HERE, "..", "lab", "results"))


def _lines(name):
    path = os.path.join(RES, name)
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [ln.rstrip("\n") for ln in f]


def _summary():
    rows = []
    for i, ln in enumerate(_lines("summary.tsv")):
        if i == 0 or not ln.strip():
            continue
        rows.append(ln.split("\t"))

    # 一部だけ流し直すと行が末尾に付くので、ケース番号（S1, S2, ...）の順に並べ直す（同じ番号の中は元の順）
    def key(item):
        idx, row = item
        m = re.match(r"S(\d+)", row[0])
        return (int(m.group(1)) if m else 999, idx)
    return [r for _, r in sorted(enumerate(rows), key=key)]


SUMMARY = _summary()
META = [ln for ln in _lines("meta.txt") if ln.strip()]
_partial = [ln for ln in META if ln.startswith("partial=")]
if _partial:   # 一部の流し直しは最後の 1 行だけ載せる
    META = [ln for ln in META if not ln.startswith("partial=")] + [_partial[-1]]


def excerpt(case, pattern, limit=12):
    """ケースの実行記録から、正規表現に合う行を順に最大 limit 行返す"""
    rx = re.compile(pattern)
    out = []
    for ln in _lines(case + ".txt"):
        if rx.search(ln):
            out.append(ln.replace("\t", "    "))
            if len(out) >= limit:
                break
    return out or ["（検証結果のファイルがありません: lab/results/%s.txt）" % case]


def verdict_of(case):
    for row in SUMMARY:
        if row and row[0] == case:
            return row[-1]
    return "未実施"


def counts():
    ok = sum(1 for r in SUMMARY if r and r[-1] == "OK")
    return ok, len(SUMMARY)
