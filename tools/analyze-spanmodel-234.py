# -*- coding: utf-8 -*-
"""スパンモデル側の②③④（遅行スパン・終値の位置・長期スパンの傾き）の総当たりを集計する。

膠着の設定はユーザー決定の固定値（15分足 / ケルトナーの内側 / 測る足4時間 / 期間21 / 倍率1.5、
執行は入1決1）。振ったのは②③④とエントリーのきっかけの 216 通り。

**順位はすべて合計損益（円）の降順。** 足切りは掛けていない（掛けるなら明示して掛ける）。
②③④をすべて「使わない」にした行が現行設定にあたり、216通りの中に含まれる。

使い方:  rtk python tools/analyze-spanmodel-234.py
入力:    %APPDATA%\\MetaQuotes\\Terminal\\Common\\Files\\p3_sm_m15_USDJPY#_PERIOD_M15_opt.csv
"""
import csv
import os
import statistics

LAG = {0: "使わない", 1: "a 終値を抜く", 2: "b 高値安値を抜く", 3: "c 雲を抜く",
       4: "a+c 終値と雲", 5: "b+c 高安と雲"}
POS = {0: "入れない", 1: "入れる"}
SLOPE = {0: "使わない", 1: "1本前と比べる", 2: "2本前と比べる", 3: "3本前と比べる",
         4: "4本前と比べる", 5: "5本前と比べる"}
TRIG = {0: "色の変化", 1: "膠着の開始", 2: "どちらでも"}
YEARS = ("2018", "2019", "2020", "2021", "2022")
LOT_PIP_YEN = 100.0
PASS_NET = 3.01        # 合格ライン グロス3.7 を学習期間のコストで戻した目安
FEW = 50               # backtest_design.md「50回を切る場合はサンプル不足として参考程度」
RANK_N = 20

DIR = os.path.join(os.environ["APPDATA"], "MetaQuotes", "Terminal", "Common", "Files")
CSV = os.path.join(DIR, "p3_sm_m15_USDJPY#_PERIOD_M15_opt.csv")
BASE = (0, 0, 0)       # 現行設定 = ②③④すべて使わない


def load():
    tot, yr = {}, {}
    with open(CSV, newline="", encoding="latin-1") as f:
        for r in csv.DictReader(f):
            k = (int(r["trigger"]), int(r["lag_mode"]), int(r["use_close_pos"]),
                 int(r["slope_mode"]))
            if r["scope"] == "total":
                n, net = int(r["trades"]), float(r["net"])
                tot[k] = (n, net, net / LOT_PIP_YEN / n if n else None)
            elif r["scope"] == "year":
                yr.setdefault(k, {})[r["period"]] = (int(r["trades"]), float(r["net"]))
    return tot, yr


def name(k):
    return "%-10s ②%-12s ③%-6s ④%-12s" % (TRIG[k[0]], LAG[k[1]], POS[k[2]], SLOPE[k[3]])


def hr(title, note=""):
    print("\n" + "=" * 108)
    print(title)
    if note:
        print("  " + note)
    print("=" * 108)


def row(k, tot, yr, rank=None, tag=""):
    n, net, pips = tot[k]
    y = yr.get(k, {})
    cells = "".join(("%+9.0f" % y[v][1]) if v in y else "        —" for v in YEARS)
    pos = sum(1 for v in YEARS if v in y and y[v][1] > 0)
    print("  %-4s %+9.0f %6d %7.2f %2d/%d %s %s%s" % (
        ("%d位" % rank) if rank else "", net, n, pips, pos, len(y), cells, name(k),
        ("  " + tag) if tag else ""))


def head():
    print("  %-4s %9s %6s %7s %4s %s %s" % (
        "順位", "合計円", "回数", "1回pips", "黒字",
        "".join("%9s" % v for v in YEARS), "引き金 / ②遅行 / ③終値の位置 / ④傾き"))


def main():
    tot, yr = load()
    print("""
順位は【合計損益（円）】の降順。足切りは掛けていない（回数は列で確認する）。
固定: 15分足 / 膠着=ケルトナーの内側 / 測る足=4時間 / 期間21 / 倍率1.5 / 入遅1・決遅1
振った: ②遅行スパン6 × ③終値の位置2 × ④傾き6 × 引き金3 = 216 通り
合格ライン = 1回あたりネット %.2f pips（グロス3.7を学習期間のコストで戻した目安）
「黒字」= 5年のうち合計損益がプラスだった年数。2018年は11月からの2ヶ月ぶん
""" % PASS_NET)

    hr("A. 合計損益の上位%d件" % RANK_N)
    head()
    order = sorted(tot, key=lambda k: -tot[k][1])
    for i, k in enumerate(order[:RANK_N], 1):
        tag = "← 現行設定" if k[1:] == BASE else ""
        if tot[k][0] < FEW:
            tag = (tag + "  ※取引%d回未満" % FEW).strip()
        row(k, tot, yr, i, tag)

    hr("B. 現行設定（②③④すべて使わない）の位置",
       "引き金ごとに、216通りの中で何位か")
    head()
    rk = {k: i + 1 for i, k in enumerate(order)}
    for t in (0, 1, 2):
        k = (t,) + BASE
        row(k, tot, yr, rk[k], "← 現行設定")

    hr("C. ②③④それぞれを単独で見る",
       "他をまたいだ中央値。効いているつまみがあるかを見る（最良の1件では判断しない）")
    for title, idx, names in (("②遅行スパンを何と比べるか", 1, LAG),
                              ("③終値と青スパンの位置関係", 2, POS),
                              ("④長期スパンの傾き", 3, SLOPE)):
        print("\n  【%s】" % title)
        print("    %-14s %10s %8s %9s %10s %10s" % (
            "選択肢", "合計円中央値", "回数中央値", "1回pips", "黒字の割合", "合格の割合"))
        for v in sorted(names):
            g = [k for k in tot if k[idx] == v and tot[k][0]]
            if not g:
                continue
            print("    %-14s %10.0f %8.0f %9.2f %9.0f%% %9.0f%%" % (
                names[v],
                statistics.median(tot[k][1] for k in g),
                statistics.median(tot[k][0] for k in g),
                statistics.median(tot[k][2] for k in g),
                sum(1 for k in g if tot[k][1] > 0) * 100 / len(g),
                sum(1 for k in g if tot[k][2] >= PASS_NET) * 100 / len(g)))

    hr("D. 全体像")
    ns = sorted(tot[k][0] for k in tot)
    print("  取引数: 中央値 %d / 最小 %d / 最大 %d   （%d回未満のパス: %d / %d）" % (
        statistics.median(ns), ns[0], ns[-1], FEW,
        sum(1 for k in tot if tot[k][0] < FEW), len(tot)))
    print("  合計損益がプラス: %d / %d" % (sum(1 for k in tot if tot[k][1] > 0), len(tot)))
    print("  合格ライン以上  : %d / %d" % (
        sum(1 for k in tot if tot[k][2] and tot[k][2] >= PASS_NET), len(tot)))
    print("  5年すべて黒字   : %d / %d" % (
        sum(1 for k in tot if len(yr.get(k, {})) == len(YEARS)
            and all(v[1] > 0 for v in yr[k].values())), len(tot)))
    allpos = [k for k in tot if len(yr.get(k, {})) == len(YEARS)
              and all(v[1] > 0 for v in yr[k].values())]
    if allpos:
        print("\n  5年すべて黒字だったものを合計損益の順に並べる:")
        head()
        for i, k in enumerate(sorted(allpos, key=lambda k: -tot[k][1])[:RANK_N], 1):
            tag = "← 現行設定" if k[1:] == BASE else ""
            if tot[k][0] < FEW:
                tag = (tag + "  ※取引%d回未満" % FEW).strip()
            row(k, tot, yr, i, tag)


if __name__ == "__main__":
    main()
