# Raffle Smart Contracts

On-chain raffles: a seller locks a prize, buyers purchase tickets, and winners are drawn with
verifiable randomness. Built with Foundry and Solidity 0.8.20.

> **Audit status.** These contracts have not been audited. An earlier version was deployed and
> found to contain four critical vulnerabilities, all of which are recorded with runnable
> proofs in [`docs/security/`](docs/security/). This version fixes them. Do not deploy without
> an independent audit. See [Known limitations](#known-limitations) for what is deliberately
> not fixed.

## Overview

Each raffle is an EIP-1167 minimal proxy clone, so creating one costs a fraction of a full
deployment. A raffle:

- sells a fixed number of tickets for an ERC20 payment token
- escrows the prize until the raffle settles
- succeeds only if every ticket sells, and otherwise refunds everyone
- draws winners from a single seed supplied by Chainlink VRF
- pays out only when the recipient asks, including the protocol fee

Vocabulary used throughout the code and docs is defined in [`CONTEXT.md`](CONTEXT.md).

## Lifecycle

A raffle is always in exactly one state. Every function names the state it requires, and none of
them infers the state from the clock.

```
                    ┌──────────────────────────────────────────┐
                    │                                          │
  create ──────► Active ──finalize()──► RandomnessPending ──drawWinners()──► Succeeded
                    │      (sold out)          │
                    │                          │ failOnTimeout()  after 1 day
                    │ finalize() not sold out  │
                    │ cancel()   while empty   ▼
                    └──────────────────────► Failed
                      failIfAbandoned() after endTime + 7 days
```

| State | Tickets | Refunds | Prizes | Seller |
|---|---|---|---|---|
| Active | yes | no | no | may cancel only while no tickets are sold |
| RandomnessPending | no | no | no | nothing |
| Succeeded | no | no | yes | withdraws proceeds |
| Failed | no | yes | no | reclaims the prize |

**Succeeded and Failed are permanent.** Nothing moves out of a raffle until it reaches one of them.

## Contracts

**`RaffleFactory`** creates raffles and holds the terms new ones are born with.
`createRaffle(...)` pulls the prize from the caller, `setFeeBps`, `setFeeRecipient` and
`setRandomnessProvider` set defaults for future raffles only. Ownership is two-step, and the
fee is capped at `MAX_FEE_BPS` (10%), which is a constant and cannot be raised.

**`Raffle`** is one raffle, deployed as a clone. `buyTickets`, `finalize`, `drawWinners`,
`claimPrize`, `claimRefund`, `withdrawSeller`, `withdrawFee`, `withdrawAsset`, plus the three
escape hatches `failOnTimeout`, `failIfAbandoned` and `cancel`.

**`ChainlinkVRFProvider`** implements `IRandomnessProvider` against Chainlink VRF v2.5. Only
raffles registered with its factory may spend the subscription.

## Design decisions

**All or nothing.** A raffle succeeds only when `totalFunds == sellerMin`, and `sellerMin` must
equal `ticketPrice * ticketCap`, so success means every ticket sold. Anything less refunds
everyone.

**ERC20 only.** No native ETH anywhere. Wrap to WETH and use that. The prize and the payment
token may be the same token; the contract tracks the two obligations separately.

**Everything is pulled, nothing is pushed.** No settlement transaction sends tokens to anybody,
including the protocol fee. A recipient that cannot receive tokens can therefore never block
anyone else's money.

**Terms are frozen at creation.** The fee, the fee recipient and the randomness provider are
copied into the raffle when it is created. Later changes to the factory cannot alter a raffle
that is already selling tickets.

**Settling and drawing are separate transactions.** `finalize()` decides only whether the raffle
sold out. Winners come later, from a seed that did not exist when `finalize()` was sent, so
whoever sends it has no influence on who wins.

**Every wait has an escape hatch.** If the seed never arrives, anyone may fail the raffle after a
day. If nobody settles a raffle at all, anyone may fail it 7 days after the deadline. Both
paths refund everyone and take no fee.

**One ticket wins at most once.** Winners are drawn without replacement from a single seed. An
address holding several tickets can still win several times, which is intended: more tickets
mean more chances.

## Randomness

Winners come from one seed, supplied by Chainlink VRF and delivered with a proof the contract
verifies. That seed is stretched into as many picks as needed by hashing it with the round
number, and tickets are drawn without replacement using a partial Fisher-Yates shuffle.

The contract does not use `blockhash` anywhere. An earlier version did, and because past block
hashes are public before a transaction is sent, and `finalize()` may be called by anyone at any
time, a ticket holder could simulate the draw each block and only submit when they won. That is
recorded as R-04 in [`docs/security/FINDINGS.md`](docs/security/FINDINGS.md).

## Development

```bash
forge build
forge test
forge test --match-path 'test/audit/*'    # the security regression suite
forge coverage
```

The `test/audit/` suite contains the original exploit proofs, inverted so that they now assert
each attack is blocked. If one of them fails, a vulnerability has been reintroduced.

## Deployment

Deploying requires a funded Chainlink VRF subscription on the target network.

```bash
export PRIVATE_KEY=...
export FEE_RECIPIENT=0x...
export FACTORY_OWNER=0x...          # a Safe or timelock in production
export VRF_COORDINATOR=0x...        # see .env.example for verified Base addresses
export VRF_KEY_HASH=0x...
export VRF_SUBSCRIPTION_ID=...
export FEE_BPS=200                  # optional, default 200 (2%)

forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast
```

If the deployer is also `FACTORY_OWNER`, the script binds the provider to the factory itself. If
the owner is a Safe or a timelock, that binding is a separate transaction. Either way, finish with:

```bash
export PROVIDER=0x...   # printed by Deploy
export FACTORY=0x...    # printed by Deploy
forge script script/SetupProvider.s.sol:SetupProvider --rpc-url $RPC_URL --broadcast
```

It binds the provider if that has not happened, then refuses to exit unless the factory and
provider point at each other and the VRF subscription lists the provider as a funded consumer.
**A deployment is not ready until that script passes.** Before it does, raffles can be created and
sold but cannot settle; nothing locks, they release through the abandonment hatch and refund.

The provider's factory binding is write-once. A second factory needs its own provider.

### Running costs

Chainlink VRF is paid, from a subscription funded in LINK or native ETH. One request is made per
raffle that **sells out**; a raffle that misses its target fails without asking for randomness, so
it costs nothing. Cost per request is
`gas price x (coordinator overhead + callback gas used) x (1 + premium)`. On Base that is
150,400 + 435 overhead paying in LINK, our fulfilment measures 27,201 gas, and the premium is 50%
for LINK or 60% for native — so roughly 267,000 gas-equivalents per settled raffle, which at Base
gas prices is cents, not dollars.

What matters more is the **buffer**. The coordinator will not start a request unless the
subscription can cover the worst case for that gas lane: the full `VRF_CALLBACK_GAS` limit at the
lane's price, not the gas actually used. Keep the subscription funded well above one request's
worth, and remember a callback that fails is still charged.

On Base Sepolia, testnet LINK is free from Chainlink's faucet, so nothing above costs real money
until mainnet.

The factory owner is passed in explicitly rather than taken from `msg.sender`, because a CREATE2
deployment routes through the deterministic deployer proxy, which would otherwise become the
owner and leave the factory permanently un-administrable.

## Trust assumptions

- **The factory owner** sets the fee, the fee recipient and the randomness provider for *future*
  raffles. They cannot touch a raffle that already exists, cannot exceed the 10% fee cap, and
  cannot influence any draw. Use a multisig behind a timelock.
- **The provider owner** cannot influence a draw or move money, but can stall settlement by
  pointing the provider at a gas lane no node serves, or a subscription the coordinator
  rejects. Raffles then
  refund. Give it to the same owner as the factory.
- **Chainlink** must answer. If it does not, raffles fail and refund rather than locking. The
  coordinator interface is declared locally rather than vendored, so `test/audit/VRFConformance.t.sol`
  pins our wire format — request selector, field order, `extraArgs` encoding, callback signature —
  against Chainlink's published source, and `test/fork/` proves the real coordinator on Base
  Sepolia accepts a request built by this contract. If either fails, the integration has drifted.
  Run the fork suite with `BASE_SEPOLIA_RPC_URL` set; it skips itself without one.
- **Tokens** must behave normally. Money coming in is measured, so a token that delivers less than
  it was sent is rejected at the moment of transfer. Money going out is measured too: a payout
  that would debit the escrow by more than the amount owed is refused, because the surplus would
  be another claimant's money. See below for what is not covered.

## Known limitations

These are accepted and documented rather than fixed:

- **Rebasing tokens.** A balance check at deposit time cannot see a rebase that happens later. A
  negative rebase can leave a raffle unable to pay everyone. Do not use rebasing tokens.
- **Tokens that take their fee out of the receiver.** If a token debits the escrow exactly the
  amount owed but credits the receiver less, nothing here can tell: the escrow stays solvent and
  no claimant is paid from another's share, but the receiver nets less than the ledger promised.
  Closing this needs a list of approved tokens rather than a contract check. Recorded as C2-01.
- **Ticket storage cost.** Buying tickets writes one storage slot per ticket, so a single very
  large purchase can exceed the block gas limit. Split large purchases across transactions.
  Recorded as R-14.
- **No Sybil resistance.** Nothing stops one person using many wallets. The old per-address limit
  was removed because it never achieved this and its presence implied otherwise.
- **The draw is public once the seed lands.** Anyone can compute the winners from the seed before
  `drawWinners()` is mined. This changes nothing, because the seed is already fixed by then.

## Security

Findings, proofs and remediation are in [`docs/security/`](docs/security/):

- [`FINDINGS.md`](docs/security/FINDINGS.md) — the findings register, all 34 with status
- [`DECISIONS.md`](docs/security/DECISIONS.md) — what was decided and why
- [`OPEN-QUESTIONS.md`](docs/security/OPEN-QUESTIONS.md) — what still needs a human answer
- [`test/audit/`](test/audit/) — runnable proofs

## License

MIT
