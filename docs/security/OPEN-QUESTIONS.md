# Open questions

Everything still needing a human answer before this goes anywhere near real money. Findings are in
`FINDINGS.md`; settled reasoning is in `DECISIONS.md` (D-01 to D-26).

Answering "recommended" to all of them is a coherent, defensible position; they are not in tension
with each other.

## Blocking a mainnet deployment

1. **The protocol fee** — B-1 below.
2. **Who owns the factory** — B-2. A Safe behind a timelock for real money.
3. **Who owns and funds the Chainlink subscription** — B-3.
4. **Token curation** — B-7. The one open gap a contract check cannot close.
5. **An independent audit.** `FINDINGS.md`, `DECISIONS.md` and `test/audit/` are already in the
   shape an auditor wants handed over.

## Already settled during the rewrite

These were open questions; all are now answered in the code. Listed so nobody reopens them without
knowing why the answer is what it is — the reasoning is in `DECISIONS.md`.

| | Question | Answer in the code |
|---|---|---|
| A-1 | Stopping anyone from spending an address's approval (R-03) | `createRaffle` reverts unless the seller is the caller |
| A-2 | May a seller hold tickets in their own raffle? (R-05) | Yes, and it is safe now: prize, proceeds and fee are three separate ledgers |
| A-3 | Maximum protocol fee (R-06) | `MAX_FEE_BPS = 1000` (10%), frozen per raffle at creation |
| A-4 | How long to wait for randomness (R-08) | `RANDOMNESS_TIMEOUT = 1 days`, then anyone may fail the raffle |
| A-5 | What if nobody calls finalize (R-08) | `FINALIZE_GRACE = 7 days`, then `failIfAbandoned()`. D-18 |
| A-6 | Restrict which tokens can be used? (R-09) | Not restricted. Inbound and outbound transfers are measured instead. Residual is B-7 |
| A-7 | Same token for prize and payment? (R-16) | Allowed; solvent by construction once the ledgers were split. D-21 |
| A-8 | Per-address ticket limit (R-20) | Removed. It never achieved Sybil resistance and implied that it did |
| A-9 | Ticket storage refactor (R-14) | Deferred. D-13, and C-5 below |
| A-10 | Minimum raffle duration (R-16) | `MIN_DURATION = 10 minutes` |
| A-11 | Maximum number of winners (R-28) | `MAX_WINNERS_COUNT = 100`, measured to fit a block. D-18 |
| A-12 | Recover tokens sent by mistake (R-19) | `recoverToken`, which refuses the prize and payment tokens in every state |

---

## For the repo owner

### B-1 — What was the intended protocol fee? (R-07, High)
`README.md:87` says the default is 200 basis points, which is 2%. `script/Deploy.s.sol:17` uses 10
basis points, which is 0.1%, with a comment claiming it is 2%. These differ by twenty times, and
the live deployment used whichever the script produced.

**Needs an answer, not a recommendation.** Whichever it is, the README, the comment and the script
must be made to agree.

### B-2 — Who should own the factory? (R-06, R-07, R-17)
The deploy script accidentally hands ownership to the CREATE2 deployer proxy, so the live factory
can never have its fee or fee recipient changed by anyone. The fix passes the owner in explicitly,
which means someone has to say who that is.

- (a) A Safe multisig
- (b) A Safe behind a timelock, which is what `README.md:177` says it should be
- (c) A single deployer key, for now

**Recommended: (b)** for anything holding real money, **(c)** only for a testnet deployment.
The owner controls the fee and the fee recipient for future raffles, so it is worth doing properly.

### B-3 — Chainlink subscription (D-03)
Chainlink VRF needs a subscription created on Base and funded with LINK or ETH. Someone has to own
and top up that subscription. The coordinator address, key hash and subscription id then go in as
deployment parameters.

**Needs an owner and a funding plan.** Without it the fixed contracts cannot settle a successful
raffle, though nothing locks: raffles would simply time out and refund.

### B-4 — Purge the leaked API key from git history? (R-21, Low)
`foundry.toml` line 14 contains an Ankr RPC key, and it is in the commit history, not just the
current file. Rotating the key is necessary either way.

- (a) Rotate only. The old key is dead, so what is in history is harmless.
- (b) Rotate and rewrite history to remove it. Rewriting history breaks every existing clone and
      open branch.

**Recommended: (a).** Rotation is what actually protects them. (b) is only worth the disruption if
the repo is public and the key cannot be rotated for some reason.

### B-5 — What happens to the live deployment? (R-03, and the whole set)
The deployed factory cannot be fixed. It is not upgradeable and neither are its clones. The fixed
version has to be deployed to a new address.

Three things need a decision:

- Confirm the old factory address is abandoned and that no new raffles are created on it.
- Tell everyone who ever approved that factory to set their approval to zero. This is the only
  protection against R-03 on the deployed version, and it is needed today, with no raffle running.
- Decide whether the solver's factory address is updated to the new deployment, and when.

### B-6 — The solver has its own version of this bug
`epoch-multiprotocol-solver/src/components/raffles/index.ts` reads the raffle seller straight out of
`JSON.parse(extraData)` and never checks it against the intent's user. A crafted intent could name
any address holding a standing approval, and the solver would execute the theft on the attacker's
behalf. This is in a different repo and needs its own owner and its own fix.

### B-7 — Do we curate which tokens may be listed? (C2-01, High)
A seller picks both the prize token and the payment token. Inbound transfers are measured, so a
token that skims on the way in is rejected at creation or at purchase, and payouts now refuse to
debit the escrow by more than the liability (D-19). One gap survives both checks: a token whose
`transfer` debits the sender exactly the amount but credits the receiver less. The escrow stays
solvent and no claimant is paid out of another's share, but the receiver nets less than the ledger
promised, and a token that exempts the seller from that haircut lets the seller skim refunds.

- (a) Leave listing permissionless and document the residual. Buyers already have to trust a
      seller-chosen token before they buy a ticket at all.
- (b) Add an owner-controlled allowlist of supported tokens to the factory. Closes it completely
      and turns listing from permissionless into curated.
- (c) Allowlist enforced only above a size threshold, or only for the payment token.

**Recommended: (a) for a testnet, (b) before real money.** This is a product decision, not a code
one — it is the difference between an open marketplace and a curated one, so it is the owner's
call. `test_Accepted_C2_01_ReceiverHaircutIsNotBlocked` records the current behaviour honestly.

### B-8 — The provider owner is a liveness trust assumption (C2-03)
The provider's factory binding is now write-once (D-20), so nobody can strand existing raffles by
repointing it. `setRequestConfig` remains: the owner can point it at a subscription the coordinator rejects, which makes `finalize()`
revert until it is corrected, or at a gas lane no node serves, which is worse only in that it is
silent: the request is accepted on-chain and simply never answered. Both are bounded — the first
releases through `failIfAbandoned()` after the finalize grace, the second through
`failOnTimeout()` after a day — so this costs liveness rather than funds. The distinction was
established on a Base Sepolia fork, not assumed; see `test/fork/VRFBaseSepolia.t.sol`.

- (a) Accept and document. The provider owner is already trusted to fund the subscription.
- (b) Freeze the request config too, and deploy a new provider whenever a gas lane changes.

**Recommended: (a).** (b) trades a real operational need — gas lanes and subscriptions do change —
for a risk that is bounded by the refund path. Whoever owns the factory should own this too.

---

## Raised during implementation

Found by the agents that rewrote the test suites, after the fixes were written. None of them
blocks the PR, and none is a fund-loss path, but each deserves an explicit yes or no.

### C-1 — An unclaimed prize is locked forever
Once a raffle succeeds, the prize token can only leave through `claimPrize()`. `withdrawAsset()`
is failure-only and `recoverToken()` refuses the prize token in every state. A winner who loses
access to their wallet burns their share permanently.

- (a) Leave it. Unclaimed means unclaimed, and any sweep is a new trust vector.
- (b) Let the seller sweep prizes still unclaimed after a long delay, say 180 days.
- (c) Let anyone redistribute unclaimed shares to the other winners after a long delay.

**Recommended: (a) for now, (b) if your colleague wants it.** A sweep gives the seller a reason to
hope winners are slow, which is a worse property than the stranded funds it recovers. Whatever is
chosen should be stated plainly in the user-facing docs.

### C-2 — `failIfAbandoned()` can refund a raffle that actually sold out
It requires only the `Active` state, so `FINALIZE_GRACE` (7 days) after the deadline a sold-out
raffle that nobody settled is refunded and the seller receives nothing.

This is intentional and I would keep it. That path exists precisely for the case where `finalize()`
itself cannot succeed, for example because the randomness provider reverts, and in that situation
the raffle is sold out. Blocking it for sold-out raffles would turn a broken provider into a
permanent lock, which is the exact failure we are removing. Anyone may call `finalize()`, so
reaching 7 days of neglect requires every participant to lose interest.

**Recommended: keep, and document.** Worth confirming your colleague agrees.

### C-3 — `sellerMin` is a parameter that can only hold one value
`initialize` requires `ticketPrice * ticketCap == sellerMin`, so the caller has no freedom and the
argument carries no information. It is a tenth argument on `createRaffle` whose only effect is to
give integrators something to get wrong.

- (a) Leave it. Removing it changes the ABI and would break the epoch solver's encoded call.
- (b) Remove it and update the solver in the same change.

**Recommended: (a) for this PR, (b) as a follow-up** coordinated with whoever owns the solver.

### C-4 — `ticketCap` has no upper bound
A seller can create a raffle whose cap is larger than anyone can practically buy out, given C-5
below. It can then never succeed. Nobody loses money, because the funds are refundable, but it
produces a raffle that is dead on arrival.

**Recommended: add a maximum cap** once the ticket storage refactor (D-13) is done, since the two
questions are really the same one.

### C-5 — Ticket storage is still one slot per ticket
Deferred deliberately (D-13). Measured after the rewrite: about 22.4k gas per ticket, roughly
1,335 tickets per 30M gas block, 227.5M gas to buy 10,001. Recorded in the README under known
limitations. Still worth doing.

### C-6 — Refunds go to the ticket holder, not the payer
If you buy tickets as a gift and the raffle fails, the recipient collects the refund, not you.
This is unchanged from the original contract and is arguably correct, since a gift transfers the
ticket and its refund value together. It has never been written down anywhere.

**Recommended: keep, and document it.** It is the kind of thing that generates a support ticket.
