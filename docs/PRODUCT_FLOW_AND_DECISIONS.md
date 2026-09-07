# Building a Trustless Raffle: Product Flow & Design Decisions

*How the raffle system works end to end, and the decisions behind it.*

> **Revised after a security review.** An earlier version of this document argued for several
> choices that turned out to be wrong, and the contracts implemented them. Four critical
> vulnerabilities followed. The decisions below are the current ones, and where a decision was
> reversed, the original reasoning and the flaw in it are kept rather than quietly deleted.
> Findings and proofs: [`../docs/security/`](../docs/security/).

---

## Why We Built This

A trustless way to run a raffle: a seller locks a prize, buyers buy tickets, and winners are
chosen fairly with no operator holding keys or deciding outcomes.

---

## Product Flow

Three actors: the **seller** who locks the prize and receives the proceeds, the **buyers** who
purchase tickets and either win a share or get refunded, and the **protocol**, which takes a
percentage of successful raffles and has no role in anything else.

The lifecycle is **create, buy, settle, draw, claim**.

### 1. Create

The seller approves the factory and calls `createRaffle`, specifying the prize, the payment
token, the ticket price and cap, the window, and how many winners to pick. The factory deploys a
clone, initializes it, and moves the prize in, all in one transaction. The prize is locked until
the raffle reaches a terminal state.

The prize is always taken from the caller. Creating a raffle "on behalf of" another address is
not possible; see decision 8.

### 2. Buy

Between the start and the deadline, anyone calls `buyTickets(n, recipient)`. Payment comes from
the caller, tickets belong to the recipient, so one wallet can pay and another can hold. The
deadline is exclusive: at the deadline second, selling has stopped and settlement is possible.

### 3. Settle

After the deadline, anyone calls `finalize()`. It answers exactly one question: did every ticket
sell? If not, the raffle fails and everyone can be repaid. If it did, the raffle asks its
randomness provider for a seed and waits.

`finalize()` does not choose winners. That separation is the whole point of decision 5.

### 4. Draw

Once the seed arrives, anyone calls `drawWinners()`. The seed picks the winners, the prize is
split, and what the seller and the protocol are owed is recorded. The raffle has succeeded.

If the seed never arrives, anyone can fail the raffle after a day and everyone is repaid.

### 5. Claim

Everything is pulled, never pushed. Winners call `claimPrize()`. Buyers in a failed raffle call
`claimRefund()`. The seller calls `withdrawSeller()` after success or `withdrawAsset()` after
failure. The protocol fee is also pulled, by anyone, via `withdrawFee()`.

---

## Key design decisions

Summarised below. The full reasoning for each — what the alternative was, and why it lost — is in
[`security/DECISIONS.md`](security/DECISIONS.md), D-01 to D-26. It is kept in one place on purpose:
this document used to restate the decisions, drifted from the code, and confidently described
guards that did not exist. That was finding R-25.

| Decision | Choice | Changed from the original? |
|---|---|---|
| Success condition | every ticket sold | no |
| Currency | ERC20 only, prize and payment may match | relaxed |
| Lifecycle | four explicit states | **new, and the important one** |
| Payouts | pulled, including the fee | fee fixed |
| Randomness | Chainlink VRF, seed requested at settlement | **reversed** |
| Drawing | one seed, without replacement | **reversed** |
| Fee and provider | frozen at creation, fee capped at 10% | **new** |
| Creating for others | not possible | **reversed** |
| Who settles | anyone | no |
| Escape hatches | cancel, timeout, abandonment | **new** |
| Per-address limit | removed | **reversed** |

---

## What we would tell ourselves at the start

**Write the states down first.** Four of the criticals reduce to "there was no state, only a
clock". A page of vocabulary before any code would have prevented all four.

**Documentation is not evidence.** This document confidently described guards the code did not
have, and the tests were written to pass the code as it was, so nothing caught the gap. Tests
that encode what the docs *promise* now live in `test/audit/Spec.t.sol`, and they fail when the
two drift apart.

**Ask who can choose, not just who can change.** The randomness argument was airtight about
tampering and never considered selection. Those are different questions and the second one is the
one that lost the money.
