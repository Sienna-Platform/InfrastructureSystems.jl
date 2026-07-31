#!/bin/bash
# Time-series benchmark: IS4 baseline vs the InfraStore branch, one exclusive
# node, both sides split one process per BENCH_KINDS section and run
# sequentially. See HPC.md for the methodology and for why each choice is made.
#
#   sbatch benchmark/SLURM.sh
#
#SBATCH --job-name=bench-ts
#SBATCH --nodes=1 --exclusive
#SBATCH --time=12:00:00
#SBATCH --output=bench-ts-%j.log
# No --constraint on the first run: take whatever node the scheduler gives and
# record it (env.txt below). To make a later run comparable, pin it then with
# the ActiveFeatures string this one recorded.

# --- fill this in: where to send job notifications ---------------------------
# BEGIN tells you which node you landed on, END/FAIL that the ~12 h run is done.
# The integrity gate at the bottom exits non-zero on bad data, so a FAIL mail
# means "do not publish these", not only "the job crashed".
# Drop TIME_LIMIT_80 if you do not want the 80%-of-walltime warning.
#SBATCH --mail-user=REPLACE_WITH_YOUR_EMAIL
#SBATCH --mail-type=BEGIN,END,FAIL,TIME_LIMIT_80

module load julia/1.12.6
set -euo pipefail

# --- fill this in: the directory holding wt-is-rust, wt-is4-bench, infrastore
SIENNA=/path/to/your/sienna

if [ "$SIENNA" = /path/to/your/sienna ]; then
  echo "FATAL: edit SIENNA at the top of this script first." >&2
  exit 1
fi

# Warn, don't abort: an unset address is not worth losing a 12 h allocation to.
grep -q REPLACE_WITH_YOUR_EMAIL "$0" 2>/dev/null &&
  echo "WARNING: --mail-user is still the placeholder; no notifications will arrive." >&2

BRANCH=$SIENNA/wt-is-rust          # IS branch under test
IS4=$SIENNA/wt-is4-bench           # IS4 baseline (c63d9a281 + PR #594)
CORE=$SIENNA/infrastore            # Rust storage engine

export INFRASTORE_LIB=$CORE/target/release/libinfrastore_ffi.so
export JULIA_NUM_THREADS=1
export JULIA_NUM_GC_THREADS=4

RESULTS=$SIENNA/bench-results/$SLURM_JOB_ID
mkdir -p "$RESULTS"

# Stores live in tmpfs (RAM). The benchmark passes its store directory to
# SystemData explicitly, so SIENNA_TIME_SERIES_DIRECTORY is ignored — TMPDIR is
# the lever, because build_system() gets its directory from mktempdir().
NODE_SCRATCH=/dev/shm

# Preflight: tmpfs runs out of space by OOM-ing or ENOSPC mid-run, hours in.
# Fail now instead. ~15 GB of stores accumulate per run (they are only released
# at process exit), so require headroom before starting.
need_gb=20
free_gb=$(df -BG --output=avail "$NODE_SCRATCH" | tail -1 | tr -dc '0-9')
if [ "${free_gb:-0}" -lt "$need_gb" ]; then
  echo "FATAL: $NODE_SCRATCH has ${free_gb}G free, need ${need_gb}G." >&2
  echo "Either raise the tmpfs limit or point NODE_SCRATCH at node-local disk." >&2
  exit 1
fi
echo "scratch: $NODE_SCRATCH (${free_gb}G free)"

run_with_tmp() {                     # run_with_tmp <tag> <cmd...>
  export TMPDIR=$NODE_SCRATCH/$SLURM_JOB_ID-$1
  mkdir -p "$TMPDIR"
  local st=0
  "${@:2}" || st=$?                  # reclaim the tmpfs even on failure, but
  rm -rf "$TMPDIR"                   # report the command's status, not rm's
  return $st
}
# Reclaim tmpfs even if the job is cancelled or dies mid-run.
trap 'rm -rf ${NODE_SCRATCH:?}/${SLURM_JOB_ID:?}-*' EXIT

cd "$BRANCH"                         # benchmark scripts live here for both sides

{ hostname; lscpu | head -20; free -g | head -2; julia --version
  echo "IS   $(git -C "$BRANCH" rev-parse --short HEAD)"
  echo "IS4  $(git -C "$IS4" rev-parse --short HEAD)"
  echo "core $(git -C "$CORE" rev-parse --short HEAD)"
  # Node identity and its scheduler feature tags. ActiveFeatures is literally
  # what you pass to --constraint to land on this node type again.
  echo "node $SLURMD_NODENAME  partition $SLURM_JOB_PARTITION"
  scontrol show node "$SLURMD_NODENAME" | tr ' ' '\n' | grep -i 'Features='
  scontrol show node "$SLURMD_NODENAME" | tr ' ' '\n' | grep -iE '^(CPUTot|RealMemory|Gres)='
} > "$RESULTS"/env.txt

# One process per section, run one at a time. IS4's per-op cost degrades over
# the life of a process, so a single-process matrix inflates whatever runs last;
# a fresh process per section resets that. Sequential, because concurrent
# sections would reintroduce exactly the contention this node was reserved to
# remove — and it would land on IS4, the side measured as slower.
KINDS=(sts nst det prob scen sweep has dst shared serialize)

# The branch also measures `remove` at the full N. IS4 cannot — it does not
# finish at 100k, which is why it gets the separate 2k/5k/10k growth curve
# below. Dropping this from the branch would silently retire a row the previous
# run reported (`remove/float64/remove_all`, 38.1 µs/op).
BRANCH_KINDS=("${KINDS[@]}" remove)

# Raw per-section output. A subdirectory, so the non-recursive
# results_full_*.csv globs below cannot pick it up, but still under $RESULTS so
# it lands in the tarball as provenance for which process each number came from.
SECTIONS="$RESULTS"/sections
mkdir -p "$SECTIONS"

# A failing section is logged and skipped rather than aborting the job: with 43
# processes, losing hours of completed work to one bad section is the worse
# outcome. The gate at the bottom sees the gap and fails the job then.
section_failed=0

# --- IS4 baseline first (~5-6 h), `remove` excluded ---
for k in "${KINDS[@]}"; do
  BENCH_N=100000 BENCH_KINDS=$k \
    run_with_tmp is4-$k julia --project="$IS4" \
    benchmark/bench_full_is4.jl > "$SECTIONS"/is4_$k.csv \
    || { echo "SECTION FAILED: is4 $k" >&2; section_failed=1; }
done

for n in 2000 5000 10000; do
  BENCH_N=$n BENCH_KINDS=remove \
    run_with_tmp is4rm$n julia --project="$IS4" \
    benchmark/bench_full_is4.jl > "$RESULTS"/results_full_is4_remove_$n.csv
done

# --- branch second, same process structure, repeated for a variance estimate ---
for rep in 1 2 3; do
  for k in "${BRANCH_KINDS[@]}"; do
    BENCH_N=100000 BENCH_LABEL=infrastore BENCH_KINDS=$k \
      run_with_tmp br$rep-$k julia --project=test \
      benchmark/bench_full_branch.jl > "$SECTIONS"/branch_r${rep}_$k.csv \
      || { echo "SECTION FAILED: branch r$rep $k" >&2; section_failed=1; }
  done
done

# Stitch each run's sections back into the canonical one-file-per-run layout the
# gate, the variance pass and make_full_report.jl all expect: header once, every
# data row, one DONE trailer.
concat_sections() {                  # concat_sections <out> <in...>
  local out=$1; shift
  { head -1 "$1"
    awk 'FNR>1 && $0 !~ /^DONE /' "$@"
    tail -1 "$1"
  } > "$out"
}

files=(); for k in "${KINDS[@]}"; do files+=("$SECTIONS"/is4_$k.csv); done
concat_sections "$RESULTS"/results_full_is4_hpc.csv "${files[@]}"

for rep in 1 2 3; do
  files=(); for k in "${BRANCH_KINDS[@]}"; do files+=("$SECTIONS"/branch_r${rep}_$k.csv); done
  concat_sections "$RESULTS"/results_full_branch_hpc_r$rep.csv "${files[@]}"
done

# ------------------------- post-processing -------------------------
# Everything below is cheap and runs inside the allocation, so a failed run is
# diagnosed here rather than after the node is released.

# 1. Integrity gate. A truncated or error-laden CSV still looks like data, so
#    check before anything downstream consumes it. The per-section files are
#    checked too: a concatenated file takes its DONE trailer from its *first*
#    section, so a later section dying would otherwise pass this silently.
fail=$section_failed
[ "$section_failed" -eq 0 ] || echo "at least one section exited non-zero - see SECTION FAILED above"
for f in "$SECTIONS"/*.csv "$RESULTS"/results_full_*.csv; do
  tail -1 "$f" | grep -q '^DONE ' || { echo "INCOMPLETE: $f"; fail=1; }
  if awk -F, '$9 ~ /^error:/' "$f" | grep -q .; then
    echo "ERROR ROWS in $f:"; awk -F, '$9 ~ /^error:/' "$f"; fail=1
  fi
done

# Every run must have contributed all its sections; a missing one would just
# silently shrink the comparison table. Counted by glob rather than `ls | wc -l`,
# which under `pipefail` would abort the gate on the very case it is meant to
# report — a run that produced no sections at all.
for run in is4 branch_r1 branch_r2 branch_r3; do
  case $run in is4) want=${#KINDS[@]};; *) want=${#BRANCH_KINDS[@]};; esac
  found=("$SECTIONS"/${run}_*.csv)
  [ -e "${found[0]}" ] || found=()          # unmatched glob stays literal
  [ "${#found[@]}" -eq "$want" ] ||
    { echo "MISSING SECTIONS: $run has ${#found[@]} of $want"; fail=1; }
done

# make_full_report.jl keys on (branch,kind,eltype,op) and silently picks a
# winner on collision. Sections are disjoint by construction, so any duplicate
# here means the stitching is wrong, not the data.
for f in "$RESULTS"/results_full_is4_hpc.csv "$RESULTS"/results_full_branch_hpc_r?.csv; do
  dup=$(awk -F, 'NR>1 && $0 !~ /^DONE /{print $1","$2","$3","$4}' "$f" | sort | uniq -d)
  [ -z "$dup" ] || { echo "DUPLICATE KEYS in $f:"; echo "$dup"; fail=1; }
done

# IS4 legitimately reports exactly 5 unsupported rows (NonSequentialTimeSeries,
# a type it does not have). Any other count means something else broke.
nst=$(awk -F, '$9=="not_supported_on_branch"' \
  "$RESULTS"/results_full_is4_hpc.csv | wc -l)
[ "$nst" -eq 5 ] || { echo "UNEXPECTED: $nst nst-gap rows on is4 (want 5)"; fail=1; }

[ "$fail" -eq 0 ] && echo "integrity: OK" \
                  || echo "integrity: FAILURES ABOVE - do not publish these"

# 2. Run-to-run variance across the three branch passes. This is the error bar;
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

# 3. Comparison table. Stage only this run's CSVs: make_full_report.jl globs
#    every results_full_*.csv in the directory it is given, so pointing it at
#    benchmark/ would silently mix in the laptop-era files.
STAGE="$RESULTS"/report-input
mkdir -p "$STAGE"
cp "$RESULTS"/results_full_branch_hpc_r1.csv \
   "$RESULTS"/results_full_is4_hpc.csv "$STAGE"/
julia "$BRANCH"/benchmark/make_full_report.jl "$STAGE" > "$RESULTS"/comparison.md

# 4. One archive to copy back.
tar -czf "$RESULTS".tar.gz -C "$RESULTS" .
echo "results: $RESULTS.tar.gz"

# 5. Fail the job if the gate tripped, so sacct/emails show FAILED rather than
#    COMPLETED. The artifacts above are still written either way.
[ "$fail" -eq 0 ] || { echo "integrity gate failed - see log above"; exit 1; }
