#!/bin/bash
# Post-processing only: stitch a completed branch-side run, fold in an IS4
# baseline CSV from an earlier job, and produce the gate/variance/comparison
# artifacts that SLURM.sh normally writes at its tail.
#
# Use this when SLURM.sh was run with the IS4 sections commented out (or when
# any run died after the measurements but before the report). It measures
# nothing: it only reads CSVs, so it is safe to re-run and cheap to schedule.
#
#   sbatch benchmark/SLURM_report.sh <results-dir> [is4-source]
#   bash   benchmark/SLURM_report.sh <results-dir> [is4-source]   # login node
#
# <results-dir>  the failed run's $RESULTS, i.e. $SIENNA/bench-results/<jobid>.
#                Must contain sections/branch_r*_*.csv (or already-stitched
#                results_full_branch_hpc_r*.csv).
# [is4-source]   optional. A results_full_is4_hpc.csv from the older run, or a
#                directory holding it; it is copied into <results-dir>. Omit if
#                you have already copied the file in yourself.
#
#SBATCH --job-name=bench-ts-report
#SBATCH --nodes=1 --ntasks=1 --cpus-per-task=2
#SBATCH --time=00:30:00
#SBATCH --output=bench-ts-report-%j.log
# No --exclusive and no long walltime: nothing here is timed, so contention
# cannot corrupt the numbers. Do not add measurement steps to this script for
# the same reason — it is not allocated a quiet node.
#SBATCH --mail-user=REPLACE_WITH_YOUR_EMAIL
#SBATCH --mail-type=END,FAIL

module load julia/1.12.6
set -euo pipefail

# --- fill this in: the directory holding wt-is-rust (only make_full_report.jl
# --- is needed from it; no Julia project and no INFRASTORE_LIB are involved)
SIENNA=/path/to/your/sienna

if [ "$SIENNA" = /path/to/your/sienna ]; then
  echo "FATAL: edit SIENNA at the top of this script first." >&2
  exit 1
fi

BRANCH=$SIENNA/wt-is-rust

RESULTS=${1:-}
IS4_SRC=${2:-}
if [ -z "$RESULTS" ]; then
  echo "usage: $0 <results-dir> [is4-source]" >&2
  exit 1
fi
# A bare job id is the common case, so accept it as shorthand.
[ -d "$RESULTS" ] || RESULTS=$SIENNA/bench-results/$RESULTS
[ -d "$RESULTS" ] || { echo "FATAL: no such results dir: $RESULTS" >&2; exit 1; }
RESULTS=$(cd "$RESULTS" && pwd)
SECTIONS="$RESULTS"/sections

echo "results: $RESULTS"

# --- stage the IS4 baseline ---------------------------------------------------
# Only results_full_is4_hpc.csv is staged. The is4 remove growth curve
# (results_full_is4_remove_*.csv, n=2000/5000/10000) is deliberately left out of
# the report input: it shares the key (remove,float64,remove_all) with the
# branch's n=100000 row, so merging it would print a speedup between two
# different problem sizes. Copy those files in for provenance if you like — the
# staging step below will not pick them up.
if [ -n "$IS4_SRC" ]; then
  [ -d "$IS4_SRC" ] && IS4_SRC=$IS4_SRC/results_full_is4_hpc.csv
  [ -f "$IS4_SRC" ] || { echo "FATAL: no such IS4 CSV: $IS4_SRC" >&2; exit 1; }
  cp "$IS4_SRC" "$RESULTS"/results_full_is4_hpc.csv
  echo "is4 baseline copied from $IS4_SRC"
fi

IS4_CSV=$RESULTS/results_full_is4_hpc.csv
if [ ! -f "$IS4_CSV" ]; then
  echo "FATAL: $IS4_CSV missing. Pass the old run's CSV as the second argument," >&2
  echo "       or copy it into $RESULTS yourself." >&2
  exit 1
fi

# Record what this report was built from, since the two halves now come from
# different jobs and the run's own env.txt only describes the branch half.
{ echo "report built by $0"
  echo "job ${SLURM_JOB_ID:-none}  host $(hostname)"
  echo "results dir $RESULTS"
  echo "is4 baseline source ${IS4_SRC:-pre-existing $IS4_CSV}"
  echo "is4 baseline $(ls -l "$IS4_CSV")"
  echo "report script $(git -C "$BRANCH" rev-parse --short HEAD)"
} > "$RESULTS"/report_provenance.txt

# --- stitch the branch sections ----------------------------------------------
KINDS=(sts nst det prob scen sweep has dst shared serialize)
BRANCH_KINDS=("${KINDS[@]}" remove)

concat_sections() {                  # concat_sections <out> <in...>
  local out=$1; shift
  { head -1 "$1"
    awk 'FNR>1 && $0 !~ /^DONE /' "$@"
    tail -1 "$1"
  } > "$out"
}

# Which repetitions actually ran. Detected rather than assumed: the point of
# this script is to salvage a run that did not finish as planned, so hard-coding
# 1 2 3 would abort on exactly the case it exists to handle.
REPS=()
if [ -d "$SECTIONS" ]; then
  for rep in 1 2 3; do
    found=("$SECTIONS"/branch_r${rep}_*.csv)
    [ -e "${found[0]}" ] && REPS+=("$rep")
  done
fi

fail=0

if [ "${#REPS[@]}" -gt 0 ]; then
  for rep in "${REPS[@]}"; do
    files=()
    for k in "${BRANCH_KINDS[@]}"; do
      f=$SECTIONS/branch_r${rep}_$k.csv
      [ -f "$f" ] && files+=("$f") || { echo "MISSING SECTION: branch r$rep $k"; fail=1; }
    done
    [ "${#files[@]}" -gt 0 ] || { echo "FATAL: rep $rep has no sections" >&2; exit 1; }
    concat_sections "$RESULTS"/results_full_branch_hpc_r$rep.csv "${files[@]}"
  done
  echo "stitched ${#REPS[@]} branch rep(s) from $SECTIONS"
else
  # No sections directory: fall back to whatever the failed run already
  # stitched, so a run that got past concat but died at the report still works.
  stitched=("$RESULTS"/results_full_branch_hpc_r*.csv)
  [ -e "${stitched[0]}" ] ||
    { echo "FATAL: neither $SECTIONS nor results_full_branch_hpc_r*.csv found" >&2; exit 1; }
  echo "no sections dir; using ${#stitched[@]} pre-stitched branch file(s) as-is"
fi

# ------------------------- post-processing -------------------------
# Same gate as SLURM.sh, with the is4 half checked as a single imported file
# rather than as sections — there are no is4 sections in this results dir.

# 1. Integrity gate.
gate_files=("$RESULTS"/results_full_*.csv)
[ -d "$SECTIONS" ] && gate_files+=("$SECTIONS"/*.csv)
for f in "${gate_files[@]}"; do
  tail -1 "$f" | grep -q '^DONE ' || { echo "INCOMPLETE: $f"; fail=1; }
  if awk -F, '$9 ~ /^error:/' "$f" | grep -q .; then
    echo "ERROR ROWS in $f:"; awk -F, '$9 ~ /^error:/' "$f"; fail=1
  fi
done

for rep in "${REPS[@]}"; do
  want=${#BRANCH_KINDS[@]}
  found=("$SECTIONS"/branch_r${rep}_*.csv)
  [ -e "${found[0]}" ] || found=()
  [ "${#found[@]}" -eq "$want" ] ||
    { echo "MISSING SECTIONS: branch_r$rep has ${#found[@]} of $want"; fail=1; }
done
# Not a failure — a two-rep run is publishable, it just has a weaker error bar,
# and the variance pass below reports the count it actually used.
[ "${#REPS[@]}" -eq 3 ] ||
  echo "NOTE: ${#REPS[@]} of 3 branch repetitions present; variance is based on those."

for f in "$RESULTS"/results_full_is4_hpc.csv "$RESULTS"/results_full_branch_hpc_r?.csv; do
  dup=$(awk -F, 'NR>1 && $0 !~ /^DONE /{print $1","$2","$3","$4}' "$f" | sort | uniq -d)
  [ -z "$dup" ] || { echo "DUPLICATE KEYS in $f:"; echo "$dup"; fail=1; }
done

# 2. Checks specific to importing the is4 half from another job. A wrong file
#    copied in here is the one new failure mode this script introduces, and
#    every one of these mistakes still parses as valid CSV.
is4_labels=$(awk -F, 'NR>1 && $0 !~ /^DONE /{print $1}' "$IS4_CSV" | sort -u | tr '\n' ' ')
[ "$is4_labels" = "is4 " ] ||
  { echo "WRONG BASELINE: $IS4_CSV has branch label(s) '$is4_labels', want 'is4'"; fail=1; }

# The 10 kinds the is4 side is expected to cover. A truncated baseline (say, the
# job died after `scen`) would otherwise just drop rows from the table.
want_kinds="det det_shared dst has_ts nst prob scen serialize sts sts_shared"
got_kinds=$(awk -F, 'NR>1 && $0 !~ /^DONE /{print $2}' "$IS4_CSV" | sort -u | tr '\n' ' ')
[ "$got_kinds" = "$want_kinds " ] ||
  { echo "IS4 KIND MISMATCH: got '$got_kinds' want '$want_kinds'"; fail=1; }

# IS4 legitimately reports exactly 5 unsupported rows (NonSequentialTimeSeries,
# a type it does not have). Any other count means something else broke.
nst=$(awk -F, '$9=="not_supported_on_branch"' "$IS4_CSV" | wc -l)
[ "$nst" -eq 5 ] || { echo "UNEXPECTED: $nst nst-gap rows on is4 (want 5)"; fail=1; }

# The branch run measured on this job's node; the baseline did not. That is a
# real caveat on every speedup column below, so state it in the log.
echo "NOTE: is4 and branch numbers come from different jobs - confirm both ran"
echo "      on the same node type before publishing (compare env.txt files)."

[ "$fail" -eq 0 ] && echo "integrity: OK" \
                  || echo "integrity: FAILURES ABOVE - do not publish these"

# 3. Run-to-run variance across the branch passes. This is the error bar;
#    without it every number in the report is a single sample.
awk -F, '
  $1!="branch" && $9=="ok" && $4!="maxrss" && $4!="store_disk_bytes" {
    k=$2"/"$3"/"$4; v=$7+0
    if (!(k in lo) || v<lo[k]) lo[k]=v
    if (!(k in hi) || v>hi[k]) hi[k]=v
    s[k]+=v; c[k]++
  }
  END {
    print "op,passes,mean_us,spread_pct"
    for (k in c) {
      m=s[k]/c[k]; sp=(m>0)?100*(hi[k]-lo[k])/m:0
      printf "%s,%d,%.2f,%.1f\n", k, c[k], m, sp
      tot+=sp; n++; if (sp>wv) { wv=sp; wk=k }
    }
    printf "# mean spread %.1f%% over %d ops; worst %s %.1f%%\n", tot/n, n, wk, wv
  }' "$RESULTS"/results_full_branch_hpc_r*.csv > "$RESULTS"/branch_variance.csv
tail -1 "$RESULTS"/branch_variance.csv

# 4. Comparison table. Stage only the two files that belong in it:
#    make_full_report.jl globs every results_full_*.csv in the directory it is
#    given, so an unstaged directory would mix in the is4 remove growth curve
#    and any laptop-era files.
STAGE="$RESULTS"/report-input
rm -rf "$STAGE"                      # stale stage from the failed run would linger
mkdir -p "$STAGE"
cp "$RESULTS"/results_full_branch_hpc_r"${REPS[0]:-1}".csv \
   "$RESULTS"/results_full_is4_hpc.csv "$STAGE"/
julia "$BRANCH"/benchmark/make_full_report.jl "$STAGE" > "$RESULTS"/comparison.md
echo "report: $RESULTS/comparison.md"

# 5. One archive to copy back. Keep any archive the earlier job left, rather
#    than overwriting a possibly-good tarball with this one.
[ -f "$RESULTS".tar.gz ] && mv "$RESULTS".tar.gz "$RESULTS".tar.gz.prev
tar -czf "$RESULTS".tar.gz -C "$RESULTS" .
echo "results: $RESULTS.tar.gz"

# 6. Fail the job if the gate tripped, so sacct/emails show FAILED rather than
#    COMPLETED. The artifacts above are still written either way.
[ "$fail" -eq 0 ] || { echo "integrity gate failed - see log above"; exit 1; }
