# Raffle System Mechanisms

How the contracts actually work. Vocabulary is defined in [`CONTEXT.md`](CONTEXT.md).

Where this document once described behaviour the code did not implement, that gap was the direct
cause of several critical vulnerabilities. It is now written from the code. If the two disagree,
that is a bug in one of them and worth chasing down.

## 1. Factory and clones

The factory deploys one `Raffle` implementation in its constructor, passing its own address so
the implementation records permanently which factory may initialize clones of it. The
implementation is then locked with `_disableInitializers()`, so it can never be used as a raffle
itself.

Each new raffle is an EIP-1167 minimal proxy, about 45 bytes of code delegating to the
implementation. Creation, initialization and prize escrow all happen in one transaction:

```
createRaffle()
  → clone deployed
  → clone.initialize(params)   ← reverts unless msg.sender is the factory
  → prize transferred from the caller into the clone
  → balance checked: the clone must have received exactly assetAmount
```

The prize is always pulled from `msg.sender`. A `raffleSeller` argument is accepted for backward
compatibility but must equal the caller or be zero. It cannot name a third party, because an
ERC20 allowance is permission to move tokens for your own raffle, not permission for a stranger
to spend it on terms they chose.

## 2. States

A raffle is in exactly one of `Uninitialized`, `Active`, `RandomnessPending`, `Succeeded` or
`Failed`. Every state-changing function begins by requiring a specific state. None of them
decides from `block.timestamp` what the state should be.

Clone storage starts as all zeroes, which is why `Uninitialized` is first in the enum.

## 3. Buying tickets

`buyTickets(n, recipient)` requires the `Active` state and `startTime <= now < endTime`. The
window is half-open: selling stops at the instant finalization becomes possible, so the two can
never overlap.

Tickets are appended to `ticketHolders`, once per ticket, so the array index is the ticket number
and the value is the holder. Payment always comes from `msg.sender`; the tickets belong to
`recipient`, or to the caller when that is zero.

Accounting is updated before the transfer, and the transfer is then checked against the balance
delta. A token that delivers less than it was sent is rejected outright rather than quietly
leaving the raffle unable to pay everyone.

There is no per-address ticket limit. The old one counted against the recipient, so a single
payer could route around it with different recipients, and no on-chain limit can prevent one
person using several wallets.

## 4. Settlement

`finalize()` requires `Active` and `now >= endTime`. Anyone may call it.

- If `totalFunds != sellerMin`, the raffle did not sell out. State becomes `Failed`. Done.
- Otherwise state becomes `RandomnessPending` and the raffle asks its provider for a seed.

`finalize()` chooses no winners. This is deliberate: it is what stops the caller from picking the
outcome by choosing when to send the transaction.

## 5. The draw

`drawWinners()` requires `RandomnessPending` and a seed that has arrived. Anyone may call it. It
reads the seed, draws the winners, splits the prize, records what the seller and the protocol are
owed, and moves the state to `Succeeded`.

**Stretching one seed.** Each round derives its own number as `keccak256(seed, i)`. One honest
seed therefore produces any number of picks, and everyone can verify the draw afterwards by
recomputing it.

**Drawing without replacement.** Think of the tickets as a row of numbered stubs. Round `i` draws
only from positions `[i, totalTickets)`, and the drawn stub is swapped out of that range, exactly
like dealing from a deck. No ticket can be drawn twice.

To avoid copying the whole row into memory, the row is virtual: position `i` holds ticket `i`
unless a swap put something else there. Only positions actually touched cost storage, so a
three-winner draw costs three writes whether the raffle sold ten tickets or ten thousand.

An address holding several tickets occupies several positions and can still win several times.
That is intended. What cannot happen is one ticket winning twice.

**Prize split.** Each winner receives `assetAmount / winnersCount`, and the first
`assetAmount % winnersCount` winners receive one extra unit, so the credited total is exactly the
prize. `assetAmount >= winnersCount` is enforced at creation, so no declared winner is credited
zero.

## 6. Escape hatches

Three ways a raffle reaches `Failed` other than not selling out. All of them refund everyone and
take no fee.

| Function | Condition | Who |
|---|---|---|
| `cancel()` | `Active`, zero tickets sold | seller only |
| `failOnTimeout()` | `RandomnessPending`, one day elapsed | anyone |
| `failIfAbandoned()` | `Active`, 7 days past `endTime` | anyone |

These exist so that no outside failure can trap money. A silent oracle, a paused token or simple
neglect ends in refunds rather than a permanent hole.

## 7. Payouts

Every payout is pulled, including the protocol fee. No settlement transaction sends tokens to
anybody, so a recipient that cannot receive tokens can never block anyone else.

Three ledgers, each in exactly one token, never combined:

| Ledger | Token | Claimed by |
|---|---|---|
| `sellerProceeds` | payment | `withdrawSeller()`, seller, `Succeeded` |
| `protocolFeeOwed` | payment | `withdrawFee()`, anyone, sends to the frozen recipient |
| `pendingPrize[addr]` | prize | `claimPrize()`, the winner, `Succeeded` |

Refunds are computed from the ticket count rather than a ledger: `claimRefund()` requires
`Failed`, zeroes the caller's tickets and returns `tickets * ticketPrice`.

`withdrawAsset()` returns the whole prize to the seller in `Failed`. Its flag is set before the
transfer.

An earlier version kept the seller's proceeds and the winners' prizes in one mapping, in two
different tokens. A seller who won could claim the sum in the prize token, leaving an honest
winner unpaid.

## 8. Protocol fee

The fee is read from the factory once, at creation, and frozen on the raffle. Later changes to
the factory apply only to raffles created afterwards. The cap is `MAX_FEE_BPS`, 10%, a constant
on both contracts that no one can raise.

At settlement the fee is recorded as owed, not sent. `withdrawFee()` pays it out later, to the
recipient frozen at creation.

## 9. Access control

| Function | Who |
|---|---|
| `initialize` | the factory only, once |
| `buyTickets`, `finalize`, `drawWinners`, `failOnTimeout`, `failIfAbandoned`, `withdrawFee` | anyone |
| `cancel`, `withdrawSeller`, `withdrawAsset`, `recoverToken` | the seller |
| `claimPrize` | any address with a prize owed |
| `claimRefund` | any address holding tickets in a failed raffle |
| `setFeeBps`, `setFeeRecipient`, `setRandomnessProvider` | the factory owner, two-step |

`claimPrize` proves entitlement from the ledger rather than scanning the winners array.

## 10. Security properties

1. **State, not time.** Every guard is on the state. This is what closed the refund and prize
   withdrawal holes, which were both open during the sale because the old check asked whether the
   raffle had succeeded, and before the deadline that was always false.
2. **Reentrancy.** Every state-changing function is `nonReentrant`, and state is written before
   external calls throughout. Note that the guard works in clones because OpenZeppelin treats an
   uninitialized slot as not-entered; the guard's own constructor never runs for a clone.
3. **Measured transfers.** Inbound amounts are checked against the balance delta, so tokens that
   take a cut are rejected instead of silently making the raffle insolvent.
4. **Solvency.** Obligations are tracked per token and never combined, so the raffle can always
   pay what it says it owes. Invariant tests in `test/audit/Tokens.t.sol` assert this.
5. **Bounded loops.** At most 100 winners, a ceiling set so a full draw (about 6M gas,
   measured) stays well inside a block. `claimPrize` does no scanning.
6. **Recovery.** `recoverToken` can never touch the prize or the payments, in any state.

## 11. Extension points

`IRandomnessProvider` is the seam. Anything implementing `requestRandomness` and `getRandomness`
can supply seeds, and the raffle records which provider it was created with. `ChainlinkVRFProvider`
is the production implementation; `test/mocks/MockRandomnessProvider.sol` drives the tests and is
never deployed.

## 12. Timing constants

| Constant | Value | What it governs |
|---|---|---|
| `MIN_DURATION` | 10 minutes | Shortest gap between start and deadline |
| `RANDOMNESS_TIMEOUT` | 1 day | How long a pending raffle waits for its seed before anyone may fail it |
| `FINALIZE_GRACE` | 7 days | How long past the deadline an unsettled raffle may be failed by anyone. Also the window a provider that reverts on request costs buyers, since `finalize()` then reverts and the raffle never leaves `Active` |
| `DRAW_DEADLINE` | 30 days | Backstop. Past this, `failOnTimeout()` fires even if a seed did arrive, so a draw that cannot execute refunds rather than strands |
| `MAX_WINNERS_COUNT` | 100 | Bounds the draw. A full draw measures about 6M gas |
| `MAX_FEE_BPS` | 1000 (10%) | Ceiling on the protocol fee, on both contracts, not adjustable |

Inside the normal window, `failOnTimeout()` refuses to fire if the seed did arrive, so a late seed
is drawn rather than refunded and the outcome cannot depend on who called first. Past
`DRAW_DEADLINE` that check is dropped, because a raffle that can never be drawn must still have a
way out.
