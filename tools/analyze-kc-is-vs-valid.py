# -*- coding: utf-8 -*-
"""③ケルトナーの総当たりを、学習期間と検証用期間で突き合わせる。

**検証用期間の使用回数を1回消費した結果を扱う**（2026-08-22 実施）。
docs/backtest_results_kc_grid.md §11 の数字はすべてこのスクリプトの出力。

問うているのは「どれを選ぶか」ではなく「学習期間の順位は検証用期間の順位を
言い当てるか」。当たらなければ、どれを選んでも同じであることがその場で決まる。

使い方:  rtk python tools/analyze-kc-is-vs-valid.py
入力:    %APPDATA%\\MetaQuotes\\Terminal\\Common\\Files\\
           p3_kc_<tf>_..._opt.csv      … 学習期間 2018/11〜2022/12
           p3_kcv_<tf>_..._opt.csv     … 検証用期間 2023/01〜2024/10
           p3_kcbase_<tf>_..._opt.csv / p3_kcvbase_<tf>_..._opt.csv … 膠着なし
"""
import csv
import os
import statistics

TFS = [("5分", "M5"), ("10分", "M10"), ("15分", "M15"), ("1時間", "H1")]
TRIG = {0: "色の変化", 1: "膠着の開始", 2: "どちらでも"}
SQZTF = {0: "同じ足", 1: "1時間足", 2: "4時間足", 3: "日足"}
LOT_PIP_YEN = 100.0
PASS_NET = 3.01
ENOUGH = 100               # 学習期間の取引数の下限
VALID_MIN = 42             # 検証用期間の取引数の下限。期間比 42% を掛けた相当値
TOP_FRac = 0.10            # 「上位」の定義。上位10%
SHOW = 15
# 突き合わせたい設定（引き金, 測る足, 入遅, 決遅, 期間, 倍率）
COMPARE = (2, 2, 1, 1, 21, 1.50)

DIR = os.path.join(os.environ["APPDATA"], "MetaQuotes", "Terminal", "Common", "Files")


def load(tag, tf):
    """設定の組み合わせをキーにした辞書を返す。パス番号は期間ごとに変わるため使えない。"""
    path = os.path.join(DIR, "p3_%s_%s_USDJPY#_PERIOD_%s_opt.csv" % (tag, tf.lower(), tf))
    if not os.path.exists(path):
        return None
    out = {}
    with open(path, newline="", encoding="latin-1") as f:
        for r in csv.DictReader(f):
            if r["scope"] != "total":
                continue
            key = (int(r["trigger"]), int(r["squeeze_tf"]), int(r["entry_delay"]),
                   int(r["exit_delay"]), int(r["sqz_period"]), float(r["sqz_kcmult"]))
            n = int(r["trades"])
            net = float(r["net"])
            out[key] = (n, net, net / LOT_PIP_YEN / n if n else None)
    return out


def spearman(xs, ys):
    """順位相関。1に近いほど学習期間の順位が検証用の順位を言い当てている。"""
    n = len(xs)
    if n < 3:
        return None

    def rank(v):
        order = sorted(range(n), key=lambda i: v[i])
        rk = [0.0] * n
        i = 0
        while i < n:
            j = i
            while j + 1 < n and v[order[j + 1]] == v[order[i]]:
                j += 1
            avg = (i + j) / 2.0 + 1.0
            for k in range(i, j + 1):
                rk[order[k]] = avg
            i = j + 1
        return rk

    rx, ry = rank(xs), rank(ys)
    mx, my = statistics.mean(rx), statistics.mean(ry)
    num = sum((a - mx) * (b - my) for a, b in zip(rx, ry))
    dx = sum((a - mx) ** 2 for a in rx) ** 0.5
    dy = sum((b - my) ** 2 for b in ry) ** 0.5
    return num / (dx * dy) if dx and dy else None


def hr(title, src, note=""):
    print("\n" + "=" * 100)
    print(title)
    print("  出所: " + src + (("   " + note) if note else ""))
    print("=" * 100)


def label_of(k):
    return "%-10s %-7s 入%d決%d 期間%-3d 倍率%.2f" % (
        TRIG[k[0]], SQZTF[k[1]], k[2], k[3], k[4], k[5])


def main():
    print("""
順位は【合計損益（円）】で付ける。1回あたり pips ではない。
先に取引数で足切りする: 学習期間 %d 回以上、検証用期間 %d 回以上（期間比 42%% の相当値）。
両方を満たした設定だけを並べ、順位・上位%.0f%% はすべてその中での話。
""" % (ENOUGH, VALID_MIN, TOP_FRac * 100))

    hr("1. 学習期間の順位は、検証用期間の順位を言い当てるか",
       "両方の期間で回した同じ設定どうしを、合計損益の降順で突き合わせる",
       "（順位相関が0付近なら、学習期間の順位で選ぶ意味が無いということ）")
    print("  %-6s %8s %10s %10s %12s %14s %s" % (
        "時間足", "足切り後", "順位相関", "参考:pips", "学習で上位10%", "→検証でも上位10%", "偶然なら"))
    keep = {}
    for label, tf in TFS:
        a, b = load("kc", tf), load("kcv", tf)
        if not a or not b:
            print("  %-6s （ファイルなし）" % label)
            continue
        ks = [k for k in a if k in b and a[k][0] >= ENOUGH and b[k][0] >= VALID_MIN]
        keep[tf] = (a, b, ks)
        if len(ks) < 3:
            print("  %-6s %8d （少なすぎて判定しない）" % (label, len(ks)))
            continue
        rho = spearman([a[k][1] for k in ks], [b[k][1] for k in ks])
        rho_p = spearman([a[k][2] for k in ks], [b[k][2] for k in ks])
        m = max(1, int(len(ks) * TOP_FRac))
        hit = len(set(sorted(ks, key=lambda k: -a[k][1])[:m]) &
                  set(sorted(ks, key=lambda k: -b[k][1])[:m]))
        print("  %-6s %8d %10s %10s %12d %14d %s" % (
            label, len(ks), ("%.3f" % rho) if rho is not None else "—",
            ("%.3f" % rho_p) if rho_p is not None else "—", m, hit,
            "%.0f" % (m * TOP_FRac)))

    hr("2. 学習期間で選んだ設定は、検証用期間で生き残ったか",
       "学習期間だけで絞り、その集合を検証用で評価する（選び直しはしない）",
       "（検証用を見て選び直せば第二の学習期間になる）")
    print("""  判定の条件（前回はここを書いていなかった。検証用側に取引数の下限も無かった）
    学習で選ぶ  : 1回あたりネット %.2f pips 以上 かつ 取引 %d 回以上
    生き残り(黒字): 検証用の合計損益がプラス     かつ 検証用の取引が下限以上
    生き残り(合格): 検証用の1回あたりが %.2f pips 以上 かつ 検証用の取引が下限以上
    検証用は1年10ヶ月で学習期間4年2ヶ月の 42%%。学習の %d 回は検証用では %d 回相当。
    下限を満たさなかったものは「判定不能」とし、生き残りにも脱落にも数えない。
""" % (PASS_NET, ENOUGH, PASS_NET, ENOUGH, int(ENOUGH * 0.42)))
    for label, tf in TFS:
        if tf not in keep:
            continue
        a, b, ks = keep[tf]
        sel = [k for k in ks if a[k][2] >= PASS_NET and a[k][0] >= ENOUGH]
        print("  【%s足】 学習で選ばれた設定 %d 件" % (label, len(sel)))
        if not sel:
            print("    （該当なし）\n")
            continue
        ns = sorted(b[k][0] for k in sel)
        print("    検証用での取引数: 中央値 %d / 最小 %d / 最大 %d" % (
            statistics.median(ns), ns[0], ns[-1]))
        print("    %-10s %10s %14s %14s %16s" % (
            "取引の下限", "判定できる件数", "うち黒字", "うち合格", "1回pips中央値"))
        for th in (0, 20, 42, 100):
            g = [k for k in sel if b[k][0] >= th]
            if not g:
                print("    %-10d %10d %14s %14s %16s" % (th, 0, "—", "—", "—"))
                continue
            pos = sum(1 for k in g if b[k][1] > 0)
            pas = sum(1 for k in g if b[k][2] >= PASS_NET)
            print("    %-10d %10d %8d (%3d%%) %8d (%3d%%) %16.2f" % (
                th, len(g), pos, pos * 100 // len(g), pas, pas * 100 // len(g),
                statistics.median(b[k][2] for k in g)))
        print()

    hr("3. 両方の期間で【合計損益】が上位%.0f%%に入った設定" % (TOP_FRac * 100),
       "足切り後の集合を、学習期間の合計損益と検証用の合計損益でそれぞれ並べた積集合",
       "（ご依頼の「両方で上位」。ただしこれは検証用を見て選んでいる）")
    for label, tf in TFS:
        if tf not in keep:
            continue
        a, b, ks = keep[tf]
        if len(ks) < 3:
            continue
        m = max(1, int(len(ks) * TOP_FRac))
        both = list(set(sorted(ks, key=lambda k: -a[k][1])[:m]) &
                    set(sorted(ks, key=lambda k: -b[k][1])[:m]))
        print("\n  【%s足】 足切り後 %d 通り / 上位%.0f%% = %d位まで / 両方で上位: %d件" % (
            label, len(ks), TOP_FRac * 100, m, len(both)))
        if not both:
            continue
        print("    %-46s %22s %22s %s" % (
            "設定", "学習 合計円/回/pips", "検証 合計円/回/pips", "2期間合計"))
        for k in sorted(both, key=lambda k: -(a[k][1] + b[k][1]))[:SHOW]:
            print("    %-46s %+9.0f/%5d/%6.2f %+9.0f/%5d/%6.2f %+10.0f" % (
                label_of(k), a[k][1], a[k][0], a[k][2], b[k][1], b[k][0], b[k][2],
                a[k][1] + b[k][1]))

    hr("5. 指定した設定と、両方で上位%.0f%%だった設定の比較" % (TOP_FRac * 100),
       "指定 = " + label_of(COMPARE),
       "（順位は【合計損益】の降順。足切りを通らなかった設定は順位の母集団に入らない）")
    for label, tf in TFS:
        if tf not in keep:
            continue
        a, b, ks = keep[tf]
        if len(ks) < 3:
            continue
        m = max(1, int(len(ks) * TOP_FRac))
        both = list(set(sorted(ks, key=lambda k: -a[k][1])[:m]) &
                    set(sorted(ks, key=lambda k: -b[k][1])[:m]))

        def rk(d):
            return {k: i + 1 for i, k in enumerate(sorted(ks, key=lambda k: -d[k][1]))}
        ra, rb = rk(a), rk(b)

        print("\n  【%s足】 足切り後 %d 通り（上位%.0f%% = %d位まで）" % (
            label, len(ks), TOP_FRac * 100, m))
        print("    %-46s %26s %26s" % (
            "設定", "学習 合計円/回/pips (順位)", "検証 合計円/回/pips (順位)"))

        def line(k, tag):
            if k not in ks:
                why = "足切り未通過"
                if k in a and k in b:
                    why += "（学習%d回 / 検証%d回）" % (a[k][0], b[k][0])
                print("    %-46s %s%s" % (label_of(k), why, tag))
                return
            print("    %-46s %+9.0f/%5d/%6.2f (%4d位 上位%3.0f%%) %+9.0f/%5d/%6.2f (%4d位 上位%3.0f%%)%s" % (
                label_of(k), a[k][1], a[k][0], a[k][2], ra[k], ra[k] / len(ks) * 100,
                b[k][1], b[k][0], b[k][2], rb[k], rb[k] / len(ks) * 100, tag))

        line(COMPARE, "  ← 指定")
        for k in sorted(both, key=lambda k: -(a[k][1] + b[k][1]))[:SHOW]:
            line(k, "")
        if not both:
            print("    （両方で上位%.0f%%に入った設定は無し）" % (TOP_FRac * 100))

    hr("4. 膠着なしとの比較（検証用期間）",
       "p3_kcvbase_<tf>_..._opt.csv",
       "（そもそも膠着を足す意味があったか）")
    print("  %-6s %26s %26s" % ("時間足", "膠着なし 最良 円/回/pips", "膠着あり 最良 円/回/pips"))
    for label, tf in TFS:
        if tf not in keep:
            continue
        _, b, _ = keep[tf]
        vb = load("kcvbase", tf)
        best = max((v for v in b.values() if v[0]), key=lambda v: v[1])
        if vb:
            bb = max((v for v in vb.values() if v[0]), key=lambda v: v[1])
            print("  %-6s %+16.0f/%5d/%6.2f %+16.0f/%5d/%6.2f" % (
                label, bb[1], bb[0], bb[2], best[1], best[0], best[2]))
        else:
            print("  %-6s %26s %+16.0f/%5d/%6.2f" % (label, "（未実行）", best[1], best[0], best[2]))


if __name__ == "__main__":
    main()
