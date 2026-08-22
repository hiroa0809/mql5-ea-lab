# -*- coding: utf-8 -*-
"""③ケルトナーの内側について、期間と倍率の総当たり結果を集計する。

docs/backtest_results_kc_grid.md の数字は **すべてこのスクリプトの出力**。
手で書き写した数字を文書に載せない（analyze-macro-days.py と同じ理由）。

判定式は 2σ < 倍率 × ATR（Squeeze.mqh の SQZ_KeltnerRatio）。期間は σ と ATR の
両方に使われるため分けて指定できない。動かせるつまみはこの2つだけ。

使い方:  rtk python tools/analyze-kc-grid.py
入力:    %APPDATA%\\MetaQuotes\\Terminal\\Common\\Files\\
           p3_kc_<tf>_USDJPY#_PERIOD_<TF>_opt.csv     … ケルトナーの総当たり
           p3_kcbase_<tf>_USDJPY#_PERIOD_<TF>_opt.csv … 膠着なしの比較相手
         作り方は docs/backtest_results_kc_grid.md 冒頭。
"""
import csv
import os
import statistics

TFS = [("5分", "M5"), ("10分", "M10"), ("15分", "M15"), ("1時間", "H1")]
TRIG = {0: "色の変化", 1: "膠着の開始", 2: "どちらでも"}
SQZTF = {0: "同じ足", 1: "1時間足", 2: "4時間足", 3: "日足"}
LOT_PIP_YEN = 100.0        # 0.10 ロットで 1 pip = 100円
PASS_NET = 3.01            # 合格ライン グロス3.7 をネットへ換算した目安
PREV = (21, 1.50)          # P3 第1段階で固定していた（期間, 倍率）
FEW_TRADES = 50            # これを切る数字は参考程度（backtest_design.md）
ENOUGH = 100               # 足切り。50 では「参考程度」がそのまま残るため一段上げる
RANK_N = 20                # 合計損益の順位表に出す件数
YEARS = ("2018", "2019", "2020", "2021", "2022")   # 2018 は11月からの2ヶ月ぶん

DIR = os.path.join(os.environ["APPDATA"], "MetaQuotes", "Terminal", "Common", "Files")
INT_COLS = ("trigger", "squeeze", "squeeze_tf", "lookback", "entry_delay",
            "exit_delay", "lag_mode", "use_close_pos", "slope_mode",
            "macro_use", "trades", "sqz_period")


def load(tag, tf):
    """scope=total の行だけ返す。年別・月別は本書では使わないため捨てる。"""
    path = os.path.join(DIR, "p3_%s_%s_USDJPY#_PERIOD_%s_opt.csv" % (tag, tf.lower(), tf))
    if not os.path.exists(path):
        return path, None
    out = []
    with open(path, newline="", encoding="latin-1") as f:
        for r in csv.DictReader(f):
            if r["scope"] != "total":
                continue
            for k in INT_COLS:
                r[k] = int(r[k])
            r["net"] = float(r["net"])
            r["kc"] = float(r["sqz_kcmult"])
            r["pips"] = r["net"] / LOT_PIP_YEN / r["trades"] if r["trades"] else None
            out.append(r)
    return path, out


def load_years(tag, tf):
    """パス番号 -> 年 -> 合計損益。順位表に年別の列を並べるため。"""
    path = os.path.join(DIR, "p3_%s_%s_USDJPY#_PERIOD_%s_opt.csv" % (tag, tf.lower(), tf))
    if not os.path.exists(path):
        return {}
    out = {}
    with open(path, newline="", encoding="latin-1") as f:
        for r in csv.DictReader(f):
            if r["scope"] == "year":
                out.setdefault(r["pass"], {})[r["period"]] = (int(r["trades"]), float(r["net"]))
    return out


def med(xs):
    xs = [x for x in xs if x is not None]
    return statistics.median(xs) if xs else None


def alive(rows):
    """取引のあった行。取引ゼロは 1取引pips が出せないため除く。"""
    return [r for r in rows if r["trades"]]


def hr(title, src, note=""):
    print("\n" + "=" * 96)
    print(title)
    print("  出所: " + src + (("   " + note) if note else ""))
    print("=" * 96)


def make_grid(rows, key):
    """(期間, 倍率) ごとに key を集めた中央値の表を返す。"""
    bucket = {}
    for r in rows:
        bucket.setdefault((r["sqz_period"], r["kc"]), []).append(key(r))
    return {k: med(v) for k, v in bucket.items()}


def axes(rows):
    return (sorted({r["sqz_period"] for r in rows}),
            sorted({r["kc"] for r in rows}))


def show_grid(periods, mults, cells, fmt="%6.2f", blank="     —"):
    print("  期間\\倍率 " + "".join("%7s" % ("%.2f" % m) for m in mults))
    for p in periods:
        line = "  %8d " % p
        for m in mults:
            v = cells.get((p, m))
            line += (fmt % v) if v is not None else blank
        print(line)


def ranking(rows, n=RANK_N):
    """合計損益の多い順に並べる。加工しない生の順位表。"""
    return sorted(rows, key=lambda r: -r["net"])[:n]


def main():
    data, base = {}, {}
    for _, tf in TFS:
        data[tf] = load("kc", tf)
        base[tf] = load("kcbase", tf)

    def rank_table(rows, years, title, note=""):
        """合計損益の順位表。横に 2018〜2022 の年別損益を並べる。"""
        top = ranking(rows)
        print("\n  %s%s" % (title, ("  " + note) if note else ""))
        print("    %-3s %10s %6s %7s %4s %s %-7s %-10s %s" % (
            "位", "合計円", "回数", "1回pips", "黒字", "".join("%9s" % y for y in YEARS),
            "測る足", "引き金", "期間/倍率/入決"))
        for i, r in enumerate(top, 1):
            y = years.get(r["pass"], {})
            cells = "".join(("%+9.0f" % y[k][1]) if k in y else "        —" for k in YEARS)
            pos = sum(1 for k in YEARS if k in y and y[k][1] > 0)
            print("    %-3d %+10.0f %6d %7.2f %2d/%d %s %-7s %-10s %d/%.2f/%d%d%s" % (
                i, r["net"], r["trades"], r["pips"], pos, len(y), cells,
                SQZTF[r["squeeze_tf"]], TRIG[r["trigger"]],
                r["sqz_period"], r["kc"], r["entry_delay"], r["exit_delay"],
                "" if r["pips"] >= PASS_NET else "  未達"))
        return top

    hr("A. 合計損益の上位%d件（加工なし）— 横は年別の合計損益" % RANK_N,
       "各CSVの scope=total を net で降順。年別は同じパスの scope=year",
       "（足切りも中央値も掛けていない。2018年は11月からの2ヶ月ぶん）")
    for label, tf in TFS:
        _, rows = data[tf]
        if not rows:
            continue
        years = load_years("kc", tf)
        _, brows = base[tf]
        if brows:
            b = sorted(alive(brows), key=lambda r: -r["net"])[0]
            byr = load_years("kcbase", tf).get(b["pass"], {})
            print("\n  【%s足】 膠着なしの最良: %+.0f円 / %d回 / %.2f pips   年別 %s" % (
                label, b["net"], b["trades"], b["pips"],
                " ".join("%s:%+.0f" % (k, byr[k][1]) for k in YEARS if k in byr)))
        else:
            print("\n  【%s足】" % label)
        top = rank_table(alive(rows), years, "合計損益の順（上位%d件）" % RANK_N)
        few = sum(1 for r in top if r["trades"] < FEW_TRADES)
        ps = sum(1 for r in top if r["pips"] >= PASS_NET)
        allpos = sum(1 for r in top
                     if len(years.get(r["pass"], {})) == len(YEARS)
                     and all(v[1] > 0 for v in years[r["pass"]].values()))
        print("    上位%d件: 取引%d回未満 %d件 / 合格ライン以上 %d件 / 5年すべて黒字 %d件" % (
            len(top), FEW_TRADES, few, ps, allpos))
        ok = [r for r in alive(rows)
              if len(years.get(r["pass"], {})) == len(YEARS)
              and all(v[1] > 0 for v in years[r["pass"]].values())]
        print("    全%d通りのうち 5年すべて黒字は %d通り（合格ライン以上に限ると %d通り）" % (
            len(alive(rows)), len(ok), sum(1 for r in ok if r["pips"] >= PASS_NET)))
        if ok:
            rank_table(ok, years, "うち 5年すべて黒字だけを並べ直す（上位%d件）" % RANK_N)

    hr("0. 入力ファイルと、実際に使われた条件",
       "各CSVの lag_mode / use_close_pos / slope_mode 列",
       "（P3 第1段階と揃っているか。0/0/0 が正）")
    print("  %-6s %-10s %8s %8s %10s  %s" % (
        "時間足", "②/③/④", "総パス", "取引あり", "取引ゼロ", "ファイル"))
    for label, tf in TFS:
        path, rows = data[tf]
        if not rows:
            print("  %-6s （ファイルなし: %s）" % (label, os.path.basename(path)))
            continue
        cfg = sorted({(r["lag_mode"], r["use_close_pos"], r["slope_mode"]) for r in rows})
        ok = alive(rows)
        print("  %-6s %-10s %8d %8d %10d  %s" % (
            label, ",".join("%d/%d/%d" % c for c in cfg),
            len(rows), len(ok), len(rows) - len(ok), os.path.basename(path)))

    hr("1. 配線の確認 — 倍率を上げると膠着は緩くなるか",
       "各CSVの scope=total（全パターンをまたいだ中央値）",
       "（倍率が大きいほど 2σ<倍率×ATR は通りやすい。取引数が単調に増え、"
       "膠着なしへ近づくはず）")
    for label, tf in TFS:
        _, rows = data[tf]
        if not rows:
            continue
        rows = alive(rows)
        _, mults = axes(rows)
        by = {}
        for r in rows:
            by.setdefault(r["kc"], []).append(r)
        print("\n  【%s足】" % label)
        print("    %-10s" % "倍率" + "".join("%8s" % ("%.2f" % m) for m in mults))
        cnt = [med([r["trades"] for r in by[m]]) for m in mults]
        pip = [med([r["pips"] for r in by[m]]) for m in mults]
        print("    %-10s" % "取引数" + "".join(
            ("%8.0f" % c) if c is not None else "       —" for c in cnt))
        print("    %-10s" % "1取引pips" + "".join(
            ("%8.2f" % v) if v is not None else "       —" for v in pip))
        mono = all(a is not None and b is not None and b >= a
                   for a, b in zip(cnt, cnt[1:]))
        print("    取引数は倍率について単調増加か: %s" % ("はい" if mono else "**いいえ**"))
        _, brows = base[tf]
        if brows:
            b = alive(brows)
            print("    膠着なし（比較相手・執行4通り）: 取引数 %s / 1取引 %.2f pips" % (
                med([r["trades"] for r in b]), med([r["pips"] for r in b])))
        else:
            print("    膠着なし（比較相手）: 未実行")

    hr("2. (期間 × 倍率) の格子 — 1取引あたり pips の中央値",
       "scope=total を 引き金3 × 測る足4 × 執行4 = 48通りでまとめた中央値",
       "（探すのは最良の1マスではなく、良い値が広がっている面）")
    for label, tf in TFS:
        _, rows = data[tf]
        if not rows:
            continue
        rows = alive(rows)
        p, m = axes(rows)
        c = make_grid(rows, lambda r: r["pips"])
        print("\n  【%s足】  合格ライン相当 = ネット %.2f pips" % (label, PASS_NET))
        show_grid(p, m, c)
        hit = [k for k, v in c.items() if v is not None and v >= PASS_NET]
        pos = [k for k, v in c.items() if v is not None and v > 0]
        print("    黒字のマス %d / 合格ライン以上のマス %d （全 %d マス）" % (
            len(pos), len(hit), len(c)))
        prev = c.get(PREV)
        print("    前回の設定 (期間%d, 倍率%.2f): %s" % (
            PREV[0], PREV[1], ("%.2f pips" % prev) if prev is not None else "—"))

    hr("3. (期間 × 倍率) の格子 — 取引数の中央値",
       "同上",
       "（%d回を切るマスの数字は参考程度。backtest_design.md の読み方）" % FEW_TRADES)
    for label, tf in TFS:
        _, rows = data[tf]
        if not rows:
            continue
        rows = alive(rows)
        p, m = axes(rows)
        c = make_grid(rows, lambda r: r["trades"])
        print("\n  【%s足】" % label)
        show_grid(p, m, c, fmt="%7.0f", blank="      —")
        few = [k for k, v in c.items() if v is not None and v < FEW_TRADES]
        print("    取引数中央値が %d 回未満のマス: %d / %d" % (FEW_TRADES, len(few), len(c)))

    hr("4. 測る足で分けた格子 — 1取引pips の中央値",
       "scope=total を squeeze_tf で層別（引き金3 × 執行4 = 12通りの中央値）",
       "（P3 第1段階で強かったのは4時間足。それが期間・倍率にどう依存するか）")
    for label, tf in TFS:
        _, rows = data[tf]
        if not rows:
            continue
        rows = alive(rows)
        p, m = axes(rows)
        for stf in sorted({r["squeeze_tf"] for r in rows}):
            sub = [r for r in rows if r["squeeze_tf"] == stf]
            if not sub:
                continue
            print("\n  【%s足 / 測る足=%s】" % (label, SQZTF[stf]))
            show_grid(p, m, make_grid(sub, lambda r: r["pips"]))

    hr("5. 時間足をまたいだ一貫性",
       "10分・15分・1時間の3つで同じ (期間, 倍率) を突き合わせる",
       "（隣り合う2つで揃っても偶然。3つで見る）")
    tf3 = ["M10", "M15", "H1"]
    have = [tf for tf in tf3 if data[tf][1]]
    if len(have) < 3:
        print("  3つそろっていない（あるのは %s）。判定しない。" % (", ".join(have) or "なし"))
    else:
        cs = {tf: make_grid(alive(data[tf][1]), lambda r: r["pips"]) for tf in tf3}
        keys = sorted(cs["M10"])
        def ok(k, thr):
            return all(cs[tf].get(k) is not None and cs[tf][k] >= thr for tf in tf3)
        allpos = [k for k in keys if ok(k, 1e-9)]
        allpass = [k for k in keys if ok(k, PASS_NET)]
        print("  マス総数 %d" % len(keys))
        print("  3つとも黒字        : %d マス" % len(allpos))
        print("  3つとも合格ライン超: %d マス" % len(allpass))
        if allpos:
            print("\n  3つとも黒字だったマス（弱いほうから見た順）:")
            print("    %-8s %-8s %8s %8s %8s %10s" % (
                "期間", "倍率", "10分", "15分", "1時間", "最小"))
            for k in sorted(allpos, key=lambda k: -min(cs[tf][k] for tf in tf3)):
                print("    %-8d %-8.2f %8.2f %8.2f %8.2f %10.2f" % (
                    k[0], k[1], cs["M10"][k], cs["M15"][k], cs["H1"][k],
                    min(cs[tf][k] for tf in tf3)))

    hr("6. 取引数で足切りしたうえでの一貫性",
       "10分・15分・1時間の3つすべてで取引数の中央値が %d 回以上のマスだけ残す" % ENOUGH,
       "（格子の高い値は取引数の少ない隅に集まる。そこを外して見る）")
    if len(have) < 3:
        print("  3つそろっていない。判定しない。")
    else:
        ps = {tf: make_grid(alive(data[tf][1]), lambda r: r["pips"]) for tf in tf3}
        ns = {tf: make_grid(alive(data[tf][1]), lambda r: r["trades"]) for tf in tf3}
        bs = {}
        for tf in tf3:
            _, br = base[tf]
            bs[tf] = med([r["pips"] for r in alive(br)]) if br else None
        keys = [k for k in sorted(ps["M10"])
                if all(ns[tf].get(k) is not None and ns[tf][k] >= ENOUGH for tf in tf3)]
        print("  取引数が足りるマス: %d / %d" % (len(keys), len(ps["M10"])))
        print("  膠着なしの 1取引pips: " + "  ".join(
            "%s=%s" % (tf, ("%.2f" % bs[tf]) if bs[tf] is not None else "—") for tf in tf3))
        pos = [k for k in keys if all(ps[tf][k] > 0 for tf in tf3)]
        beat = [k for k in keys
                if all(bs[tf] is not None and ps[tf][k] > bs[tf] for tf in tf3)]
        pas = [k for k in keys if all(ps[tf][k] >= PASS_NET for tf in tf3)]
        print("  うち 3つとも黒字        : %d マス" % len(pos))
        print("  うち 3つとも膠着なしに勝つ: %d マス" % len(beat))
        print("  うち 3つとも合格ライン超  : %d マス" % len(pas))
        if keys:
            print("\n  取引数が足りるマスの全一覧（3つの最小 1取引pips の良い順）:")
            print("    %-6s %-6s %18s %18s %18s %8s" % (
                "期間", "倍率", "10分 pips(回)", "15分 pips(回)", "1時間 pips(回)", "最小"))
            for k in sorted(keys, key=lambda k: -min(ps[tf][k] for tf in tf3)):
                cells = ["%8.2f (%5.0f)" % (ps[tf][k], ns[tf][k]) for tf in tf3]
                print("    %-6d %-6.2f %18s %18s %18s %8.2f" % (
                    k[0], k[1], cells[0], cells[1], cells[2],
                    min(ps[tf][k] for tf in tf3)))

    hr("7. 設定を1つに固定したうえで、周りが持つか",
       "引き金 × 測る足 × 執行 の48通りを潰さず、1つずつ (期間×倍率) の面を見る",
       "（§2〜§6 は48通りの中央値なので、特定の1組だけ効く形を消してしまう。"
       "ここはその穴を埋める）")
    if len(have) < 3:
        print("  3つそろっていない。判定しない。")
    else:
        rows3 = {tf: alive(data[tf][1]) for tf in tf3}
        per = sorted({r["sqz_period"] for r in rows3["M10"]})
        mul = sorted({r["kc"] for r in rows3["M10"]})
        pi = {p: i for i, p in enumerate(per)}
        mi = {m: i for i, m in enumerate(mul)}

        def cfgkey(r):
            return (r["trigger"], r["squeeze_tf"], r["entry_delay"], r["exit_delay"])

        table = {}   # cfg -> (period, mult) -> {tf: (trades, pips)}
        for tf in tf3:
            for r in rows3[tf]:
                table.setdefault(cfgkey(r), {}).setdefault(
                    (r["sqz_period"], r["kc"]), {})[tf] = (r["trades"], r["pips"])

        def passes(cell):
            return (cell is not None and len(cell) == 3
                    and all(t >= ENOUGH for t, _ in cell.values())
                    and all(p >= PASS_NET for _, p in cell.values()))

        def positive(cell):
            return (cell is not None and len(cell) == 3
                    and all(p > 0 for _, p in cell.values()))

        hits = []
        for cfg, cells in table.items():
            for k, cell in cells.items():
                if not passes(cell):
                    continue
                nb = []
                for dp, dm in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                    a, b = pi[k[0]] + dp, mi[k[1]] + dm
                    if 0 <= a < len(per) and 0 <= b < len(mul):
                        nb.append(cells.get((per[a], mul[b])))
                hits.append((cfg, k, cell, nb))

        print("  3つの時間足すべてで 取引%d回以上 かつ 合格ライン超 のマス: %d" % (ENOUGH, len(hits)))
        if not hits:
            print("  → ③ケルトナーには、条件を固定しても合格する設定が1つも無い。")
        else:
            print("\n  そのマスと、隣（期間±1段=5、倍率±1段=0.25）の持ち具合:")
            print("    %-26s %-6s %-6s %8s %10s %10s" % (
                "引き金/測る足/入遅/決遅", "期間", "倍率", "最小pips", "隣で合格", "隣で黒字"))
            for cfg, k, cell, nb in sorted(hits, key=lambda h: -min(p for _, p in h[2].values())):
                np_ = sum(1 for c in nb if passes(c))
                nz = sum(1 for c in nb if positive(c))
                print("    %-26s %-6d %-6.2f %8.2f %6d / %d %6d / %d" % (
                    "%s/%s/入%d/決%d" % (TRIG[cfg[0]], SQZTF[cfg[1]], cfg[2], cfg[3]),
                    k[0], k[1], min(p for _, p in cell.values()), np_, len(nb), nz, len(nb)))
            solid = [h for h in hits if sum(1 for c in h[3] if passes(c)) >= 2]
            print("\n  隣が2つ以上も合格するマス（面になっているもの）: %d" % len(solid))
            if not solid:
                print("  → 合格するマスはすべて孤立した点。倍率を1段（0.25）動かすか、")
                print("     期間を1段（5）動かすと崩れる。過学習の形。")

    hr("8. 前回の設定は良い側だったか",
       "各時間足の格子の中で (期間21, 倍率1.50) が何番目か",
       "（前回は振らずに固定していた。慣習の値が当たりだったかを見る）")
    print("  %-6s %10s %10s %14s" % ("時間足", "前回pips", "最良pips", "順位（良い順）"))
    for label, tf in TFS:
        _, rows = data[tf]
        if not rows:
            continue
        c = make_grid(alive(rows), lambda r: r["pips"])
        vals = sorted((v for v in c.values() if v is not None), reverse=True)
        prev = c.get(PREV)
        if prev is None:
            print("  %-6s %10s %10.2f %14s" % (label, "—", vals[0], "—"))
            continue
        rank = sum(1 for v in vals if v > prev) + 1
        print("  %-6s %10.2f %10.2f %14s" % (
            label, prev, vals[0], "%d / %d" % (rank, len(vals))))


if __name__ == "__main__":
    main()
