(nersc-python) nlewi26@login14:euler-miniapp$ cat plot_io_timeline.py
#!/usr/bin/env python3
"""
plot_io_timeline.py

Build a per-rank I/O timeline from HashBrick IOProfile CSV output.

For every  <prefix>_rank<NNNNNN>.csv  in the current directory this draws one
stacked subplot.  Each subplot has two lanes:

    top lane    -- top-level function blocks (kind == "func") interleaved with
                   gray "compute" bars filling the gaps between them
    bottom lane -- the sub-phases (kind == "scope" / "cgns") that fall inside
                   each function block

Function blocks and their sub-phases are drawn in shades of orange; compute
gaps are gray.  The legend maps each orange shade to the top-level function
name (e.g. cgnsWriteSolutionFile).

App bounds come from the matching  <prefix>_rank<NNNNNN>.meta.csv  sidecar if
present (app_start_s / app_end_s).  When absent, the axis falls back to the
first/last profiled event -- in which case the leading/trailing compute blocks
cannot be shown.

Times are taken from t_start_s / t_end_s (MPI_Wtime monotonic seconds); the
timeline only uses relative position, so no wall-clock conversion is needed.

Usage:
    python plot_io_timeline.py
    python plot_io_timeline.py --prefix io_profile --out io_timeline.png
    python plot_io_timeline.py --dir /path/to/csvs
"""

import argparse
import glob
import os
import re
import sys
import csv

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import Patch
import matplotlib.colors as mcolors


RANK_RE = re.compile(r"_rank(\d+)\.csv$")


def parse_args():
    p = argparse.ArgumentParser(description="Per-rank I/O timeline plotter.")
    p.add_argument("--dir", default=".",
                   help="directory containing the CSV files (default: .)")
    p.add_argument("--prefix", default="io_profile",
                   help="CSV filename prefix (default: io_profile)")
    p.add_argument("--out", default="io_timeline.png",
                   help="output PNG path (default: io_timeline.png)")
    p.add_argument("--dpi", type=int, default=150, help="output DPI")
    p.add_argument("--max-ranks", type=int, default=0,
                   help="cap number of ranks plotted (0 = no cap)")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="print parsing diagnostics (files, rows, distinct "
                        "functions/scopes/calls per rank)")
    return p.parse_args()


def find_csvs(directory, prefix):
    """Return [(rank:int, csv_path, meta_path_or_None), ...] sorted by rank."""
    pattern = os.path.join(directory, "{}_rank*.csv".format(prefix))
    out = []
    for path in glob.glob(pattern):
        base = os.path.basename(path)
        if base.endswith(".meta.csv"):
            continue  # skip sidecars; matched separately
        m = RANK_RE.search(base)
        if not m:
            continue
        rank = int(m.group(1))
        meta = path[:-len(".csv")] + ".meta.csv"
        out.append((rank, path, meta if os.path.exists(meta) else None))
    out.sort(key=lambda t: t[0])
    return out


def load_rows(csv_path):
    """Load event rows, robust to unquoted commas in the 'phase' field.

    The C profiler writes the raw call expression (e.g.
    'cgerr = cg_base_write(a, "Base", b)') into the phase column without CSV
    quoting, so a naive csv parser mis-splits those rows.  The schema is fixed:

        rank, function, phase, kind, t_start_s, t_end_s, duration_us,
        bytes, call_index [, wall_start_s, wall_end_s]

    The first 2 fields (rank, function) and the trailing 5+ fields are all
    comma-free, so we split on commas and reconstruct 'phase' as everything
    between them.  Counting from the right makes this order-independent of the
    optional wall-clock columns.
    """
    rows = []
    n_dropped = 0
    with open(csv_path) as f:
        header = f.readline()  # consume header
        ncols = header.count(",") + 1
        # trailing comma-free fields after 'phase':
        #   kind, t_start_s, t_end_s, duration_us, bytes, call_index, [walls...]
        n_tail = ncols - 3   # everything after rank,function,phase
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split(",")
            if len(parts) < 3 + n_tail:
                n_dropped += 1
                continue
            rank_s = parts[0]
            function = parts[1]
            tail = parts[-n_tail:]
            phase = ",".join(parts[2:len(parts) - n_tail])
            # tail = [kind, t_start_s, t_end_s, duration_us, bytes, call_index, ...]
            kind = tail[0]
            try:
                t_start = float(tail[1])
                t_end = float(tail[2])
            except (ValueError, IndexError):
                n_dropped += 1
                continue
            rows.append({
                "function": function,
                "phase": phase,
                "kind": kind,
                "t_start": t_start,
                "t_end": t_end,
            })
    if n_dropped:
        sys.stderr.write(
            "[warn] {}: skipped {} unparseable row(s)\n".format(
                os.path.basename(csv_path), n_dropped))
    return rows


def load_app_bounds(meta_path):
    """Return (app_start, app_end) or (None, None) if unmarked/missing."""
    if not meta_path:
        return None, None
    try:
        with open(meta_path, newline="") as f:
            reader = csv.DictReader(f)
            for r in reader:
                s = float(r["app_start_s"])
                e = float(r["app_end_s"])
                # -1 sentinel means the driver never called the marker
                return (s if s >= 0 else None,
                        e if e >= 0 else None)
    except (KeyError, ValueError, OSError):
        pass
    return None, None


def func_blocks(rows):
    """Top-level function spans: kind == 'func' and phase == 'TOTAL'."""
    blocks = [(r["t_start"], r["t_end"], r["function"])
              for r in rows
              if r["kind"] == "func" and r["phase"] == "TOTAL"]
    blocks.sort(key=lambda b: b[0])
    return blocks


def spans_of_kind(rows, kind):
    """Spans for a given kind ('scope' or 'cgns'). Returns (s,e,func,phase)."""
    out = [(r["t_start"], r["t_end"], r["function"], r["phase"])
           for r in rows
           if r["kind"] == kind]
    out.sort(key=lambda s: s[0])
    return out


def compute_gaps(blocks, t0, t1):
    """Gray compute spans = anything in [t0, t1] not covered by a func block.

    Function blocks can be adjacent or have gaps; they should not overlap at
    the top level, but we coalesce defensively just in case.
    """
    if not blocks:
        return [(t0, t1)] if t1 > t0 else []

    # Coalesce block coverage into non-overlapping intervals.
    merged = []
    for s, e, _ in sorted(blocks, key=lambda b: b[0]):
        if merged and s <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], e)
        else:
            merged.append([s, e])

    gaps = []
    cursor = t0
    for s, e in merged:
        if s > cursor:
            gaps.append((cursor, s))
        cursor = max(cursor, e)
    if t1 > cursor:
        gaps.append((cursor, t1))
    return gaps


def shorten_call(phase):
    """Reduce a stringized call expression to its function name.

    Drops any 'lhs = ' assignment prefix and keeps everything up to the first
    parenthesis:
      'cgerr = cg_open(a_fileName, CG_MODE_WRITE, &indexFile)' -> 'cg_open'
      'cgerr = cgp_field_multi_write_data( indexFile, ...)'    -> 'cgp_field_multi_write_data'
    Falls back to the trimmed string if there is no parenthesis.
    """
    s = phase.split("(", 1)[0]           # everything before first '('
    if "=" in s:
        s = s.split("=", 1)[1]           # drop 'lhs =' prefix
    return s.strip()


def distinct_palette(n):
    """Generate n maximally-distinct RGBA colors.

    Spaces hues evenly around the wheel and alternates saturation/value so that
    even when the count is large (20-30 calls) adjacent and wrapped colors stay
    visually separable -- unlike a fixed 16/20-entry list that must repeat.
    """
    import colorsys
    if n <= 0:
        return []
    colors = []
    # Two value/saturation tiers interleaved across the hue wheel.
    tiers = [(0.85, 0.90), (0.65, 0.70)]
    for i in range(n):
        hue = (i / n) % 1.0
        sat, val = tiers[i % len(tiers)]
        r, g, b = colorsys.hsv_to_rgb(hue, sat, val)
        colors.append((r, g, b, 1.0))
    return colors


def build_color_map(func_keys, scope_keys, call_keys):
    """Assign one distinct color per entity, per lane, keyed by name alone.

      func_keys  -- function names      (kind 'func')
      scope_keys -- scope phase names    (kind 'scope')
      call_keys  -- shortened call names (kind 'cgns')

    Each lane is colored independently from a palette sized to that lane's
    count, so every distinct function / scope / call gets its own color and a
    single legend entry.  Returns three dicts.
    """
    def assign(keys):
        ks = sorted(keys)
        pal = distinct_palette(len(ks))
        return {k: pal[i] for i, k in enumerate(ks)}

    return assign(func_keys), assign(scope_keys), assign(call_keys)


COMPUTE_COLOR = "0.65"  # gray


def lighten(color, amount=0.35):
    """Blend a color toward white."""
    r, g, b, a = mcolors.to_rgba(color)
    return (r + (1 - r) * amount,
            g + (1 - g) * amount,
            b + (1 - b) * amount,
            a)


def plot(ranks_data, func_colors, scope_colors, call_colors, out_path, dpi):
    n = len(ranks_data)
    fig, axes = plt.subplots(n, 1, figsize=(13, max(2.8 * n, 3.0)),
                             squeeze=False)
    axes = axes[:, 0]

    # Three lanes within each subplot (y in [0, 1]), top to bottom:
    #   functions (with compute gaps) / scopes / calls
    FUNC_Y, FUNC_H = 0.70, 0.24
    SCOPE_Y, SCOPE_H = 0.39, 0.22
    CALL_Y, CALL_H = 0.10, 0.22

    for ax, (rank, blocks, scopes, calls, t0, t1, marked) in zip(axes,
                                                                 ranks_data):
        span = t1 - t0 if t1 > t0 else 1.0

        # --- functions lane: compute gaps (gray) + function blocks ---
        for gs, ge in compute_gaps(blocks, t0, t1):
            ax.barh(FUNC_Y, (ge - gs), left=(gs - t0), height=FUNC_H,
                    color=COMPUTE_COLOR, edgecolor="white", linewidth=0.4,
                    align="edge", zorder=2)
        for bs, be, fn in blocks:
            ax.barh(FUNC_Y, (be - bs), left=(bs - t0), height=FUNC_H,
                    color=func_colors.get(fn, "gray"),
                    edgecolor="white", linewidth=0.4, align="edge", zorder=3)

        # --- scopes lane: colored per scope phase name ---
        for ss, se, fn, phase in scopes:
            ax.barh(SCOPE_Y, (se - ss), left=(ss - t0), height=SCOPE_H,
                    color=scope_colors.get(phase, "gray"),
                    edgecolor="white", linewidth=0.25, align="edge", zorder=3)

        # --- calls lane: colored per call function name (up to first paren) ---
        for cs, ce, fn, phase in calls:
            ax.barh(CALL_Y, (ce - cs), left=(cs - t0), height=CALL_H,
                    color=call_colors.get(shorten_call(phase), "gray"),
                    edgecolor="white", linewidth=0.2, align="edge", zorder=3)

        ax.set_xlim(0, span)
        ax.set_ylim(0, 1)
        ax.set_yticks([CALL_Y + CALL_H / 2,
                       SCOPE_Y + SCOPE_H / 2,
                       FUNC_Y + FUNC_H / 2])
        ax.set_yticklabels(["calls", "scopes", "functions"], fontsize=8)
        title = "rank {:06d}".format(rank)
        if not marked:
            title += "  (no app markers; axis = first/last event)"
        ax.set_title(title, fontsize=9, loc="left")
        ax.tick_params(axis="x", labelsize=8)
        for s in ("top", "right", "left"):
            ax.spines[s].set_visible(False)

    axes[-1].set_xlabel("time since app start (s)", fontsize=9)

    # One legend with section header rows, wrapped into enough columns that it
    # never overflows the figure height (which previously truncated entries).
    spacer = Patch(facecolor="none", edgecolor="none", label="")

    entries = []
    entries.append(("\u2014 Functions \u2014", None))
    entries.append(("compute", COMPUTE_COLOR))
    for fn in sorted(func_colors):
        entries.append((fn, func_colors[fn]))
    entries.append(("", None))
    entries.append(("\u2014 Scopes \u2014", None))
    for p in sorted(scope_colors):
        entries.append((p, scope_colors[p]))
    entries.append(("", None))
    entries.append(("\u2014 Calls \u2014", None))
    for c in sorted(call_colors):
        entries.append((c, call_colors[c]))

    handles = []
    for label, color in entries:
        if color is None:
            handles.append(Patch(facecolor="none", edgecolor="none",
                                 label=label))
        else:
            handles.append(Patch(facecolor=color, label=label))

    # Wrap so no column exceeds ~22 rows; columns fill top-to-bottom.
    ncol = max(1, (len(handles) + 21) // 22)
    fig.legend(handles=handles, loc="upper left", bbox_to_anchor=(0.83, 1.0),
               fontsize=7, framealpha=0.9, ncol=ncol, handlelength=1.2,
               labelspacing=0.3, columnspacing=1.2)

    fig.tight_layout(rect=(0, 0, 0.82, 1))
    fig.savefig(out_path, dpi=dpi, bbox_inches="tight")
    print("wrote {}".format(out_path))


def main():
    args = parse_args()
    found = find_csvs(args.dir, args.prefix)
    if not found:
        sys.stderr.write(
            "no CSV files matching '{}_rank*.csv' in {}\n".format(
                args.prefix, os.path.abspath(args.dir)))
        sys.exit(1)

    if args.max_ranks > 0:
        found = found[:args.max_ranks]

    if args.verbose:
        print("[debug] dir={}  prefix={}".format(
            os.path.abspath(args.dir), args.prefix))
        print("[debug] matched {} CSV file(s):".format(len(found)))
        for rank, csv_path, meta_path in found:
            print("[debug]   rank {:>6d}: {}  meta={}".format(
                rank, os.path.basename(csv_path),
                os.path.basename(meta_path) if meta_path else "(none)"))

    ranks_data = []
    func_keys = set()
    scope_keys = set()
    call_keys = set()
    for rank, csv_path, meta_path in found:
        rows = load_rows(csv_path)
        if not rows:
            if args.verbose:
                print("[debug] rank {:>6d}: 0 usable rows, skipping".format(
                    rank))
            continue
        blocks = func_blocks(rows)
        scopes = spans_of_kind(rows, "scope")
        calls = spans_of_kind(rows, "cgns")

        rank_funcs = set()
        rank_scopes = set()
        rank_calls = set()
        for _, _, fn in blocks:
            func_keys.add(fn)
            rank_funcs.add(fn)
        for _, _, fn, phase in scopes:
            scope_keys.add(phase)
            rank_scopes.add(phase)
        for _, _, fn, phase in calls:
            sc = shorten_call(phase)
            call_keys.add(sc)
            rank_calls.add(sc)

        app_start, app_end = load_app_bounds(meta_path)
        marked = app_start is not None and app_end is not None

        event_lo = min(r["t_start"] for r in rows)
        event_hi = max(r["t_end"] for r in rows)
        t0 = app_start if app_start is not None else event_lo
        t1 = app_end if app_end is not None else event_hi

        if args.verbose:
            print("[debug] rank {:>6d}: {} rows  "
                  "({} func blocks, {} scope spans, {} call spans)  "
                  "app_bounds={}  span={:.3f}s".format(
                      rank, len(rows), len(blocks), len(scopes), len(calls),
                      "marked" if marked else "first/last-event", t1 - t0))
            print("[debug]            distinct: {} functions, {} scopes, "
                  "{} calls".format(len(rank_funcs), len(rank_scopes),
                                     len(rank_calls)))

        ranks_data.append((rank, blocks, scopes, calls, t0, t1, marked))

    if not ranks_data:
        sys.stderr.write("CSV files found but contained no usable rows\n")
        sys.exit(1)

    if args.verbose:
        print("[debug] ---- global distinct keys ----")
        print("[debug] functions ({}): {}".format(
            len(func_keys), ", ".join(sorted(func_keys))))
        print("[debug] scopes ({}): {}".format(
            len(scope_keys), ", ".join(sorted(scope_keys))))
        print("[debug] calls ({}): {}".format(
            len(call_keys), ", ".join(sorted(call_keys))))

    func_colors, scope_colors, call_colors = build_color_map(
        func_keys, scope_keys, call_keys)
    plot(ranks_data, func_colors, scope_colors, call_colors,
         args.out, args.dpi)


if __name__ == "__main__":
    main()
