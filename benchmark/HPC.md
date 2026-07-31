# Running the time-series benchmark on HPC

One exclusive node, both branches run sequentially as single undisturbed
processes. This is the cleanest available methodology: it removes the
cross-machine problem (the 2026-07-30 laptop rerun compared M3 Max branch
numbers against M2 Pro IS4 numbers), the inter-process contention problem
(splitting a run across concurrent processes to save wall time), and
node-to-node hardware variance.

Scripts below are SLURM. For PBS/Torque, the environment setup is identical;
only the `#SBATCH` directives and `$SLURM_*` variables change.

## Status: executed 2026-07-31 (SLURM job 15438463)

Results are in this directory and summarised in `REPORT.md`. What the run
actually did, versus what is written below:

| | planned | actual |
|---|---|---|
| node | any, exclusive | `x1005c6s2b1n1`, 2× Xeon 8470QL / 104 cores / 250 GB, `ActiveFeatures=hbw,rh8` |
| Julia | 1.12.6 | **1.12.1** (the module available on the cluster) |
| scratch | node-local disk if any, else `/dev/shm` | `/dev/shm` — no node-local disk exists here, so the run is tmpfs-backed |
| IS4 | `c63d9a281` + #594 | `320a5035` (that resolution); the `git diff c63d9a281 --stat` gate in step 1 was not captured in `env.txt` |
| passes | IS4 ×1, branch ×3 | as planned; branch spread mean 3.0%, worst `reload_read_one` 24.7% |
| IS4 `remove` | 2k / 5k / 10k curve | as planned; `REPORT.md` extrapolates 100k from the fit |

**The one methodological finding to carry forward: running IS4's whole matrix
in a single process biases it.** IS4's per-op cost degrades over the life of a
process. Identical read work measured 1,678 µs/op in the first section (`sts`,
100k Float64 STS full read) and 7,209 µs/op in the `shared` section at the end
— a 4.3× drift; `det` vs `det_shared` drifted 2.7×. The branch was flat across
the same span (67.9 → 63.2 µs/op), and on the four-process 2026-07-30 laptop
run IS4's shared reads were *faster* than its non-shared reads, as they should
be. This is consistent with the HDF5 open-object iteration already identified
in IS4's removal path.

Consequence: in `results_full_is4_hpc.csv` the sections that ran late —
`sweep`, `has`, `dst`, `shared`, `serialize` — are upper bounds on IS4's cost,
so their speedup ratios are upper bounds too. `sts`, `nst`, `det`, `prob` and
`scen` ran early and are clean.

**Amend step 5 on the next run:** give IS4 one process per `BENCH_KINDS`
section (`sts`, `nst`, `det`, `prob`, `scen`, `sweep`, `has`, `dst`, `shared`,
`serialize`), run *sequentially* — one at a time, so the exclusive-node
property is preserved and only the process-lifetime accumulation is reset. The
branch does not need this but should get the same treatment for symmetry. This
costs no extra node time; it only changes where the process boundaries fall.

## Read this first: the three things that invalidate an HPC run

**1. `TMPDIR` must be node-local — the job uses `/dev/shm`.**
`build_system()` calls `mktempdir()` for every combination, and every store
write, read, slice and sweep goes through that directory. On most clusters
`TMPDIR` defaults to a shared parallel filesystem (Lustre, GPFS, NFS). Leave it
there and you are benchmarking the network filesystem, not the two storage
engines — results that look entirely plausible and mean nothing.

Note that `SIENNA_TIME_SERIES_DIRECTORY` does **not** work here. Both branches
honour it, but only as a fallback: `build_system()` passes
`time_series_directory` to `SystemData` explicitly, and the kwarg wins. `TMPDIR`
is the lever, since it is what `mktempdir()` reads.

Budget **~15 GB**. Per-combination temp directories are only released at
process exit, so they accumulate across the matrix (the branch run measured
6.6 GB of stores; IS4 is comparable, and the serialization section writes
another copy). On tmpfs that is 15 GB of **RAM**, and on most SLURM
configurations it counts against the job's memory cgroup — so the node needs
that much above the ~2 GB the benchmark itself peaks at. The script preflights
this and refuses to start if `/dev/shm` is short.

**Understand what tmpfs changes.** It removes storage I/O from the comparison,
which isolates the engines' CPU and algorithmic differences — the right call on
diskless compute nodes, where `/dev/shm` is the only fast node-local option.
But it is not what the report currently claims: prior campaigns were
disk-backed, and production Sienna systems store to disk. It may also mask the
IS4 contention sensitivity measured on 2026-07-30 (IS4 STS reads degraded 5.35×
under concurrent load; the branch 1.08×) if that effect turns out to be
I/O-bound.

`/dev/shm` is used because this cluster does not define `$SLURM_TMPDIR` — the
site provisions no per-job scratch, and `/tmp` cannot be assumed node-local.
Before settling for tmpfs, check whether local disk exists under another name
(run inside an allocation):

```sh
findmnt -t xfs,ext4,ext3,btrfs,tmpfs -o TARGET,FSTYPE,SIZE,SOURCE
df -hT /tmp /var/tmp /scratch /lscratch /local /localscratch 2>/dev/null
```

A mount of type `xfs`/`ext4` on a local device — as opposed to `lustre`, `nfs`,
`gpfs`, `beegfs`, or `tmpfs` — with ~20 GB free is a better `NODE_SCRATCH`, and
keeps the run disk-backed and comparable to earlier campaigns. If everything
node-local is tmpfs, `/dev/shm` is the only option and the caveat above applies.

Do **not** fall back to `/tmp` without checking its type. On many clusters it is
a symlink onto shared storage, and the run would silently measure the network
filesystem.

**2. Request an exclusive node.**
`--exclusive`. A co-scheduled job perturbs cache, memory bandwidth and I/O,
and the effects are not uniform across operations — read-heavy paths suffer
far more than metadata probes, which silently inflates the branch's advantage.
Record the node you actually landed on (step 6).

**3. Compute nodes usually have no network.**
Every `Pkg` operation and all precompilation must happen on the login node
(steps 3–4). A compute job that tries to resolve packages will fail or hang.

Also set Julia's thread counts explicitly. The benchmark is single-threaded,
but Julia sizes its **GC** thread pool from the core count by default, so an
HPC node with 128 cores behaves differently from the 14-core laptop these
results were last measured on. Pinning both makes the run reproducible and
independent of which node you land on. The script below sets them.

## Step 0 — prerequisites on the cluster

| need | notes |
|---|---|
| Julia 1.12.6 | `module load julia/1.12.6`, or juliaup in `$HOME` |
| Rust ≥ 1.94 | `rust-version` in infrastore's `Cargo.toml`; rustup in `$HOME` is fine |
| cmake + C compiler | infrastore builds HDF5 and zlib from vendored source |
| protobuf-compiler | gRPC codegen in the infrastore workspace |
| git | |

Debian/Ubuntu-flavoured login nodes: `sudo apt-get install cmake
protobuf-compiler` — or the module equivalents. No system HDF5 is required
(and should not be used: the vendored static build is what the laptop numbers
used).

## Step 1 — layout and checkouts

Three sibling directories. Set these once — every later step and the job
script use them.

```sh
# Fill in the parent; the rest are its children.
SIENNA=/path/to/your/sienna

BRANCH=$SIENNA/wt-is-rust          # IS branch under test
IS4=$SIENNA/wt-is4-bench           # IS4 baseline
CORE=$SIENNA/infrastore            # Rust storage engine
```

If they are not there yet:

```sh
mkdir -p $SIENNA && cd $SIENNA

git clone -b feat/rust-time-series-store <IS-remote> wt-is-rust
git -C wt-is-rust checkout f3eceb1f       # the commit these results describe

git clone <infrastore-remote> infrastore
git -C infrastore checkout f0c075e        # v0.4.0

# IS4 baseline: documented base commit + the PR #594 cherry-pick
git clone <IS-remote> wt-is4-bench
git -C wt-is4-bench checkout -B is4-bench c63d9a281
git -C wt-is4-bench cherry-pick -m 1 -X theirs 030ee942
```

Working from a worktree off an existing clone instead is fine — but pin the
commit explicitly. `git worktree add <path> IS4` checks out the *branch*, and
the IS4 tip is six commits ahead of the baseline (PR #596's units refactor
plus an aux-files cleanup); the subsequent `checkout` of the commit does not
stick. Use `--detach c63d9a281`, or `-b is4-bench c63d9a281`, then cherry-pick.
Verify before building:

```sh
git diff c63d9a281 --stat    # must be exactly: 2 files, 95 insertions(+), 63 deletions(-)
```

Anything more than those two files means you are on the branch tip, not the
documented baseline — the benchmark will still run and still produce
plausible numbers, which is what makes this one worth checking.

`030ee942` is PR #594's merge commit, hence `-m 1` (git needs to know which
parent to diff against). `-X theirs` resolves its three conflicts against
`c63d9a281` in #594's favour — IS4's pre-#594 per-series SQLite queries give
way to #594's hoisted metadata store, memoised forecast parameters, and
in-memory `existing_forecasts` lookup.

`is4-baseline-pr594.patch` in this directory is the same resolution as a patch
(`git am < …`), if you would rather apply it than re-resolve.

Why bother: without #594 the IS4 100k transform does not finish within an
hour, so the baseline is measured with IS4's *best* implementation rather than
a strawman. #594 touches no other measured path.

## Step 2 — build the InfraStore engine (login node)

```sh
cd $CORE
cargo build -p infrastore-ffi --release
export INFRASTORE_LIB=$PWD/target/release/libinfrastore_ffi.so   # .so on Linux
```

**Release, not debug.** A debug build leaves out every optimisation and keeps
the bounds/overflow checks in; it runs an order of magnitude slower and would
understate InfraStore drastically. Confirm the path you export contains
`/release/`.

First build compiles HDF5 from source — a few minutes, then cached.

## Step 3 — Julia environments (login node, needs network)

InfraStore.jl is **not registered**, so the branch environment has to develop
it by explicit path. The IS4 side needs no such step.

```sh
# Branch environment
cd $BRANCH
julia --project=test -e 'using Pkg;
  Pkg.develop([PackageSpec(path="."),
               PackageSpec(path="'"$CORE"'/julia/InfraStore.jl")]);
  Pkg.instantiate()'

# IS4 environment — the checkout is its own project. It already declares
# TimeSeries and DataStructures, the only packages the benchmark needs beyond
# InfrastructureSystems itself, so there is nothing to add.
julia --project=$IS4 -e 'using Pkg; Pkg.instantiate()'
```

Do **not** run `Pkg.develop` or `Pkg.add` against `$IS4`. Developing the
package into its own environment is circular, and `Pkg.add` rewrites the
checkout's tracked `Project.toml` — which dirties the tree and invalidates the
`git diff c63d9a281 --stat` baseline check from step 1. `Pkg.instantiate()`
only writes `Manifest.toml`, which IS gitignores.

If the branch environment fails to resolve with *"empty intersection between
InfraStore@0.4.0 and project compatibility 0.3"*, bump the pin in
`test/Project.toml` to `InfraStore = "^0.4"`. That fix is already applied in
the working tree here but is easy to lose in a fresh clone of an older commit.

If `Pkg` cannot reach a registry, prefix with `JULIA_PKG_SERVER=`.

## Step 4 — precompile and smoke-test (login node)

Do not skip this. A five-minute smoke run catches a broken environment before
you spend a node-hour discovering it.

```sh
cd $BRANCH
INFRASTORE_LIB=$CORE/target/release/libinfrastore_ffi.so \
  BENCH_N=200 julia --project=test benchmark/bench_full_branch.jl | tail -5

BENCH_N=200 julia --project=$IS4 \
  benchmark/bench_full_is4.jl | tail -5
```

Both must end with `DONE <label> full`. Check for failures:

```sh
awk -F, '$9!="ok" && $1!="branch"' <output>
```

The branch should show **no** non-`ok` rows. IS4 should show exactly five
`not_supported_on_branch` rows — the `NonSequentialTimeSeries` payloads, a
type IS4 does not have. Anything else, especially rows starting `error:`, is a
broken environment, not a result.

## Step 5 — the job (single node, both branches sequentially)

Both branches on **one** node, one after the other. `--constraint` only bounds
node-to-node variance (silicon binning, NVMe wear and fill, DIMM population,
rack thermals, microcode); it does not eliminate it, and several headline
claims are ratios where a few percent of node difference lands straight in the
number. One node removes that error class instead of arguing it away. It costs
~30 min, since IS4 dominates either way.

**Split IS4 by section.** The 2026-07-31 run put IS4's whole matrix in one
process and its late sections came out inflated (see *Status* above). Loop
`BENCH_KINDS` one section per process instead — sequentially, so the node stays
undisturbed. The script below is the as-run version and does not do this yet.

**Run IS4 first, the branch second.** Whatever runs second inherits a
thermally soaked CPU and a written-on local disk. With the branch second, that
penalty *understates* its advantage, so the reported speedups are conservative
lower bounds. The reverse order flatters the branch — the first thing a
skeptical reviewer will probe.

**Repeat the branch run.** It is only ~30 min, so three passes cost an hour
and give run-to-run variance measured on the actual node. That turns "every
number is a single sample" into a quantified error bar for at least one side.

```bash
#!/bin/bash
#SBATCH --job-name=bench-ts
#SBATCH --nodes=1 --exclusive
#SBATCH --time=10:00:00
#SBATCH --output=bench-ts-%j.log
# No --constraint on the first run: take whatever node the scheduler gives and
# record it (env.txt below). To make a later run comparable, pin it then with
# the ActiveFeatures string this one recorded.

module load julia/1.12.6
set -euo pipefail

# --- fill this in: the directory holding wt-is-rust, wt-is4-bench, infrastore
SIENNA=/path/to/your/sienna

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
  "${@:2}"
  rm -rf "$TMPDIR"                   # tmpfs holds RAM until deleted
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

# --- IS4 baseline first (~4-5 h), `remove` excluded ---
BENCH_N=100000 \
BENCH_KINDS=sts,nst,det,prob,scen,sweep,has,dst,shared,serialize \
  run_with_tmp is4 julia --project="$IS4" \
  benchmark/bench_full_is4.jl > "$RESULTS"/results_full_is4_hpc.csv

for n in 2000 5000 10000; do
  BENCH_N=$n BENCH_KINDS=remove \
    run_with_tmp is4rm$n julia --project="$IS4" \
    benchmark/bench_full_is4.jl > "$RESULTS"/results_full_is4_remove_$n.csv
done

# --- branch second (~30 min each), repeated for a variance estimate ---
for rep in 1 2 3; do
  BENCH_N=100000 BENCH_LABEL=infrastore \
    run_with_tmp br$rep julia --project=test \
    benchmark/bench_full_branch.jl > "$RESULTS"/results_full_branch_hpc_r$rep.csv
done

# ------------------------- post-processing -------------------------
# Everything below is cheap and runs inside the allocation, so a failed run is
# diagnosed here rather than after the node is released.

# 1. Integrity gate. A truncated or error-laden CSV still looks like data, so
#    check before anything downstream consumes it.
fail=0
for f in "$RESULTS"/results_full_*.csv; do
  tail -1 "$f" | grep -q '^DONE ' || { echo "INCOMPLETE: $f"; fail=1; }
  if awk -F, '$9 ~ /^error:/' "$f" | grep -q .; then
    echo "ERROR ROWS in $f:"; awk -F, '$9 ~ /^error:/' "$f"; fail=1
  fi
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
```

The job leaves you `hpc-<jobid>/` containing the raw CSVs, `comparison.md`
(the branch-vs-IS4 table), `branch_variance.csv` (the error bar),
`env-<jobid>.txt` (provenance), and a tarball of all of it.

Only pass `r1` to the report generator. It keys rows by
`(branch, kind, eltype, op)`, so handing it all three branch passes would make
them collide on identical keys and the winner would be decided by `readdir`
order. The other two passes exist for the variance number, not the table.

Check `branch_variance.csv` before trusting any speedup: if the mean spread is
a few percent, the single-sample ratios are sound. If some op swings 30%, that
op's ratio is noise and needs more passes or a caveat.

Three removal points rather than one let you *show* the growth curve instead
of asserting it — if µs/op roughly doubles from 5k to 10k, that is the
quadratic claim demonstrated rather than argued.

Wall-time estimates come from the original campaign's per-op costs (~229 min
of timed operations for the IS4 matrix, ~9 min per branch pass), plus JIT
warmup and the untimed setup adds. The 10 h request is padded roughly 1.5×; a
job killed at the wall clock loses everything, since results only land as the
run proceeds.

## Step 6 — record the environment

The report's environment table must describe the machine the numbers came
from. The job script captures it inside the allocation (`env.txt`) rather than
reconstructing it afterwards: hostname, CPU model, RAM, Julia version, the
three commit SHAs, and the node's scheduler feature tags.

Reconstructing it later does not work — once the allocation ends you cannot
tell which node you were given, and the laptop campaign already shipped a
report whose stated hardware did not match its data.

The `ActiveFeatures=` line is the one to keep handy. It is the exact string
`--constraint` takes, so a future rerun can be pinned to this node type
without guessing:

```sh
grep -i ActiveFeatures env.txt      # e.g. ActiveFeatures=genoa,nvme
#SBATCH --constraint=genoa          # in the rerun, using a value you measured
```

## Step 7 — merge and report

Copy the CSVs back into `benchmark/`, then:

```sh
julia benchmark/make_full_report.jl
```

**Archive the superseded CSVs first.** `make_full_report.jl` globs *every*
`results_full_*.csv` in the directory and keys rows by
`(branch, kind, eltype, op)`. Leaving the laptop-era files in place means the
old and new runs collide on identical keys, and which one wins is decided by
`readdir` order — it will warn, but it will still emit a table. Move the
superseded files to `benchmark/archive/` so the report is generated from the
HPC run alone.

Then update `REPORT.md`: the environment block, the date, the commit SHAs, and
the methodology bullets — the "long runs were split across concurrent
processes" and "both branches were measured under comparable machine load"
caveats can both be **deleted**, which is the main scientific gain from doing
this on HPC at all. Done for the 2026-07-31 run; the laptop-era CSVs were
deleted rather than archived (they are recoverable from git history), and the
staged `report-input/` directory is what the generator reads.

## What this does and does not fix

Fixed: cross-machine comparison, inter-process contention, noisy-neighbour
effects, and the unverifiable "comparable machine load" hand-wave.

Not fixed by moving to HPC:

- **Process-lifetime accumulation on IS4.** Discovered by the 2026-07-31 run
  and not a property of the machine: IS4's per-op cost grows over the life of
  a process, so a single-process matrix inflates whatever runs last. The fix
  is process boundaries (one per `BENCH_KINDS` section), not a bigger node.
- **Single run per configuration.** Every number remains one sample. If a
  reviewer asks for error bars, the fix is repeats (`for rep in 1 2 3`, adding
  a rep column), not a bigger machine. Cheap for the branch, expensive for
  IS4.
- **HPC node storage differs from a laptop's.** Node-local NVMe usually beats
  a laptop SSD, which flatters *both* engines — but not necessarily equally,
  since IS4 and InfraStore have different I/O patterns. The comparison is
  sound; absolute µs/op are not transferable to the laptop results.
- **IS4's `remove` at 100k stays an extrapolation**, now an honest one with a
  measured growth curve behind it.
