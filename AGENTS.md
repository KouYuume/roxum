# Working on roxum

## Direction

- Build a Web platform that fits Roc's language and effect model. Use idiomatic Roc APIs rather than translating Rust or axum structures mechanically.
- Keep application policy and pure transformations in Roc; keep operating-system resources and execution machinery in the Zig host.
- Prefer small, explicit APIs. Keep implementation details internal unless applications need them to express behavior.
- Read the relevant [design documents](docs/README.md) before changing an architectural boundary. Document the resulting design, not the history of the change.

## Repository map

| Location | Responsibility |
|---|---|
| `platform/*.roc` | Roc APIs and their internal implementation; `platform/main.roc` declares application-visible modules |
| `platform/host/` | Zig host, execution, resource management, and generated ABI glue |
| `integrations/` | Integrations built on platform capabilities |
| `libraries/` | Supporting libraries |
| `examples/hello/`, `examples/ddd/`, `examples/middleware/` | Minimal, DDD, and tags-and-middleware application examples |
| `tests/`, `fuzz/` | Behavioral, integration, ownership, ABI, and fuzz checks |
| `bench/` | Performance workloads and measurement tools |
| `docs/guides/`, `docs/design/` | User-facing guidance and current design contracts |
| `tools/`, `build.zig` | Build, verification, code generation, and release tooling |

## Language and runtime rules

### Roc

- Before writing, modifying, or reviewing Roc code, read and follow [roc_coding_rules.md](roc_coding_rules.md).
- That document is the source of truth for pure functions, effectful functions, `->` / `=>`, and the `!` naming convention.

### Zig

- Do not use inferred enum literals such as `.persistent` or `.request` in project-authored Zig code. Qualify values with their type, for example `Domain.persistent` and `Domain.request`.
- Prefer a one-line guard without braces for a single simple early return, for example `if (invalid) return null;`. Use braces for multiple operations, an explanatory comment, or a branch that no longer reads clearly on one line.
- Preserve the ownership and lifetime contracts in [execution and ownership](docs/design/execution-model.md) and the suspension/cancellation contracts in [I/O scheduling](docs/design/io-execution.md). Request allocations and effect handles must not escape their request lifetime.
- Regenerate ABI glue through `tools/regen-glue.sh`; do not hand-edit generated output. Build host archives and Roc platform sources together after boundary changes.

## Public behavior and documentation

- Follow the [public API layout](docs/design/public-api-layout.md). Do not expose host implementation types merely because ABI glue needs them.
- When public behavior changes, update the relevant guides, examples, and contract tests together. Check error behavior as well as successful responses.
- Keep examples runnable and representative of the supported API. Keep their subjects and scope focused: a minimal application, a DDD application, and an application whose routes use tags and layers.
- Write code comments and documentation in English, except for explicitly localized documents. Keep `README.md` and `README.ja.md` aligned when their shared content changes.
- Comments should explain contracts, invariants, constraints, or non-obvious reasons. Omit comments that restate the code, temporary decisions, debugging notes, or development history.
- Keep build outputs, local credentials, benchmark results, and temporary investigation files out of version control. Follow the existing ignore rules; retain reusable fixtures and regression tests.

## Tests and verification

- Derive test cases from the input contract and its boundaries. State the boundary or equivalence class each case covers rather than listing arbitrary values.
- For boundary-value tests, cover the nearest valid value below the boundary, the boundary itself, and the nearest valid value above it, where those values exist. Include invalid values immediately outside the accepted range when the API must reject them.
- Analyze boundaries within the valid domain. For power-of-two alignments around 16 bytes, use `8`, `16`, and `32`, not `15` and `17`.
- Keep exhaustive contract matrices separate from focused unit boundaries. If acceptance requires `1, 2, 4, 8, 16, 32`, exercise all six in the allocator lifecycle test even if a smaller unit test covers the branch boundary.
- Use the pinned compiler and setup in [toolchain.md](docs/toolchain.md). Do not change the compiler pin to work around a failure without handling the associated ABI and compatibility checks.
- Choose verification based on the changed behavior. Run focused checks during development and the broader affected checks before declaring the work complete. Report what ran, what failed, and what remains unverified.

Run commands from the repository root:

| Purpose | Command |
|---|---|
| List available verification groups | `python3 tools/check.py --list` |
| Run an affected group across its configured backend/allocator variants | `python3 tools/check.py --only <step-name>` |
| Run unit, Roc module, negative-fixture, and parser fuzz tests | `zig build test` |
| Check generated ABI glue | `bash tools/regen-glue.sh --check` |
| Run semantic ABI checks | `zig build test-abi` |
| Run the complete release verification suite | `python3 tools/check.py` |
| Test the HTTP benchmark tooling without AWS calls | `python3 -m unittest discover -s bench/m13 -p 'test_*.py'` |

For compiler, ABI, ownership, or execution changes, follow the broader matrix in
[toolchain.md](docs/toolchain.md) and [.github/workflows/full-checks.yml](.github/workflows/full-checks.yml),
including Linux checks. Do not run independent host rebuilds concurrently against
the same `platform/targets/` output; `tools/check.py` coordinates those phases.
Documentation-only edits need link/content checks rather than runtime tests.

Pull request CI runs only a fast subset. Before pushing or opening a pull request,
commit, then run the complete suite with `ROC_SRC` set: `python3 tools/check.py`.
The pre-push hook and the Claude Code and Codex hooks refuse commits that have not
passed it; do not bypass them. Leave merges, releases, repository settings, and
pushes that force, delete, or push tags to the maintainer. See
[contributing](docs/contributing.md).

## Performance work

- Follow the [HTTP comparison protocol](bench/m13/protocol.md) and [remote measurement procedure](bench/m13/remote.md).
- Compare equivalent externally observable work under equal resource budgets. Use idiomatic implementations and give every candidate the same tuning opportunity.
- Preserve raw output, failures, build provenance, and all repetitions. Do not discard unfavorable results or tune acceptance rules after seeing the outcome.
- Distinguish smoke tests and local diagnostics from comparative measurements. Do not infer general API performance from fixed-response workloads, or sufficient load-generator headroom from successful requests alone.
- Optimize from a reproducible baseline and a demonstrated bottleneck. Recheck correctness, tail latency, memory, and other affected workloads after a change.
