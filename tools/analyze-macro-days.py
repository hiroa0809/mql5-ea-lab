# -*- coding: utf-8 -*-
"""マクロ反応日での絞り込みの検証結果を、総当たりCSVから集計し直す。

docs/backtest_results_macro_days.md の数字は **すべてこのスクリプトの出力**。
手で書き写した数字を文書に載せない（2026-08-21。使い捨てのコードで集計して
結果だけ報告していたため、追試できない状態になっていた）。

使い方:  rtk python tools/analyze-macro-days.py
入力:    %APPDATA%\\MetaQuotes\\Terminal\\Common\\Files\\
           p3_m2base_<TF>_USDJPY#_PERIOD_<TF>_opt.csv  … 膠着なし
           p3_m2sqz_<TF>_USDJPY#_PERIOD_<TF>_opt.csv   … 膠着あり
         tools/run-backtest.ps1 で -Tag m2base_<TF> / m2sqz_<TF> として作ったもの。
         作り方は docs/backtest_results_macro_days.md 冒頭。
"""
import csv
import os
import statistics

TFS = [("10分", "M10"), ("15分", "M15"), ("1時間", "H1")]
MACRO = {0: "絞込なし", 1: "反応日のみ", 2: "反応なし日"}
TRIG = {0: "色の変化", 1: "膠着の開始", 2: "どちらでも"}
LOT_PIP_YEN = 100.0        # 0.10 ロットで 1 pip = 100円
COST_ROUND_TRIP = 1.22     # 往復コスト（docs/backtest_design.md）
PASS_NET = 3.01            # 合格ライン グロス3.7 をネットへ換算した目安

DIR = os.path.join(os.environ["APPDATA"], "MetaQuotes", "Terminal", "Common", "Files")
INT_COLS = ("trigger", "squeeze", "squeeze_tf", "lookback", "entry_delay",
            "exit_delay", "lag_mode", "use_close_pos", "slope_mode",
            "macro_use", "trades")


def load(tag, tf):
    path = os.path.join(DIR, "p3_%s_%s_USDJPY#_PERIOD_%s_opt.csv" % (tag, tf, tf))
    if not os.path.exists(path):
        return path, []
    with open(path, newline="", encoding="latin-1") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        for k in INT_COLS:
            r[k] = int(r[k])
        r["net"] = float(r["net"])
        r["pips"] = r["net"] / LOT_PIP_YEN / r["trades"] if r["trades"] else None
    return path, rows


def med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def totals(rows, **flt):
    return [r for r in rows
            if r["scope"] == "total" and r["trades"]
            and all(r[k] == v for k, v in flt.items())]


def hr(title, src, note=""):
    print("\n" + "=" * 78)
    print(title)
    print("  出所: " + src + (("   " + note) if note else ""))
    print("=" * 78)


def main():
    data = {}
    for _, tf in TFS:
        for tag in ("m2base", "m2sqz"):
            data[(tag, tf)] = load(tag, tf)

    hr("0. 入力ファイルと、実際に使われたスパンモデル側の条件",
       "各CSVの lag_mode / use_close_pos / slope_mode 列",
       "（P3 第1段階と揃っているか。0/0/0 が正）")
    print("%-6s %-8s %-10s %8s  %s" % ("時間足", "種別", "②/③/④", "有効パス", "ファイル"))
    for label, tf in TFS:
        for tag, kind in (("m2base", "膠着なし"), ("m2sqz", "膠着あり")):
            path, rows = data[(tag, tf)]
            if not rows:
                print("%-6s %-8s （ファイルなし: %s）" % (label, kind, path))
                continue
            cfg = sorted({(r["lag_mode"], r["use_close_pos"], r["slope_mode"]) for r in rows})
            print("%-6s %-8s %-10s %8d  %s" % (
                label, kind, ",".join("%d/%d/%d" % c for c in cfg),
                len(totals(rows)), os.path.basename(path)))

    hr("1. 膠着なし — マクロ絞り込み別",
       "p3_m2base_<TF>_..._opt.csv の scope=total",
       "（執行4通りをまたいだ中央値）")
    print("%-6s %-12s %8s %11s %13s" % ("時間足", "マクロ", "取引数", "1取引pips", "ネット円"))
    for label, tf in TFS:
        _, rows = data[("m2base", tf)]
        if not rows:
            continue
        for mu in (0, 1, 2):
            g = totals(rows, macro_use=mu)
            print("%-6s %-12s %8s %11.3f %13.0f" % (
                label, MACRO[mu], med([r["trades"] for r in g]),
                med([r["pips"] for r in g]), med([r["net"] for r in g])))
        print()

    hr("2. 膠着あり — マクロ絞り込み別（全パターン）",
       "p3_m2sqz_<TF>_..._opt.csv の scope=total",
       "（全パターンをまたいだ中央値）")
    print("%-6s %-12s %8s %11s %11s" % ("時間足", "マクロ", "取引数", "1取引pips", "黒字の割合"))
    for label, tf in TFS:
        _, rows = data[("m2sqz", tf)]
        if not rows:
            continue
        for mu in (0, 1, 2):
            g = totals(rows, macro_use=mu)
            win = sum(1 for r in g if r["net"] > 0) / len(g) * 100
            print("%-6s %-12s %8s %11.3f %10.0f%%" % (
                label, MACRO[mu], med([r["trades"] for r in g]),
                med([r["pips"] for r in g]), win))
        print()

    hr("3. 膠着あり — 引き金別「反応日のみ − 絞込なし」の差",
       "同上を trigger で層別",
       "（1取引pips 中央値の差。往復コスト %.2f pips 未満は誤差）" % COST_ROUND_TRIP)
    print("%-12s %8s %8s %8s  %s" % ("引き金", "10分", "15分", "1時間", "向き"))
    for tg in (0, 1, 2):
        ds = []
        for _, tf in TFS:
            _, rows = data[("m2sqz", tf)]
            a = med([r["pips"] for r in totals(rows, macro_use=0, trigger=tg)]) if rows else None
            b = med([r["pips"] for r in totals(rows, macro_use=1, trigger=tg)]) if rows else None
            ds.append(b - a if (a is not None and b is not None) else None)
        v = ("3つとも改善" if all(d is not None and d > 0 for d in ds)
             else "3つとも悪化" if all(d is not None and d < 0 for d in ds)
             else "割れている")
        cells = ["%+.2f" % d if d is not None else "—" for d in ds]
        print("%-12s %8s %8s %8s  %s" % (TRIG[tg], cells[0], cells[1], cells[2], v))

    hr("4. 候補 — 膠着=③ケルトナーの内側 / 測る足=4時間足",
       "p3_m2sqz_<TF>_..._opt.csv を squeeze=3, squeeze_tf=2, lookback=6 で絞る",
       "（③は順位の本数が効かないため lookback は1組だけ採用）")
    for label, tf in TFS:
        _, rows = data[("m2sqz", tf)]
        if not rows:
            continue
        print("\n【%s足】" % label)
        print("  %-12s %4s %4s %-12s %8s %11s %11s" % (
            "引き金", "入遅", "決遅", "マクロ", "取引数", "ネット円", "1取引pips"))
        for tg in (1, 2, 0):
            for r in sorted(totals(rows, squeeze=3, squeeze_tf=2, lookback=6, trigger=tg),
                            key=lambda x: (x["entry_delay"], x["exit_delay"], x["macro_use"])):
                mark = "  ←合格ライン超" if (r["macro_use"] == 1 and r["pips"] >= PASS_NET) else ""
                print("  %-12s %4d %4d %-12s %8d %11.0f %11.3f%s" % (
                    TRIG[tg], r["entry_delay"], r["exit_delay"], MACRO[r["macro_use"]],
                    r["trades"], r["net"], r["pips"], mark))
            print()
    print("  合格ライン相当 = ネット %.2f pips（グロス 3.7 を学習期間のコストで戻した目安）" % PASS_NET)

    hr("5. 候補の年別 — 15分足 / ③ケルトナー / 4時間足 / 入遅2・決遅2",
       "同CSVの scope=year",
       "（2022年への依存を見る）")
    _, rows = data[("m2sqz", "M15")]
    if rows:
        for tg in (1, 2):
            print("\n  引き金=%s" % TRIG[tg])
            print("  %-6s %18s %18s %18s" % ("年", MACRO[0], MACRO[1], MACRO[2]))
            years = sorted({r["period"] for r in rows if r["scope"] == "year"})
            acc = {}
            for y in years:
                cells = []
                for mu in (0, 1, 2):
                    hit = [r for r in rows
                           if r["scope"] == "year" and r["period"] == y and r["trigger"] == tg
                           and r["squeeze"] == 3 and r["squeeze_tf"] == 2 and r["lookback"] == 6
                           and r["macro_use"] == mu and r["entry_delay"] == 2 and r["exit_delay"] == 2]
                    if hit:
                        cells.append("%.0f(%d回)" % (hit[0]["net"], hit[0]["trades"]))
                        acc.setdefault(mu, []).append((y, hit[0]["net"], hit[0]["trades"]))
                    else:
                        cells.append("—")
                print("  %-6s %18s %18s %18s" % (y, cells[0], cells[1], cells[2]))
            for mu in (0, 1, 2):
                rec = acc.get(mu, [])
                if not rec:
                    continue
                s = sum(n for _, n, _ in rec)
                t = sum(c for _, _, c in rec)
                s22 = sum(n for y, n, _ in rec if y == "2022")
                t22 = sum(c for y, _, c in rec if y == "2022")
                ex = ((s - s22) / LOT_PIP_YEN / (t - t22)) if (t - t22) else 0.0
                print("    %-10s 合計 %8.0f円/%4d回 (%6.3f pips)   2022年 %3.0f%%   "
                      "2022年を除くと %8.0f円/%4d回 (%6.3f pips)" % (
                          MACRO[mu], s, t, s / LOT_PIP_YEN / t,
                          (s22 / s * 100) if s else 0, s - s22, t - t22, ex))

    hr("6. 「反応日のみ」の取引数分布",
       "p3_m2sqz_<TF>_..._opt.csv の scope=total, macro_use=1",
       "（1取引あたりの数字がどれだけ当てになるか）")
    print("%-6s %12s %16s %24s" % ("時間足", "取引数中央値", "100回未満の割合", "1取引pips 四分位範囲"))
    for label, tf in TFS:
        _, rows = data[("m2sqz", tf)]
        if not rows:
            continue
        g = totals(rows, macro_use=1)
        ps = sorted(r["pips"] for r in g)
        few = sum(1 for r in g if r["trades"] < 100) / len(g) * 100
        print("%-6s %12s %15.0f%% %24s" % (
            label, med([r["trades"] for r in g]), few,
            "%.2f 〜 %.2f" % (ps[len(ps) // 4], ps[len(ps) * 3 // 4])))


if __name__ == "__main__":
    main()
