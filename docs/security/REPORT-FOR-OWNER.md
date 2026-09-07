# Security review and fixes: Raffle contracts

Hi. A friend flagged that the raffle contracts might have problems, so I ran a full adversarial
review. There were more issues than the original note found, including four that let someone take
or permanently freeze funds. This document explains each one and what changed.

Everything here is reproducible. Every finding has a test that used to perform the attack
successfully, and now asserts the attack is rejected. `forge test` runs them.

**Nothing in here is a criticism of the design.** Most of these are cases where the documentation
described the correct behaviour and the code was missing a guard. The `IRandomnessProvider`
interface you wrote was exactly the right shape and is now wired up as intended.

---

## Before anything else: the live deployment

The deployed factory cannot be fixed. Neither it nor its clones are upgradeable, so the fixed
version has to go to a new address. Two things matter today, independently of this PR:

1. **Anyone who ever approved the deployed factory should set that approval back to zero.**
   Finding 3 below is exploitable against them right now, with no raffle running and no money in
   the contract. Closing the raffle did not close this.
2. **No new raffles should be created on the deployed factory.** Any raffle created there is born
   with all of the issues below.

---

## What changed, at a glance

| | Before | After |
|---|---|---|
| Lifecycle | 7 overlapping flags, "has this succeeded?" recomputed from the clock | 4 explicit states, every function names the one it requires |
| Randomness | past block hashes, drawn inside `finalize()` | Chainlink VRF, requested at settlement, drawn in a separate call |
| Ledgers | one mapping holding two different tokens | three ledgers, one token each |
| Protocol fee | pushed during settlement, read live, cap 100% | pulled, frozen at creation, cap 10% |
| Creating for others | any caller could name any seller | the seller must be the caller |
| Stuck funds | several permanent-lock paths | three escape hatches, all refunding |
| Tests | 53, no invariants | 216, including two solvency invariants and a Base Sepolia fork suite |

**Test results:** 212 tests across 12 suites, all passing on the default build profile, plus 4
fork tests that run the provider against the real Chainlink coordinator on Base Sepolia.
`Raffle.sol`, `RaffleFactory.sol` and `ChainlinkVRFProvider.sol` are at 100% line, statement,
branch and function coverage.
Both solvency invariants hold over 8,192 fuzz calls each, and survived a 131,072-call stress run.

---

## The nine serious findings

### 1. Buyers could take their money back and keep their tickets in the draw
**Critical.** `claimRefund()` checked only whether the raffle had succeeded, and before the
deadline that answer is always no. So refunds worked during the sale. Worse, a refund reset only
the caller's ticket count, leaving their entries in the draw and leaving `totalFunds` untouched.

Buy 98 tickets, refund, buy 2 more with the counter reset: the contract believes it sold out while
holding 2 tokens, and every entry belongs to you. Or buy all and refund all, and the seller's prize
is locked forever at no cost to the attacker.

**Fixed:** refunds require the settled `Failed` state.

### 2. The seller could take the prize back mid-sale and still get paid
**Critical.** `withdrawAsset()` had the same broken check. A seller could let the raffle sell out,
pull the prize one second before the deadline, then collect the proceeds too. Winners were recorded
but could not claim, and buyers could not refund because the raffle had "succeeded".

**Fixed:** prize withdrawal requires `Failed`. A seller may now `cancel()` while no tickets have
been sold, which covers the honest mistake without reopening the hole.

### 3. Anyone could raffle off your tokens
**Critical, and still live on the deployed version.** `createRaffle` let the caller name any
address as the seller and pulled the prize from that address. Anyone who had approved the factory
could have their tokens raffled off by a stranger, priced in a worthless token the stranger
printed, with a two second window, and claimed.

**Fixed:** the named seller must equal the caller, or be zero. The signature is unchanged, so the
epoch solver keeps working. Its approve and create calls come from the same account, so they
already satisfy this.

> Separately: `epoch-multiprotocol-solver/src/components/raffles/index.ts` reads the seller from
> `JSON.parse(extraData)` without checking it against the intent's user. Worth a look by whoever
> owns that service.

### 4. Anyone could work out the winners and only settle when they won
**Critical.** Winners came from past block hashes, which are public before a transaction is sent,
and `finalize()` was permissionless with no deadline. A ticket holder could simulate the draw each
block and submit only when favourable. Free retries every two seconds.

Measured: someone holding a third of the tickets waited 24 blocks and took every prize. Someone
who settled honestly at the first opportunity won nothing.

The reasoning in the design doc was that past blocks are safer than future ones because nobody can
change them. That is true and it is not the problem. Nobody needed to change a hash, only to
choose which one counted.

**Fixed:** `finalize()` settles the sale and requests a seed. A separate `drawWinners()` picks the
winners once the seed arrives. The seed does not exist when `finalize()` is sent, so there is
nothing to shop for.

### 5. One number held two different currencies
**High.** `pendingWithdrawals` stored the seller's proceeds in the payment token and winners'
prizes in the prize token, in the same mapping. A seller who won claimed the sum in the prize
token, and an honest co-winner got nothing. An attacker could also gift the seller a single ticket
and, if it won, permanently lock the seller's proceeds.

**Fixed:** `sellerProceeds`, `protocolFeeOwed` and `pendingPrize`, one token each, never combined.

### 6. The owner could take 100% of a raffle's proceeds after it sold out
**High.** The fee was read from the factory at settlement, not at creation, and the cap was 100%.

**Fixed:** fee and recipient are frozen when the raffle is created, and the cap is a 10% constant
neither of us can raise.

### 7. The deploy script gave ownership away and set the wrong fee
**High.** `new RaffleFactory{salt: ...}` inside a broadcast routes through the CREATE2 deployer
proxy, so `Ownable(msg.sender)` made that proxy the owner. The deployed factory can never have its
fee or recipient changed by anyone. The script also defaulted to 10 basis points with a comment
saying 2%, while the README says 200.

**Fixed:** the owner is an explicit constructor argument, the default is 200 to match the README,
and the script asserts after deploying that ownership landed where intended.

> **I need your answer on the fee.** I used 200 because that is what the README says. If 0.1% was
> deliberate, it is one environment variable.

### 8. A single failed transfer could freeze everything forever
**High.** The protocol fee was pushed during `finalize()`. If the payment token refused the fee
recipient, settlement reverted permanently, and refunds were already closed because the raffle had
"succeeded". All buyer funds and the prize, locked with no way out.

**Fixed:** nothing is pushed during settlement. The fee is owed and pulled later. A blocked fee
recipient now only blocks the fee.

### 9. Unusual tokens broke the accounting
**High.** `totalFunds` was credited the nominal amount without checking what actually arrived. A
token taking a 1% cut left the contract unable to pay everyone, and the last claimant lost their
whole balance rather than 1%.

**Fixed:** every inbound transfer is checked against the balance delta, at purchase and at
creation. Tokens that do not deliver exactly are rejected.

> **Accepted, not fixed:** rebasing tokens. No deposit-time check can see a rebase that happens
> later. Documented as a known limitation.

---

## The other nineteen

| ID | Severity | Finding | Status |
|---|---|---|---|
| R-10 | Medium | Implementation and rogue clones could be initialized by anyone | Fixed, `Initializable` plus an immutable factory |
| R-11 | Medium | Three different definitions of "ended" collided at the deadline second | Fixed, one half-open window |
| R-12 | Medium | Collision fallback paid one ticket twice and excluded another | Fixed, drawn without replacement |
| R-13 | Medium | A zero block hash collapsed the draw onto a few tickets | Fixed, zero seed rejected |
| R-14 | Medium | One storage write per ticket, so large purchases exceed the block limit | **Deferred**, measured at 22,355 gas per ticket |
| R-15 | Low | A prize smaller than the winner count produced unclaimable winners | Fixed, rejected at creation |
| R-16 | Low | No validation of start time, duration, or prize size | Fixed |
| R-17 | Low | Single-step ownership, no timelock | Fixed to `Ownable2Step`; the timelock is a deployment choice |
| R-18 | Low | State written after external calls in three places | Fixed |
| R-19 | Low | No way to recover tokens sent by mistake | Fixed, and it can never touch the prize or the payments |
| R-20 | Low | Per-address limit counted the recipient, so a payer routed around it | Removed, and the docs no longer claim it prevents domination |
| R-21 | Low | An Ankr API key committed in `foundry.toml` | Removed from the working tree. **Rotate it.** History is your call |
| R-22 | Low | `forge-std` was not a declared dependency | Fixed, installed explicitly |
| R-23 | Info | The randomness hook was dead code the docs advertised | Fixed, it is now the real seam |
| R-24 | Info | A read-only reentrancy window during the fee push | Gone, settlement makes no external call |
| R-25 | Info | Documentation contradicted the code in about twenty places | Rewritten from the code |
| R-26 | Info | 64% branch coverage, no invariants, tests passing because of bugs | 212 tests, 100% branch coverage, two invariants, spec tests |
| R-27 | Info | Unbounded registry getter | Fixed, paginated |
| R-28 | Info | Draw cost near the block limit | Fixed, cap lowered to 100, measured at 6M gas |

---

## Behaviour changes worth your review

These are deliberate and each is arguable. Push back on any of them individually.

- **No refunds before a raffle settles.** Matches what the docs always said.
- **The seller may cancel only while zero tickets are sold.** Cancel-any-time was rejected because
  it hands the seller a rug.
- **Settlement takes two transactions.** Unavoidable with real randomness.
- **A raffle can now fail after its deadline**, if the seed never arrives or nobody settles it.
- **The per-address ticket limit is gone.** It never worked.
- **Maximum winners is 100, was 200.** A 200-winner draw measured too close to the block limit.
- **The same token may be used for prize and payment.** Safe now that the ledgers are separate.
- **A seller may hold tickets in their own raffle.** Harmless once the ledgers are separate and the
  draw cannot be steered. Say the word and I will forbid it.

---

## Two bugs I introduced, and fixed

Recorded because you should not have to find them in review.

**The contract did not compile.** My rewrite grew the initialization event to thirteen arguments
with the IR pipeline off, which ran the stack out. I claimed it compiled cleanly; it did not. The
stale tests were failing type-checking first, so the compiler never reached code generation. Two
reviewers caught it independently. Fixed by splitting the event rather than enabling `via_ir`,
which would have changed deployed bytecode for a build-configuration reason.

**A fix of mine created a permanent lock.** I stopped `failOnTimeout()` firing when a seed had
actually arrived, to remove a race with `drawWinners()`. But a draw too large to fit in a block
would then revert forever while the timeout refused to fire. That is the same class of bug as
finding 8. Fixed by lowering the winner cap and adding a 30 day backstop past which the timeout
fires unconditionally.

---

## A second review, of the fixes

Once the rewrite was green, the remediated tree was reviewed again from scratch. That review found
no new way to steal or lock funds, and five smaller things. All five are fixed here; the full
write-up with per-finding triage is in `FINDINGS.md`, and the reasoning in `DECISIONS.md`
D-19 to D-23.

| | What it was | What changed |
|---|---|---|
| C2-01 | Money coming in was measured, money going out was not. A token can be exact in `transferFrom` and misbehave in `transfer`, so it clears every check and then short-pays a winner, a refund, or you | Every payout goes through one helper that requires the escrow to fall by exactly the amount owed. A token that debits more is refused, because the surplus is another claimant's money. One that moves nothing is refused, because it used to mark the debt settled anyway |
| C2-02 | The deploy script printed the "now wire the provider" step and stopped. Miss it and no raffle can settle for seven days | The script does it itself when it can, and `script/SetupProvider.s.sol` refuses to pass unless the wiring and the Chainlink subscription are both real |
| C2-03 | The provider's factory pointer could be changed later, which made every existing raffle unknown to it | Set once, and never again. A second factory gets its own provider |
| C2-04 | A raffle could be listed with an address that is not a token at all | Both token addresses must contain code |
| C2-05 | The provider stored any answer the coordinator sent, including for requests it never made | It records only its own requests, and rejects an empty answer by name |

Two of those fixes are deliberately not the ones the review proposed, and one thing it asked for
was left undone on purpose:

- For **C2-01** it proposed checking what the *receiver* nets and reverting on any shortfall. That
  would make payouts on such a token revert forever with no other exit, which is finding 8 above,
  reintroduced. The check measures the escrow instead: it refuses to pay one person out of
  another's money, and tolerates a haircut the token imposes on itself. The remaining gap is a
  token that quietly delivers less — closing that needs a list of approved tokens, which is a
  product decision, not a code one. It is question 7 below.
- For **C2-03** it proposed freezing the binding as a way to stop an admin stranding raffles. It
  does not: `setRequestConfig` has the same effect, and gas lanes genuinely change, so freezing it
  too would trade a real operational need for a risk the refund path already bounds. The binding
  is frozen anyway because it removes a class of accident, but the honest answer to "can the
  provider owner stall raffles" is still yes, and it is worth knowing that.
- **`assetToken != paymentToken`**, proposed in the original remediation plan, was not added. With
  the ledgers separated it is no longer needed: a raffle using one token for both roles is solvent
  by construction. Recorded so it reads as a decision rather than an oversight.

Eleven regression tests in `test/audit/CodexV2.t.sol` cover all of it, including one that stalls
two refunds against a hostile token, lifts the token's tax, and then pays both buyers in full — the
point being that the guard keeps the debt recoverable rather than pretending it was paid. Another
exercises the C2-03 residual directly: the provider owner stalls a settlement through
`setRequestConfig`, buyers refund anyway, and correcting the config restores settlement.

### The Chainlink integration, checked against Chainlink

The provider declares the VRF coordinator interface locally rather than pulling in
`@chainlink/contracts`. That meant every test agreed with us by construction — the mock was
written to match our own interface — so a wrong interface would first have shown up on-chain, as a
rejected request that stalls every raffle.

It was checked against Chainlink's published source, and the request struct, both function
signatures and the `extraArgs` encoding all match. `test/audit/VRFConformance.t.sol` now pins that
offline, against the bytes the provider actually sends, so drift fails in CI.

Reading the coordinator turned up one thing worth acting on. Chainlink deletes the request record
*before* calling us back and charges the subscription either way, so a callback that runs out of
gas loses that random number permanently — it cannot be retried. Fulfilment costs 27,201 gas, but
nothing stopped the owner configuring a limit below that, which would have burned the subscription
and stranded the raffle until it timed out. There is now a 100,000 floor, enforced wherever the
limit can be set.

It also confirmed that splitting settlement into `finalize()` and `drawWinners()` was load-bearing
rather than tidy: a full draw at the 100-winner cap measures 3.88M gas against Chainlink's 2.5M
callback ceiling, so picking winners inside the callback — which is roughly what the original
design did — could not have worked at the cap.

The contract was then walked against Chainlink's eight published security considerations. Six are
satisfied outright. One is hardened: confirmations now have a floor of three, because Base lets a
consumer ask for zero and zero makes a validator re-roll cheap. Two are deliberate deviations,
both written up in `DECISIONS.md` D-25 — the one worth your attention is that past 30 days the
timeout can void a raffle whose seed already arrived. That is a way to discard an unfavourable
outcome, kept only because the alternative is stranding everyone permanently, and it voids the
raffle rather than looting it: buyers are refunded and you get the prize back.

**Cost:** one VRF request per raffle that sells out — a raffle that misses its target never asks.
On Base that is roughly 178,000 gas plus a 50% premium paying in LINK, so cents per settled
raffle. The real constraint is keeping the subscription buffered above the worst case for your gas
lane. Base Sepolia LINK is free from Chainlink's faucet.

---

## What I need from you

1. **The fee: 2% or 0.1%?** The README and the script disagree by twenty times.
2. **Who owns the factory?** It is now an explicit argument. A Safe behind a timelock for real
   money.
3. **Who owns and funds the Chainlink subscription?** Needed before a sold-out raffle can settle.
   Nothing locks without it; raffles time out after a day and refund.
4. **Rotate the Ankr key**, and decide whether to purge it from history.
5. **Should an unclaimed prize be recoverable?** A winner who loses their wallet burns their share
   permanently today. My instinct is to leave it, since any sweep gives the seller a reason to hope
   winners are slow, but it should be a decision.
6. **Refunds go to the ticket holder, not the payer.** Unchanged from your original. Worth
   confirming that is what you want for gifted tickets.
7. **Do we curate which tokens may be listed?** Listing is permissionless today, and a seller
   picks both tokens. The payout guard stops one claimant being paid out of another's escrow, but
   a token that quietly delivers less than it debits still short-changes the receiver. An
   owner-controlled allowlist closes it and turns an open marketplace into a curated one. My
   recommendation is to leave it open on testnet and add the list before real money (B-7).
8. **The provider owner can stall settlement.** Not steal — stall. A bad key hash or an unfunded
   subscription makes `finalize()` revert until it is corrected, and raffles then refund. Worth
   confirming you are happy for that to sit with the same person who owns the factory (B-8).

More detail on all of these in `OPEN-QUESTIONS.md`.

---

## Verifying this yourself

```bash
forge test                                    # 212 tests
forge test --match-path 'test/audit/*'        # the security regression suite
FOUNDRY_INVARIANT_RUNS=128 FOUNDRY_INVARIANT_DEPTH=64 \
  forge test --match-contract TokensInvariantTest
```

Every `test_Fixed_*` performs an attack that used to work and asserts it is now rejected with a
specific error. If one of them ever fails, a vulnerability has come back. `test/audit/Spec.t.sol`
holds the documentation to the code: all eight of those failed before this change and pass now.

Gas, measured:

| Operation | Cost |
|---|---|
| `buyTickets`, per ticket | 22,355 |
| `finalize()` | 94k to 142k |
| `drawWinners()`, 100 winners | 3.84M to 4.98M |
| `claimPrize()` | 51k |

Reading order: this file, then `DECISIONS.md` for why each choice was made, then `FINDINGS.md` for
the full findings with the original exploit details, then `test/audit/` for the proofs.
