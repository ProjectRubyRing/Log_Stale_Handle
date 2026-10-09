# -*- coding: utf-8 -*-
"""Excel と Markdown を生成する（本文は content.py の 1 か所だけ）

  python build/build_docs.py
    → ECS_EFS_StaleFileHandle_完全解説.xlsx / .md（プロジェクト直下）
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import render_xlsx  # noqa: E402
import render_md    # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, ".."))
BASE = "ECS_EFS_StaleFileHandle_完全解説"


def main():
    x = os.path.join(ROOT, BASE + ".xlsx")
    m = os.path.join(ROOT, BASE + ".md")
    n = render_xlsx.build(x)
    lines = render_md.build(m)
    print("xlsx:", x, "(row heights:", n, ")")
    print("md  :", m, "(%d lines)" % lines)


if __name__ == "__main__":
    main()
