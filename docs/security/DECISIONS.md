# Remediation decisions

Why the code is the way it is. Read this before changing lifecycle, settlement or randomness code:
each entry exists because the obvious alternative was tried, or was wrong for a reason that is not
visible from the code alone.

Finding IDs (`R-nn`, `C2-nn`) match `FINDINGS.md`. Decision IDs (`D-nn`) are cited from commit
messages and the PR description. D-01 to D-18 cover the original rewrite, D-19 to D-23 the review
of those fixes, D-24 to D-26 the Chainlink integration.

---

## Part 1: the principles we settled on

These emerged while working through individual findings, and each one closes a whole family of
bugs rather than a single line. They are the rules the fixed contract has to obey.

### P-1. A raffle is in exactly one named state, and every action names the state it needs

The contract currently has seven overlapping flags (`finalized`, `_succeededState`, `hasFailed()`,
`canFinalize()`, `winnersSet`, `assetWithdrawnBySeller`, and a live `_succeeded()` recomputed from
the clock) and no single idea of "what state is this raffle in". Four criticals come from that.

Replaced by four states: **Active**, **Randomness Pending**, **Succeeded**, **Failed**.
Refunds require Failed. Prize claims require Succeeded. Ticket sales require Active.

Closes R-01, R-02, and half of R-08 and R-11.

### P-2. Never decide from the clock what should be decided from the state

`_succeeded()` returns false at every moment before the deadline, which is what makes the refund
and prize-withdrawal buttons live during the sale. A time comparison is not a substitute for a
settled outcome, and R-11 shows that swapping one timestamp check for another still breaks.

### P-3. Terms are frozen when the raffle is created

Anything a raffle depends on that lives outside itself gets copied in at creation: the protocol
fee, the fee recipient, the randomness provider. The factory owner may change the defaults for
future raffles and never for one that is already selling tickets.

Applies to R-04 (provider) and R-06 (fee).

### P-4. Every wait has an escape hatch

If a raffle can end up waiting on something outside its control, there must be a way for anyone
to end that wait and return everyone's money. Otherwise a silent oracle, a paused token or a
blacklisted address locks the funds permanently, which is how R-08 traps money today.

### P-5. Separate "the raffle is over" from "here is who won"

Doing both in one transaction is what lets the caller choose the outcome. Splitting them means
the moment the result is fixed is no longer a moment anyone can pick.

---

## Part 2: decisions taken

### D-01 — Refunds only for a settled, failed raffle
**Finding:** R-01 (Critical). **Chosen:** no mid-sale cancellation.

**How it is solved.** `claimRefund()` requires the Failed state instead of asking whether the
raffle has succeeded. Since the state is only reachable after the deadline, refunds cannot be
taken during the sale, so refunded tickets can no longer stay in the draw and the contract can no
longer believe it holds money it has already paid out.

**Design decision.** We considered building a proper cancel-my-ticket feature that also removes
the entries from the draw and reduces the totals. Rejected: a raffle people can leave never
reaches an all-or-nothing target, because anyone can pull out the moment it looks like filling.
That fights the product's own core rule. If it is wanted later it is its own PR.

**Behaviour change.** Buyers can no longer get money back before the deadline. That is what the
documentation always said, and what the live deployment failed to do.

### D-02 — The prize is locked until the raffle settles, with one exception
**Finding:** R-02 (Critical). **Chosen:** seller may cancel only while zero tickets are sold.

**How it is solved.** `withdrawAsset()` requires the Failed state. Separately, a seller may cancel
their own raffle outright while no tickets have been sold, which moves it straight to Failed.

**Design decision.** Three options were on the table: no escape at all, cancel-while-empty, and
cancel-any-time-with-refunds. The third was refused even though we have latitude to change product
behaviour, because it hands the seller a rug: they could kill any raffle that was filling in a way
they disliked. Cancel-while-empty solves the honest mistake, such as a mistyped end date, and its
safety condition is a single comparison an auditor can check at a glance.

**Also fixed here.** The withdrawal flag is now set before the tokens move, not after.

### D-03 — Randomness comes from Chainlink through the provider interface they already wrote
**Finding:** R-04 (Critical), and R-12 and R-13 as a consequence. **Chosen:** Chainlink VRF.

**How it is solved.** The raffle contains no `blockhash` call at all. `finalize()` settles only
whether the raffle sold out. If it did, the raffle enters Randomness Pending and asks its provider
for a number. A later `drawWinners()` call collects that number and picks the winners. If no answer
arrives within a day, anyone may fail the raffle so refunds open.

**Design decisions.**

- **Their `IRandomnessProvider` interface is used as designed** rather than replaced. It was
  already the right shape: ask now, collect later, zero means not ready. This is finishing their
  design, not overruling it.
- **A blockhash commit-to-a-future-block provider was proposed and then dropped.** It needed no
  subscription and would have let the fix deploy same-day, but leaving a weaker option in the repo
  invites someone to deploy it later when the reason is forgotten. One provider, one answer.
- **The provider address is frozen at creation** (P-3), so the owner cannot swap it mid-raffle.
- **A timeout is mandatory** (P-4). If the subscription runs dry, raffles refund rather than lock.

**Cost accepted.** A funded Chainlink subscription on Base is now a deployment prerequisite. The
coordinator address, key hash and subscription id are constructor arguments, not hardcoded.

**Behaviour change.** Settlement takes two transactions instead of one, and a raffle can now fail
after its deadline if randomness never arrives.

### D-04 — Winners are drawn from one seed, without replacement
**Finding:** R-12, R-13. **Chosen:** partial Fisher-Yates over a lazily-swapped virtual array.

**How it is solved.** One seed is stretched into as many picks as needed by hashing it with the
round number. Each round draws only from the tickets not yet drawn, exactly like dealing cards.
A zero seed is rejected outright.

**Design decision.** The existing rule that a person holding many tickets can win several prizes
is preserved deliberately, because that is the documented product behaviour. What changes is
narrower: a single **ticket** can no longer win twice, which the old collision fallback allowed in
roughly one draw in five. The neighbour bias, where the ticket after a winner quietly received
extra chances, disappears with it.

**Implementation note.** Only positions actually disturbed by a swap cost storage, so a three-winner
draw costs three writes whether the raffle has ten tickets or ten thousand.

---

## Part 3: still open

### R-03 — anyone can spend any address's approval to the factory (Critical)

Parked at the user's request, then unblocked by investigation. The blocking question was whether
anything legitimately creates raffles on someone else's behalf.

**What we found.** `epoch-multiprotocol-solver/src/components/raffles/index.ts` does pass a
caller-supplied seller. It emits an approval and a creation call in the same batch, so the approving
account and the named seller have to be the same address for the pull to succeed. In every working
configuration they already match.

**Recommendation awaiting confirmation:** require the named seller to equal the caller, or be zero.
The function signature is unchanged, so no legitimate call breaks. Only the attack breaks.

**Separately reportable.** That solver reads the seller straight out of `JSON.parse(extraData)` and
never checks it against the intent's user. Worth raising with whoever owns the solver.

---

## Part 4: not yet walked through

Serious: R-05 (one ledger holding two different tokens), R-06 (owner can take 100% of proceeds
after the sale), R-07 (deploy script gives ownership away and sets the wrong fee), R-08 (a failed
fee transfer locks everything), R-09 (fee-on-transfer and rebasing tokens break solvency).

Then the 19 smaller findings, to be covered in batches.

---

## Part 5: acted on outside the code

The deployed factory cannot be fixed. It is not upgradeable and neither are its clones, so the fixed
version has to be deployed fresh and the old address abandoned. Two things follow:

- **Anyone who ever approved the deployed factory should set that approval to zero.** R-03 is
  exploitable against them today, with no raffle running.
- **No new raffles should be created on the deployed factory.**

---

## Part 6: decisions taken to unblock implementation

Recorded after the walkthrough was paused so the fixes could be written. Each was taken on the
recommendation in `OPEN-QUESTIONS.md`. Any of them can be reversed on review.

| ID | Question | Chosen | Note |
|---|---|---|---|
| D-05 | R-03, how to stop approval theft | The named seller must equal the caller, or be zero | Keeps the function signature, so the epoch solver is unaffected. The prize is always pulled from the caller |
| D-06 | R-05, may a seller hold tickets | Yes | Harmless once the ledgers are separate and the draw cannot be steered |
| D-07 | Maximum protocol fee | 10% | A constant on both the factory and the raffle, not adjustable |
| D-08 | Wait for randomness before failing | 1 day | |
| D-09 | Raffle nobody ever settles | 30 day grace, then anyone may fail it | New `failIfAbandoned()` |
| D-10 | Restrict which tokens may be used | No allowlist | Measuring what actually arrives already rejects the dangerous case, and an allowlist would make creation permissioned |
| D-11 | Same token for prize and payment | Allowed | Three separate ledgers make it safe. `CONTEXT.md` corrected accordingly |
| D-12 | Per-address ticket limit | Removed | It never worked, since anyone can use a second wallet. A control people wrongly trust is worse than none |
| D-13 | Ticket storage refactor (R-14) | Deferred | Correct, but it touches the draw, which is already being rewritten. Concentrating both in one review is the larger risk. Still open |
| D-14 | Minimum raffle duration | 10 minutes | Also requires the start time not to be in the past |
| D-15 | Maximum winners | Kept at 200 | The blockhash reason is gone, but a bounded loop is still worth having |
| D-16 | Recover tokens sent by mistake | Added, seller only | Can never touch the prize or the payments |

### Defaults chosen so implementation could proceed, for the owner to confirm

- **B-1, the fee.** Set to 200 basis points, matching `README.md`, rather than the 10 the old
  script used. The script, the comment and the README now agree. If 0.1% was intended, one
  environment variable changes it.
- **B-2, the owner.** Now an explicit constructor argument rather than `msg.sender`, so the
  CREATE2 proxy can never end up owning the factory. The deploy script reads `FACTORY_OWNER`
  and asserts afterwards that ownership landed where intended.
- **CREATE2 salt removed** from the deploy script. Deterministic addresses were not needed, and
  the salt is what routed deployment through the proxy in the first place.

### D-17 — Two fixes found by the test rewrite, applied

**Stack too deep in `initialize()`.** Two agents independently found that `src/Raffle.sol` did not
compile under the repo's own foundry profile: the `Initialized` event had grown to thirteen
arguments and `via_ir` is off. My earlier "src compiles cleanly" claim was wrong, because the
stale test files failed type checking first and the compiler never reached code generation.

Fixed by splitting the event into `RaffleInitialized` and `TermsFrozen` rather than by turning on
`via_ir`, which would have changed the deployed bytecode for a build-configuration reason. The
rename also removes an ABI clash with OpenZeppelin `Initializable`'s own `Initialized` event.

**A race between `failOnTimeout()` and `drawWinners()`.** Once the timeout elapsed, a seed that
arrived a second late could be beaten by whoever called first, refunding a sale that had valid
randomness. `failOnTimeout()` now checks, in a try/catch, that the seed is still absent and
reverts otherwise. A provider that cannot answer a view is treated as broken, so the escape hatch
survives. The outcome no longer depends on call order.

Also applied: `getRaffles` clamps instead of overflowing, and a dead zero-owner check was removed
from the factory constructor since `Ownable` rejects that first.

### D-18 — A lock I introduced myself, and the fix

The agent converting the randomness proofs measured a 200-winner draw at roughly 28M gas. That
does not fit a 30M block on every chain, and it turned my own D-17 race fix into a permanent lock:

- `drawWinners()` would always revert, because the draw could not fit in a block.
- `failOnTimeout()` would refuse to fire, because it now required the seed to still be absent and
  the seed had in fact arrived.
- The raffle would sit in `RandomnessPending` forever with everyone's money inside.

This is the same class of bug as R-08, the one this whole rewrite exists to remove, reintroduced
by a fix for something else. Worth recording plainly rather than quietly patching.

Three changes:

- **`MAX_WINNERS_COUNT` lowered from 200 to 100.** Measured at the new ceiling, a full draw costs
  about 6M gas and `claimPrize` 51k, which leaves real margin inside a 30M block. The old value
  sat close enough to the limit that a modest gas-schedule change could have crossed it.
- **New `DRAW_DEADLINE` of 30 days.** Past it, `failOnTimeout()` fires unconditionally. Inside the
  window the "a seed arrived, draw it" guard still applies, so the ordinary race stays closed. A
  raffle that genuinely cannot be drawn now refunds instead of stranding.
- **`FINALIZE_GRACE` lowered from 30 days to 7.** A provider that reverts on request leaves the
  raffle in `Active`, so this constant is also how long a broken oracle costs buyers. One day for
  a silent provider against thirty for a reverting one was an asymmetry nobody chose.

**The lesson for review.** Every guard that makes an outcome stricter should be checked against the
question "what if the action this now forces can never succeed?". A guard that removes a race can
create a deadlock, and a deadlock is worse than the race.

---

## Part 3: decisions from the follow-up review of the fixes

Round 2 in `FINDINGS.md` is a second review, run against the remediated tree rather than the
original. It found no new theft path, and five smaller things. What follows is what was done
about each and why, including the two places where the proposed fix was not the one taken.

### D-19 — A payout measures what leaves the escrow, not what the receiver nets

**Finding C2-01.** Money coming in is measured: `buyTickets` and the factory's escrow both compare
the balance before and after, so a token that skims on the way in is rejected on the spot. Money
going out was not measured at all. A token can be exact in `transferFrom` and misbehave in
`transfer`, which clears every inbound check and then misbehaves at the only moment that matters.

Every payout now goes through one `_payOut` helper that requires this contract's own balance to
fall by **exactly** the liability. Three things follow from choosing the sender side rather than
the receiver side:

- A token that debits more than the amount is refused. That surplus is another claimant's escrow,
  so paying the first person in the queue out of the second person's money is the actual theft.
- A token whose `transfer` moves nothing is refused. Before, the ledger entry was zeroed and a
  payout event emitted for money that never left.
- A token that debits exactly the amount and simply delivers less to the receiver is **allowed**.
  The escrow stays solvent, nobody is paid from anyone else's share, and the shortfall is the
  token's own behaviour. That residual is real and is recorded as B-7.

The review proposed checking the **receiver's** balance instead and reverting on any shortfall.
That was not taken. It would make every payout on such a token revert forever, with no other exit
from the contract, which is the R-08 permanent-lock class this rewrite exists to remove. Reverting
is the right answer when the alternative is spending someone else's money, and the wrong answer
when the alternative is a haircut the token itself imposes.

What the guard does **not** do is conjure missing tokens. Against a hostile token it stalls rather
than rescues. Its value is that it never marks a debt settled that was not, so the ledger survives
the outage: `test_Fixed_C2_01_OverDebitingTransferCannotBePaidFromAnotherClaimant` stalls both
refunds, then lifts the token's tax and pays both buyers in full. Closing the last gap needs token
curation, not another check — see B-7.

### D-20 — The provider's factory binding is set once

**Finding C2-03.** A raffle freezes its randomness provider at creation, but the provider's own
`factory` pointer was mutable. Repointing it made every existing raffle unknown to the provider, so
`finalize()` reverted and a sold-out raffle could only be released by refunding everyone. That
contradicted the claim that raffles are untouched by administration.

`setFactory` now reverts once the binding is set. A second factory gets a second provider, which
costs one deployment and removes a class of accident entirely.

This does **not** make the provider owner untrusted. `setRequestConfig` remains: a subscription id
the coordinator rejects makes `finalize()` revert, and a gas lane no node serves is accepted
on-chain and then never answered. The first releases through `failIfAbandoned()`, the second
through `failOnTimeout()`; both refund. Freezing the config too was considered and
rejected: gas lanes and subscriptions legitimately change, the damage is bounded by the refund
path, and pretending otherwise would be worse than documenting it. Recorded as B-8, and asserted
rather than merely written down: `test_Accepted_C2_03_ProviderOwnerCanStallSettlementViaRequestConfig`
stalls a settlement through the config, refunds the buyer anyway, and then restores settlement.

### D-21 — Both token addresses must contain code, but they may still be the same token

**Finding C2-04.** `initialize` checked only that the addresses were non-zero. A codeless payment
token produced a listed raffle that could never sell a ticket. It harmed nobody — the seller could
`cancel()` in the same block — but a listing that cannot work should not be created, and the check
is two lines. Both addresses now require `code.length > 0`.

The original remediation for R-16 proposed a second check, `assetToken != paymentToken`, which the
follow-up review did not mention. It was deliberately not taken. With the ledgers separated
(D-05), a raffle using one token for both roles is solvent by construction: the prize is owed from
`pendingPrize`, the proceeds from `sellerProceeds` and `protocolFeeOwed`, and those three sum to
exactly the balance. The check was needed when a single mapping held both currencies. Recording it
here so the divergence from the original remediation plan is a decision, not an omission.

### D-22 — A deployment has to prove it can settle before it is called ready

**Finding C2-02.** The deploy script printed the required `provider.setFactory(...)` call and
stopped. Until an owner ran it, and until the subscription listed the provider as a funded
consumer, `finalize()` reverted and a sold-out raffle sat until the abandonment hatch refunded
everyone seven days later. A missed manual step cost buyers a week.

Two changes. `Deploy.s.sol` performs the binding itself whenever the deployer is the owner, and
asserts it afterwards, so the common path has no manual step. `script/SetupProvider.s.sol` covers
the case where the owner is a Safe or timelock: it binds if needed, then refuses to exit unless the
factory and provider point at each other and the coordinator lists the provider as a funded
consumer. A deployment is not ready until that script passes.

The subscription read is deliberately defensive — a low-level call with a length check rather than
a typed one — because it is the only part that depends on the coordinator's exact ABI, and a script
that cannot read the subscription should warn, not revert.

### D-23 — The provider records only the requests it made

**Finding C2-05.** Any callback from the coordinator was stored and emitted, including for request
ids this provider never issued, and an empty word array produced an array-bounds panic rather than
a named error. The coordinator is trusted, so neither is a fund-loss path; both make the request
history unreliable, which matters when the history is the thing you reach for after an incident.

Fulfilments now require a known request id and a non-empty array. Kept from before: a random word
of zero is stored as one, because zero is the "not ready" sentinel — without that, a legitimate
zero answer would leave the raffle waiting for a seed that had already arrived, until the timeout
refunded everybody. `test_Fixed_C2_05_ZeroWordIsStoredAsTheSentinelPlusOne` pins it.

### D-24 — The Chainlink integration is pinned to Chainlink's published ABI

The provider declares the coordinator interface locally instead of vendoring
`@chainlink/contracts`. That keeps the dependency surface small, but it meant every test agreed
with us by construction: the mock coordinator was written to match our own interface, so nothing
in the repo would have noticed if the interface were wrong. The first failure would have been
on-chain, where a rejected request stalls every raffle until the abandonment hatch refunds it.

Checked against the published source (`smartcontractkit/chainlink-brownie-contracts`,
`contracts/src/v0.8/vrf/dev/`) on 2026-09-07. Four things had to match, and all four did:

- `RandomWordsRequest`: `bytes32 keyHash, uint256 subId, uint16 requestConfirmations,
  uint32 callbackGasLimit, uint32 numWords, bytes extraArgs` — field order included, since that is
  what produces the function selector.
- `requestRandomWords(RandomWordsRequest calldata) external returns (uint256)`.
- `rawFulfillRandomWords(uint256, uint256[] calldata) external`.
- `extraArgs` = `abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), ExtraArgsV1)`.

`test/audit/VRFConformance.t.sol` now pins all of it offline, checking the bytes the provider
actually puts on the wire rather than our own constants, so drift fails in CI instead of in
production. `.env.example` carries the verified Base coordinator addresses and key hashes.

**What the reading changed.** `VRFCoordinatorV2_5.fulfillRandomWords` deletes the request
commitment *before* invoking the callback, and charges the subscription whether or not the
callback succeeds. A fulfilment that reverts or runs out of gas therefore loses that seed
permanently; it cannot be retried. Two consequences:

- **The split settlement was load-bearing, not stylistic.** A full draw at `MAX_WINNERS_COUNT`
  measures 3.88M gas against Chainlink's 2.5M callback ceiling, so picking winners inside the
  fulfilment — which is what the original blockhash design effectively did — would have been
  impossible at the cap. `test_Conformance_DrawCouldNotRunInsideTheVrfCallback` asserts the
  measurement rather than leaving it as a claim.
- **New: `MIN_CALLBACK_GAS = 100_000`.** Fulfilment measures 27,201 gas, but nothing stopped an
  owner configuring a limit below that, which would have burned the subscription and stranded the
  raffle until its timeout — a silent, unretryable failure. The floor is enforced in the
  constructor and in `setRequestConfig`, and sits well under the 2.5M ceiling so it is settable on
  every supported network. It narrows B-8: the owner can still stall settlement with a wrong key
  hash or subscription, but no longer by starving the callback.

### D-25 — Audited against Chainlink's own security considerations

Having verified the ABI (D-24), the contract was walked against the eight items on
`docs.chain.link/vrf/v2-5/security`. Six are satisfied, two are deliberate deviations. All of it
is pinned in `test/audit/VRFConformance.t.sol` rather than asserted here.

| Chainlink says | Where we stand |
|---|---|
| 1. Use `requestId` to match requests to fulfilments | Satisfied. Each raffle stores its own `randomnessRequestId` and reads only that. Tested with two raffles answered in reverse order |
| 2. Choose a safe block confirmation time | Satisfied, and hardened. See below |
| 3. Do not allow re-requesting or cancellation | Satisfied inside the normal window; one bounded deviation. See below |
| 4. Stop accepting input before requesting | Satisfied. Sales close at the deadline, and the request is made afterwards in a state where `buyTickets` reverts |
| 5. `fulfillRandomWords` must not revert | Deviation, deliberate. See below |
| 6. Inherit `VRFConsumerBaseV2Plus` | Deviation. We implement `rawFulfillRandomWords` directly with the identical coordinator check, rather than vendor the package for one modifier. The conformance suite pins the signature, which is what the base contract would otherwise guarantee |
| 7. Avoid ERC-4337 wallets for subscription management | Not applicable |
| 8. Keep the subscription funded | Operational. `script/SetupProvider.s.sol` refuses to pass unless the subscription lists the provider and holds a balance |

**Item 2, hardened: `MIN_REQUEST_CONFIRMATIONS = 3`.** Confirmations are what make a validator
re-roll uneconomic, and Base permits a consumer to ask for zero. Zero would be indefensible for a
raffle, and it could not be corrected for a request already in flight, so three is enforced at
both places the config can be set. Anything higher remains the owner's call, and should go up for
a high-value raffle.

**Item 5, deviated from knowingly.** The callback rejects a request id this provider never issued,
and an empty word array. Chainlink's rule exists because a failed callback is never retried and the
seed is lost — but neither rejection can discard a seed of ours: `requestedBy` is written in the
same transaction as the request, so a real fulfilment always finds it, and `numWords` is fixed at
one. Everything that could genuinely fail on a raffle's behalf was already moved out of the
callback into `drawWinners`, which is what the rule is really asking for.

**Item 3, deviated from knowingly, and this is the one worth your attention.** Past
`DRAW_DEADLINE`, `failOnTimeout()` fires even when a seed did arrive, which is a way to discard an
unfavourable outcome. It is kept because the alternative is the failure mode this whole rewrite
exists to remove: without it, a draw that could never execute would strand every participant
permanently. The cost is bounded in a way that matters — the raffle is voided rather than looted,
so buyers are refunded and the seller takes the prize back — and reaching it requires 30 days in
which any of up to 100 winners could have called the permissionless `drawWinners()`.
`test_Accepted_ArrivedSeedCanBeVoidedAfterTheDrawDeadline` performs the discard and asserts
everyone ends up whole, so the deviation is recorded rather than hidden.

**Cost, since it is a live dependency and not just a library.** One request per raffle that sells
out; a raffle that misses its target fails without asking for randomness. On Base the coordinator
overhead is 150,400 gas paying in LINK (128,500 native) plus 435 per word, our fulfilment measures
27,201, and the premium is 50% for LINK or 60% for native. The binding constraint is not the
per-request cost but the buffer: the coordinator will not begin a request unless the subscription
covers the full `VRF_CALLBACK_GAS` limit at the gas lane's price, and a failed callback is charged
anyway. Base Sepolia LINK is free from Chainlink's faucet.

### D-26 — Verified against Base Sepolia, and one assumption it corrected

D-24 pinned our wire format against Chainlink's published source, but published source is not
deployed bytecode. `test/fork/VRFBaseSepolia.t.sol` closes that last gap: it forks Base Sepolia,
creates and funds a real subscription on the coordinator at
`0x5C210eF41CD1a72de73bF76eC39637bB0d3d7BEE`, registers the provider as a consumer, and drives a
raffle through to a real request. The coordinator accepts it and queues it. The struct, the field
order, the `extraArgs` tag and the gas lane are therefore confirmed against the contract Chainlink
actually deployed, not against a mock of our own design. It also proves the hand-decoded
`getSubscription` read in `script/SetupProvider.s.sol` — the one place an ABI mismatch would pass
silently instead of reverting — returns what the script expects.

The fork cannot go further: the seed comes from Chainlink's offchain nodes, which do not serve a
local fork. Everything up to that boundary is now real.

**It corrected something.** B-8 said a bad key hash makes `finalize()` revert. It does not. The
coordinator validates the *subscription* and rejects an unknown one, but it does not validate the
gas lane: a key hash no node serves is accepted on-chain, queued, and then never answered. The
failure is silent rather than loud, and the two need different hatches —

- rejected subscription: `finalize()` reverts, the raffle stays `Active`, and `failIfAbandoned()`
  releases it after `FINALIZE_GRACE`;
- unserved gas lane: `finalize()` succeeds, the raffle sits in `RandomnessPending`, and
  `failOnTimeout()` releases it after `RANDOMNESS_TIMEOUT`.

Both refund everyone; neither locks. Both are now asserted against real bytecode rather than
reasoned about. The docs that stated the wrong mechanism have been corrected.

**Worth generalising.** The mock coordinator was written to match our interface, so it agreed with
us about the subscription *and* about the gas lane — and it was wrong about the second. A mock can
only confirm the behaviour its author already believed. That is the argument for keeping this fork
test in CI with an RPC secret, rather than treating it as a one-off check.
