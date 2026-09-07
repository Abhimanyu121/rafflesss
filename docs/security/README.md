# docs/security

Security record for the Raffle contracts. **Five files. Read the one you need, not all of them.**

| I want to… | Read |
|---|---|
| Hand this to the repo owner, or write the PR | `REPORT-FOR-OWNER.md` |
| Know whether a specific bug is fixed | `FINDINGS.md` — 34 findings, stable IDs, status |
| Know *why* the code is the way it is, before changing it | `DECISIONS.md` — D-01 to D-26 |
| Know what still needs a human answer | `OPEN-QUESTIONS.md` |
| See what a third party actually said | `external-reviews/`, verbatim and dated |
| Reproduce an exploit | `../../test/audit/`, and `../../test/fork/` for the live Chainlink check |
| Learn the vocabulary first | `../../CONTEXT.md` |

## Status

31 of 34 findings fixed, 1 deferred (R-14), 2 accepted with tests that assert the residual.
212 tests offline plus 4 Base Sepolia fork tests; 100% line, statement, branch and function
coverage on `Raffle.sol`, `RaffleFactory.sol` and `ChainlinkVRFProvider.sol`.

**Not audited.** Reviewed three times, twice adversarially, but no independent professional audit,
and the fixes and their tests share an author. See `OPEN-QUESTIONS.md` for what blocks mainnet.

## Reading a test name

`test_Fixed_*` performs an attack that used to succeed and asserts it is now rejected.
`test_NotExploitable_*` is an attack that never worked. `test_Accepted_*` is a weakness we chose
not to fix, asserting the current behaviour honestly. `test_Conformance_*` pins us to Chainlink's
ABI. `test_Validation_*` fires an input guard. `Spec.t.sol` holds the documentation to the code.

**If a `test_Fixed_*` ever fails, a vulnerability has been reintroduced.** Do not delete these.

## How this record is kept

Four rules, which are what make it still useful in six months to someone who was not here:

**Findings get a stable ID and are never deleted.** IDs are cited from commit messages, test names
and PR descriptions. A fixed finding changes status; it does not disappear. A refuted one stays as
`Refuted` with the reason, so nobody re-investigates it.

**Every finding has a runnable proof.** A finding without a test is an opinion. The PoC is the only
description of a bug that cannot drift, because CI runs it. After a fix the same test is flipped to
assert the rejection and renamed `test_Exploit_*` → `test_Fixed_*`. That turns the audit into
permanent regression coverage, and it is why `FINDINGS.md` carries no per-finding narrative.

**One register is the source of truth for status.** Issues, PRs and notes should say
"see `FINDINGS.md#R-01`", not restate the finding. Two places that both claim to be current will
disagree within a week. External reviews are stored verbatim and never edited; our verdicts on
their claims live in `FINDINGS.md`.

**Secrets never enter the repo.** RPC URLs come from `.env` (gitignored) via `${BASE_RPC_URL}` in
`foundry.toml`. A key that was ever committed is rotated, not just removed.

Not yet set up, and worth adding: `forge test` on every PR with the audit suites required green
before any tag or deploy; the fork suite with an RPC secret; a CI grep that fails if an API key
reappears in `foundry.toml`; and Slither or Aderyn with a stored baseline so only *new* warnings
block a PR.
