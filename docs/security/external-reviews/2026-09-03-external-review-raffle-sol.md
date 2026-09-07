# External review (shared via share-md.com, created 2026-09-03)

Source: https://share-md.com/view?id=4fb2ef4c-b106-4574-96d4-1c5c504266fe
Scope stated by reviewer: source-level review of Raffle.sol only (factory, deployment, tokens, chain not provided).

## Critical
- C-01 Buyers can refund immediately and retain winning tickets. claimRefund() only requires !_succeeded(), which is false before endTime. Buy → claimRefund → tickets[msg.sender]=0 but ticketHolders/totalTickets/totalFunds unchanged → repeat. Raffle reports sold-out/succeeded while holding little payment. Fix: require finalized && !_succeededState.
- C-02 Seller can withdraw the prize during an active raffle. withdrawAsset() only requires !_succeeded(), true throughout the active period. Fix: require finalized && !_succeededState; set assetWithdrawnBySeller before transfer.
- C-03 Prize escrow not enforced by this contract. initialize() records assetAmount but never transfers/verifies it. Conditional on unseen factory. Fix: atomic deploy+init+fund, balance-delta check == assetAmount, handle assetToken == paymentToken.

## High
- H-01 Winner selection predictable/grindable: historical blockhashes are public at finalize time; anyone can precompute winners per block and time finalize(). Fix: VRF with request/callback + timeout.
- H-02 Public initialization can be hijacked: first caller becomes factory. Exploitable if clone+init non-atomic; implementation can be initialized directly. Fix: atomic clone+init, bind to immutable factory, Initializable, lock implementation.
- H-03 Fee-on-transfer / unusual ERC-20s make accounting insolvent: totalFunds += nominal cost without balance check. Fix: balance-delta check, allowlist tokens.
- H-04 Mutable, unbounded factory fee can block or confiscate proceeds: feeBps > 10000 underflow blocks finalize; fee can be changed after purchases; 100% fee confiscates; reverting feeBps()/feeRecipient() blocks finalize; zero recipient strands fee. Fix: validate, snapshot fee at creation, max fee.

## Medium
- M-01 Collision handling stops after 3 attempts → same ticket index can win repeatedly; biases nearby indices. Fix: partial Fisher–Yates without replacement.
- M-02 Immediate protocol-fee push in finalize() can block entire raffle if token rejects recipient. Fix: pull-based protocol fee.
- M-03 Some declared winners may receive zero prizes if assetAmount < winnersCount; claimPrize requires prize > 0. Fix: require _assetAmount >= _winnersCount.
- M-04 buyTickets storage loop (one push per ticket) can exceed block gas limit. Fix: ticket ranges/cumulative checkpoints + binary search.
- M-05 blockhash assumptions not portable to L2s/other EVM chains.

## Low / design
- buyTickets allows timestamp == endTime; finalize requires > endTime; canFinalize says >= endTime. Inconsistent interval.
- Per-address limit trivially bypassed with multiple wallets.
- ETH_ADDRESS and onlyFactory unused.
- claimPrize() scans winners unnecessarily (pendingWithdrawals already proves entitlement).
- Token addresses not validated as contracts.
- No policy for accidentally transferred tokens.
- startTime can be in the past.
- Same token for payment and prize → shared balance, needs explicit solvency accounting.

## Recommended architecture
State machine {Uninitialized, Active, RandomnessPending, Succeeded, Failed}; invariants: buy only in Active; refund only in Failed; seller prize withdrawal only in Failed; VRF; full collateralization; totalTickets == ticketHolders.length; totalFunds == totalTickets*ticketPrice pre-settlement; sum(prizes) == assetAmount; no duplicate winning index; atomic clone+init+fund.
