# Findings register

Every security finding for these contracts, in one place. **IDs are stable and rows are never
deleted** — they are cited from commit messages, test names and the PR description.

| | |
|---|---|
| **Round 1** | 2026-09-03. Five independent adversarial agents (lifecycle, randomness, factory/admin, token/solvency, spec-conformance), cross-checked against the external review archived verbatim in `external-reviews/`. Verdict at the time: do not deploy — four independent critical paths stole or locked funds. |
| **Round 2** | 2026-09-07. An independent review of the *remediated* tree (`C2-*`). No new theft path; five smaller issues, all fixed. |
| **Round 3** | 2026-09-07. Conformance against Chainlink's published source and its eight security considerations, then against the live Base Sepolia coordinator. |
| **Now** | 34 findings: 31 fixed, 1 deferred, 2 accepted with tests asserting the residual. 212 tests offline plus 4 fork tests; 100% line, statement, branch and function coverage on all three production contracts. |

**Status is against the working tree.** Replace each with `Fixed (<sha>)` once the PR lands.
Where a status names a `B-` or `C-` item, that part needs a person, not code — see
`OPEN-QUESTIONS.md`. The reasoning behind every fix is in `DECISIONS.md` (D-01 to D-26).

**Proofs live in `test/audit/`, not here.** Each exploit is still performed step for step; only
the assertions were inverted once it was fixed. A `test_Fixed_*` failing means the vulnerability
is back. That is why the per-finding narratives from the original register are not reproduced:
a runnable test cannot drift out of date, and prose about deleted code can.

## Round 1 — the original audit

| ID | Sev | Title | Proof (`test/audit/`) | Status |
|---|---|---|---|---|
| R-01 | Critical | `claimRefund()` works before finalization and never unwinds accounting | Factory, Lifecycle, Tokens | Fixed |
| R-02 | Critical | Seller can `withdrawAsset()` while the raffle is live, then still collect proceeds | Factory, Lifecycle, Tokens | Fixed |
| R-03 | Critical | Anyone can spend any address's factory approval via `createRaffle(raffleSeller=victim)` | Factory, Lifecycle, Tokens | Fixed |
| R-04 | Critical | Winner draw is computable before `finalize()`; permissionless finalizer grinds blocks with no deadline | Lifecycle, Randomness | Fixed |
| R-05 | High | One `pendingWithdrawals` mapping holds seller payout (payment token) and winner prizes (asset token) | Factory, Lifecycle, Randomness | Fixed |
| R-06 | High | Factory owner can set the fee to 100 % after tickets are sold; fee is read at finalize time | Factory, Lifecycle | Fixed |
| R-07 | High | Deploy script makes the CREATE2 deployer proxy the factory owner (admin bricked); fee default is 0.1 % not 2 % | Factory | Fixed (fee value: B-1) |
| R-08 | High | Fee is pushed inside `finalize()`; any revert there locks every fund forever (no escape hatch) | Factory, Lifecycle, Tokens | Fixed |
| R-09 | High (token-dependent) | Nominal accounting: fee-on-transfer and rebasing tokens make the contract insolvent | Tokens | Fixed in part — residual in C2-01 / B-7 |
| R-10 | Medium | Implementation contract and rogue clones can be initialized by anyone; `onlyFactory` is never used | Factory, Lifecycle, Spec | Fixed |
| R-11 | Medium | Three different definitions of "ended" (`<=`, `>`, `>=`) collide at `timestamp == endTime` | Lifecycle, Spec | Fixed |
| R-12 | Medium | Collision fallback pays one ticket index twice and excludes another | Randomness | Fixed |
| R-13 | Medium | A zero `blockhash` collapses the draw to tickets 0,1,2,3,3,3,… | Randomness | Fixed |
| R-14 | Medium | `buyTickets` does one storage write per ticket; the 10,000 per-address cap is unreachable in one transaction | Tokens | **Deferred** (D-13, C-5) |
| R-15 | Low | `assetAmount < winnersCount` produces winners whose `claimPrize()` always reverts | Randomness | Fixed |
| R-16 | Low | Parameter validation gaps in `initialize()` (start/end in the past, same token for both roles, no code check on payment token) | Factory | Fixed (completed by C2-04) |
| R-17 | Low | Single-step `Ownable`, no timelock, contrary to README | — | Fixed (`Ownable2Step`); timelock: B-2 |
| R-18 | Low | Checks-effects-interactions violations in `withdrawAsset`, `buyTickets`, `finalize` | — | Fixed |
| R-19 | Low | No recovery for stranded tokens (accidental transfers, positive-rebase dust) | Tokens | Fixed |
| R-20 | Low | Per-address limit is keyed on `recipient`, so one payer bypasses it; docs call it anti-domination | Spec | Fixed |
| R-21 | Low | Committed RPC URL with an embedded Ankr API key in `foundry.toml` | — | Fixed in tree; history: B-4 |
| R-22 | Low | `forge-std` is not a declared dependency; `lib/` is gitignored while also a submodule path | — | Fixed |
| R-23 | Info | `IRandomnessProvider` / `setRandomnessProvider` are dead code; docs advertise VRF readiness | Randomness, Spec | Fixed |
| R-24 | Info | Read-only reentrancy window during the fee push (`finalized && succeeded && winners == []`) | Tokens | Fixed |
| R-25 | Info | Documentation and NatSpec contradict the code in at least 20 places | Spec | Fixed |
| R-26 | Info | Existing test suite gives false assurance (64 % branch coverage, no invariants, several tests pass only because of bugs) | — | Fixed |
| R-27 | Info | Registry is permissionless and `getAllRaffles()` is unbounded | Factory | Fixed |
| R-28 | Info | `finalize()` costs ~9 to 12 M gas at 200 winners; chains with a lower block limit cannot finalize | Randomness, Tokens | Fixed |

## Round 2 — review of the fixes

Full triage, including the two places the proposed fix was not the one taken, is in `DECISIONS.md`
D-19 to D-23. Proofs in `test/audit/CodexV2.t.sol`.

| ID | Sev | Title | Status |
|---|---|---|---|
| C2-01 | High, token-dependent | Outbound transfer taxes can short-pay liabilities | Fixed in part (D-19); residual is B-7 |
| C2-02 | Medium | Deployment leaves VRF wiring as an unverified manual step | Fixed (D-22) |
| C2-03 | Medium | Provider owner can disable existing raffles' VRF requests | Fixed (D-20); residual is B-8 |
| C2-04 | **Low** | Payment-token code is not validated at creation | Fixed (D-21) |
| C2-05 | Low | VRF provider records unknown coordinator callback IDs | Fixed (D-23) |
| C2-06 | Low | Security record and decision documents are stale or contradictory | Fixed (this update) |

## Round 3 — Chainlink conformance

Not findings against our code so much as verification that the integration is real. Reasoning in
`DECISIONS.md` D-24 to D-26; proofs in `test/audit/VRFConformance.t.sol` and `test/fork/`.

| Check | Result |
|---|---|
| Request struct, field order, selector, `extraArgs` tag | Match Chainlink's published source; pinned offline |
| Callback signature | Matches `VRFConsumerBaseV2Plus`; pinned offline |
| Chainlink's 8 security considerations | 6 satisfied, 1 hardened (`MIN_REQUEST_CONFIRMATIONS`), 2 deliberate deviations (D-25) |
| Real coordinator on Base Sepolia | Accepts a request built by this contract (D-26) |
| Callback gas | Fulfilment 27,201 gas; floor of 100,000 enforced. A draw at the winner cap is 3.88M, above Chainlink's 2.5M ceiling — which is why the draw is a separate transaction |

**One assumption corrected by the fork test.** A key hash no node serves is *accepted* on-chain and
silently never answered; only an unknown subscription reverts. The two need different hatches. See
D-26.

## Accepted, not fixed

- **Rebasing tokens.** A deposit-time balance check cannot see a later rebase. Do not list them.
- **Receiver-side token haircuts** (C2-01 residual). A token that debits the escrow exactly but
  delivers less to the receiver is not detectable from inside. Needs curation — B-7.
- **`R-14` ticket storage**, deferred: one storage slot per ticket, ~22.4k gas each. Split large
  purchases. D-13, C-5.
- **The 30-day draw deadline** can void a raffle whose seed arrived, which deviates from Chainlink
  guidance. Kept because the alternative is a permanent lock; it voids rather than loots. D-25.

## Why the bugs existed

The individual findings cluster into eight design decisions. Fixing a theme fixes every finding under it; patching findings one by one will leave siblings behind.

1. **No explicit state machine.** "Succeeded" is recomputed live from `block.timestamp` and `totalFunds` (`Raffle.sol:427-433`) and is unconditionally `false` before `endTime`. Exit functions gate on this live predicate instead of on the frozen `finalized`/`_succeededState`. That single choice produces R-01, R-02, R-08 and R-11. `MECHANISMS.md:214` claims stored state prevents manipulation; it only does so *after* `finalize()`.
2. **Accounting only ever increments.** `claimRefund()` zeroes the caller's counter but never touches `totalFunds`, `totalTickets` or `ticketHolders` (`Raffle.sol:265` vs `:215-222`). Combined with theme 1 this turns a gating bug into free tickets, a prize theft and a zero-cost permanent lock (R-01).
3. **One mapping for two currencies.** `pendingWithdrawals` is written in payment-token units for the seller (`:244`) and asset-token units for winners (`:411`); nothing stops the seller from holding tickets (R-05).
4. **An ERC20 allowance was treated as authorization.** The "custom seller" feature (`docs/PRODUCT_FLOW_AND_DECISIONS.md:38`) lets the *caller* choose both the address the prize is pulled from and every economic parameter (`RaffleFactory.sol:94-97,115`). On a public chain the caller is anyone (R-03).
5. **Randomness from data that is public before the transaction.** Past block hashes are known to every observer, and `finalize()` is permissionless with no deadline, so whoever sends the transaction chooses the outcome (R-04). The collision loop and the missing zero-hash check are secondary flaws of the same routine (R-12, R-13). The docs argue past blocks are *safer* than future blocks; the opposite holds when timing is free.
6. **Nominal instead of measured accounting.** `totalFunds += cost` and `assetAmount` are trusted rather than measured as balance deltas (`Raffle.sol:221-222`, `RaffleFactory.sol:115`). Any token that does not deliver exactly what was sent breaks solvency (R-09).
7. **Settlement depends on live global config and a push transfer.** `feeBps`/`feeRecipient` are read at finalize time and the fee is pushed inside the only state transition (`Raffle.sol:240-250`). This gives the owner a 100 % rug (R-06) and gives any reverting token a permanent lock, because theme 1 leaves no failure exit (R-08).
8. **Clone pattern without the standard guards, and deployment tooling semantics.** No `Initializable`, no implementation lock, `factory = msg.sender` (R-10). `new X{salt:…}` inside a Forge broadcast routes through the CREATE2 proxy, which then becomes `Ownable`'s `msg.sender` (R-07).

Underlying all of it: the documentation was written from intent and the tests were written to pass the code as it is. No test encodes a promise from the docs, and no invariant test exists (R-25, R-26). That is why all of the above survived a 53-test green suite.

## The external review, claim by claim

The friend's review (archived verbatim in `external-reviews/`) looked at `Raffle.sol` only. Verdicts after seeing the factory, script and tests:

| Their ID | Verdict | Mapped to | Note |
|---|---|---|---|
| C-01 | Confirmed, worse than stated | R-01 | They missed the refund-then-rebuy trick (counter reset) and the zero-cost permanent lock. |
| C-02 | Confirmed | R-02 | |
| C-03 | Refuted as stated, point stands | R-09 | Factory funds the clone atomically in the same tx, so escrow is enforced; but the amount is never measured. |
| H-01 | Confirmed, upgraded to Critical | R-04 | No miner needed; no deadline; measured 2 to 46 blocks to win. |
| H-02 | Confirmed with nuance | R-10 | Clones are safe (atomic init); the implementation and rogue clones are hijackable. |
| H-03 | Confirmed | R-09 | Six PoCs. |
| H-04 | Mostly confirmed | R-06, R-08 | The `feeBps > 10000` underflow claim is refuted (rejected by constructor and setter). 100 % fee, mid-raffle change, reverting recipient: all confirmed. Zero recipient: constructor forbids it. |
| M-01 | Partially correct | R-12 | Double-pay of a ticket index confirmed (20 % of draws at N=W=5); adjacency bias is conditional only. |
| M-02 | Confirmed | R-08 | |
| M-03 | Confirmed (Low) | R-15 | |
| M-04 | Confirmed with numbers | R-14 | 1,335 tickets max per 30 M block. |
| M-05 | Confirmed | R-13 | Zero-hash degenerate case proven; Base sequencer control noted. |
| Low: timing | Partially correct | R-11 | Harmless alone, exploitable in combination; invalidates timestamp-based fixes. |
| Low: per-address bypass | Confirmed | R-20 | |
| Low: unused `ETH_ADDRESS`/`onlyFactory` | Confirmed | R-25, R-10 | |
| Low: `claimPrize` scan | Confirmed, gas only | R-28 | 164 k gas at 200 winners. |
| Low: token not validated as contract | Partially correct | R-16 | OZ 5.5 rejects a codeless asset token; payment token slips through harmlessly. |
| Low: no sweep | Confirmed | R-19 | |
| Low: `startTime` in past | Confirmed | R-16 | Enables R-03 in two blocks. |
| Low: same token | Confirmed, conditional | R-16, R-09 | Solvent in honest flows; insolvent under R-05 or fee-on-transfer. |

**Missed by the external review**: R-03 (approval abuse, Critical), R-05 (shared ledger, High), R-07 (deploy ownership, High), R-21 (committed key), R-22, R-24, the no-deadline aggravator of R-04, and the two worse variants of C-01.
