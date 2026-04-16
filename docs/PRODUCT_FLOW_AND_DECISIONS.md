# Building a Trustless Raffle: Product Flow & Design Decisions

*An article on how our raffle system works end-to-end and the key decisions we made while building it.*

---

## Why We Built This

We wanted a minimal, trustless way to run raffles on-chain: a seller locks an asset, buyers buy tickets with a payment token, and winners are chosen fairly without a central operator holding keys or deciding outcomes. The contracts had to be gas-efficient enough for real use, secure by design, and easy to extend later (e.g. with better randomness). This article walks through the product flow and explains the main design decisions we made along the way.

---

## Product Flow

### The Big Picture

There are three main actors:

- **Seller** – Creates a raffle, locks the prize (asset), and receives payment-token proceeds if the raffle “succeeds.”
- **Buyers** – Purchase tickets with a payment token during the raffle window; they either win a share of the asset or get a refund if the raffle fails.
- **Protocol** – Takes a configurable fee (e.g. 2%) from successful raffles; no role in picking winners or moving funds beyond that.

The lifecycle is: **Create → Buy → Finalize → Settle**. No admin steps, no manual winner selection, no custody of user funds beyond the escrow period.

---

### 1. Create (Seller)

The seller calls the factory to create a raffle. They specify:

- **Prize**: which ERC20 asset and how much (e.g. 1000 USDC).
- **Economics**: payment token, ticket price, max tickets (cap), and therefore the minimum amount that must be raised for the raffle to “succeed” (we call this `sellerMin`).
- **Time**: start and end timestamps.
- **Winners**: how many winners to pick (e.g. 3); prizes are split equally among them.

The seller must approve the factory to pull the prize (asset) from their wallet. The factory deploys a minimal proxy (clone) of the raffle contract, initializes it with these parameters, and transfers the asset from the seller into the clone. From that moment, the prize is locked in the raffle contract until the raffle is finalized and either paid out to winners or returned to the seller.

**Design note:** We support an optional “custom seller” address: the *caller* can create a raffle on behalf of another address. The asset is still pulled from the *seller* address (the one that will receive proceeds or the returned asset), not from the caller. This allows relayers or frontends to create raffles without ever holding the prize.

---

### 2. Buy (Buyers)

Between `startTime` and `endTime`, anyone can call `buyTickets(n, recipient)`:

- `n` = number of tickets.
- `recipient` = address that gets the tickets (e.g. for gifting); `address(0)` means “assign to me.”

The contract checks that the raffle is active, the cap isn’t exceeded, and the buyer doesn’t exceed the per-address ticket limit. Payment is always taken from `msg.sender` (the payer), while tickets are assigned to `recipient`. So one wallet can pay and another can hold the tickets.

Payment is in a single ERC20 (the “payment token”). Buyers approve the raffle contract, then call `buyTickets`. The contract pulls `n * ticketPrice` and updates internal accounting: who owns how many tickets and how much has been raised in total.

---

### 3. Finalize (Anyone)

After `endTime`, anyone can call `finalize()`. There is no “operator” step; the contract decides success or failure from on-chain state.

**Success** means: at the time of finalization, `totalFunds == sellerMin` (exactly). In other words, every ticket was sold and the full target was reached. In that case the contract:

- Marks the raffle as finalized and succeeded.
- Computes the protocol fee (e.g. 2% of `totalFunds`) and sends it to the fee recipient.
- Credits the seller with the remainder in a “pending withdrawal” (pull) balance.
- Picks winners on the spot using a deterministic, on-chain randomness source (block hashes).
- Assigns each winner their share of the prize in another “pending withdrawal” balance.

**Failure** means: `totalFunds < sellerMin`. Then the contract:

- Marks the raffle as finalized and *not* succeeded.
- No fee is taken, no winners are picked.
- Buyers can later claim refunds (payment token), and the seller can later withdraw the original asset back.

So the only “decision” at finalization is: did we hit the target or not? Everything else (fees, winner selection, payouts) follows from that.

---

### 4. Settle (Winners, Losers, Seller)

Settlement is entirely **pull-based**: the contract never pushes tokens to users. Users claim when they want.

- **Winners** – Call `claimPrize()`. The contract sends their share of the prize (the asset) and zeros out their pending prize balance so they can’t claim twice.
- **Losers (if raffle failed)** – Call `claimRefund()`. The contract sends back `tickets[caller] * ticketPrice` in payment token and zeros their ticket count.
- **Seller (if succeeded)** – Call `withdrawSeller()` to receive the payment-token proceeds (minus protocol fee).
- **Seller (if failed)** – Call `withdrawAsset()` to get the original prize (asset) back.

No batch payouts, no loops over long lists. Each party triggers their own transfer when they’re ready, which keeps the system simple and safe from reentrancy and “unclaimable address” issues.

---

## Key Design Decisions

Below are the main product and technical decisions we made and why.

---

### 1. All-or-Nothing Success (Strict Equality)

**Decision:** The raffle only “succeeds” if `totalFunds == sellerMin` exactly. If one ticket is left unsold, the raffle fails and everyone gets refunds / seller gets the asset back.

**Why:** We wanted a clear, binary outcome: either the full target is met or it isn’t. No partial success, no “we sold 80% so we’ll run it anyway.” That keeps the rules easy to explain and audit. It also forces the seller to set a realistic cap and price so that filling the raffle is achievable.

**Trade-off:** Some use cases might prefer “run if we hit 80%” or flexible thresholds. We chose simplicity and predictability; more complex rules can be built in a separate contract or a future version.

---

### 2. Strict Parameter Relationship: `sellerMin = ticketPrice * ticketCap`

**Decision:** We require `sellerMin` to equal `ticketPrice * ticketCap` at creation time. The contract reverts if they don’t match.

**Why:** This removes ambiguity. “Minimum to succeed” is always “price of every ticket sold.” There’s no way to misconfigure a raffle so that it can never succeed or so that success means something different from “all tickets sold.”

**Trade-off:** Slightly less flexibility (e.g. you can’t set a lower “minimum” for a soft launch). We accepted that for clarity and safety.

---

### 3. ERC20-Only (No Native ETH)

**Decision:** All payments and prizes are ERC20s. We don’t accept or send native ETH in the core logic.

**Why:** Handling both ETH and ERC20 complicates the contract (different transfer patterns, fallbacks, and edge cases). Many users already use WETH or a stablecoin; we support that by accepting any ERC20. If you want “pay in ETH,” you wrap to WETH first and use WETH as the payment or asset token.

**Trade-off:** One extra step (wrap ETH) for users who prefer ETH. We prioritized simpler, auditable code and uniform handling of all tokens.

---

### 4. Pull-Based Withdrawals (No Push)

**Decision:** We never push tokens to users. Winners, losers, and the seller all call a function to “pull” their share.

**Why:** Pushing to a list of addresses can fail (e.g. contract that reverts, or address that’s not set up to receive). That can block the whole payout or create reentrancy risk. With pull-based design, each user is responsible for claiming; the contract only transfers when they call. We also avoid reentrancy by doing state updates before external transfers and using a reentrancy guard.

**Trade-off:** Users must take an action to get their funds. We consider that acceptable and document it clearly; frontends can prompt or batch-claim for users if needed.

---

### 5. Winner Selection: Past Block Hashes (Not Future Blocks)

**Decision:** When we pick winners, we use hashes of *past* blocks (e.g. `blockhash(finalizationBlock - 1)`, `blockhash(finalizationBlock - 2)`, …). We do this in the same transaction as `finalize()`, so there’s no “wait N blocks” step.

**Why:** Using a future block would require users to wait and would be more vulnerable to manipulation (miners/validators know the future block hash). Using past blocks means the data is already fixed when we finalize; we only require that enough blocks have been produced (we cap winners at 200 so we stay within the 256-block window where `blockhash` is available).

**Trade-off:** Block hashes are not perfect randomness (miners have some influence). For high-value raffles we recommend integrating a verifiable randomness source (e.g. Chainlink VRF). We added an `IRandomnessProvider` hook so that can be plugged in later without changing the core flow.

---

### 6. Winners Picked at Finalization (Not on First Claim)

**Decision:** Winners are chosen inside `finalize()` as soon as we know the raffle succeeded. There is no “lazy” winner selection when the first winner claims.

**Why:** We want a single, deterministic moment when the outcome is fixed. If we picked on first claim, the order of claims could matter or we’d have to encode more complex “first claim triggers selection” logic. Doing it in `finalize()` keeps the model simple: after finalization, winners and amounts are fixed and anyone can read them.

**Trade-off:** Finalization must happen when enough blocks exist for our blockhash-based randomness (at least as many as winners). We enforce that and cap winners at 200 so this is achievable in normal conditions.

---

### 7. Allowing the Same Address to Win Multiple Times

**Decision:** We allow one address to appear multiple times in the winner list (e.g. if they bought many tickets and the “random” indices hit them more than once). After a few collision-avoidance attempts we intentionally allow duplicates.

**Why:** With a cap on tickets per address (e.g. 10,000), one address can still hold many tickets. Disallowing multiple wins would require more complex “replace duplicate with next non-winner” logic and could skew odds. Allowing multiple wins reflects “one ticket, one chance” in a simple way: more tickets mean more chances, including multiple wins.

**Trade-off:** A whale can win several prizes in one raffle. We mitigate by limiting tickets per address and document this behavior; for some products a “one win per address” rule might be added in an extension.

---

### 8. Factory + Clones (EIP-1167)

**Decision:** We deploy one “implementation” raffle contract and then create each new raffle as a minimal proxy (clone) of that implementation. A factory owns the implementation and the list of raffles.

**Why:** Deploying a full contract per raffle is expensive. Clones are tiny (minimal bytecode that delegates to the implementation), so creating many raffles is much cheaper. The factory also gives a single place for global config (fee, fee recipient, future randomness provider) and a clear registry of raffles.

**Trade-off:** Upgradeability of the implementation is a separate concern; we didn’t add it in v1 to keep the model simple and non-upgradeable by default.

---

### 9. Permissionless Finalization

**Decision:** Any address can call `finalize()` after `endTime`. The seller doesn’t have to do it.

**Why:** We want the outcome to be determined only by on-chain state and time. If only the seller could finalize, they could delay or refuse to finalize. With permissionless finalization, a relayer, bot, or any user can trigger it once the time has passed.

**Trade-off:** None from a trust perspective; it strictly improves decentralization and liveness.

---

### 10. Caps and Limits

**Decision:** We enforce (1) a max tickets per address (e.g. 10,000), and (2) a max number of winners (e.g. 200).

**Why:** Per-address cap limits one wallet dominating a raffle and keeps the “many participants” feel. The winner cap ensures we don’t need more past block hashes than the EVM provides (256 blocks), and keeps gas for winner selection bounded.

**Trade-off:** Very large raffles (e.g. 10,000 winners) would need a different randomness or batching design; we optimized for the common case and left extension points.

---

## Summary Table

| Decision | What we chose | Main reason |
|----------|----------------|-------------|
| Success condition | `totalFunds == sellerMin` exactly | Simple, binary, auditable |
| sellerMin | Must equal `ticketPrice * ticketCap` | No misconfiguration |
| Currency | ERC20 only (WETH for ETH) | Simpler, uniform code |
| Payouts | Pull-based only | Safety, no push failures/reentrancy |
| Randomness | Past block hashes, at finalization | No wait, fixed moment, upgradeable later |
| When winners are set | In `finalize()` | Single deterministic point |
| Multiple wins per address | Allowed | Simpler, matches “more tickets = more chances” |
| Deployment | Factory + EIP-1167 clones | Gas-efficient, clear registry |
| Who can finalize | Anyone after `endTime` | Permissionless, no gatekeeping |
| Limits | Tickets per address, max winners | Fairness and gas/blockhash safety |

---

## Conclusion

The product flow is: **create → buy → finalize → settle**, with no ongoing operator role and no manual winner selection. Every design choice above was made to keep the system simple, predictable, and secure: strict success rules, pull-based withdrawals, past-block randomness, and clear caps. We traded some flexibility (e.g. no native ETH, no partial success) for clarity and safety, and added hooks (like `IRandomnessProvider`) so we can improve randomness or add features later without redoing the core flow.

If you’re integrating this system, the main things to remember are: (1) success is all-or-nothing and requires exact sale of all tickets, (2) users must claim their own refunds or prizes, and (3) anyone can and should call `finalize()` after the raffle ends so that outcomes are fixed on-chain.
