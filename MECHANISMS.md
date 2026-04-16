# Raffle System Mechanisms

## Overview

A gas-efficient raffle system using EIP-1167 minimal proxy clones. Each raffle sells tickets for ERC20 tokens and distributes prizes to randomly selected winners.

## Core Mechanisms

### 1. Factory Pattern (EIP-1167 Clones)

**Purpose**: Gas-efficient deployment of multiple raffles

- **RaffleFactory** deploys a single implementation contract
- Each new raffle is a minimal proxy clone (45 bytes) pointing to the implementation
- Saves ~95% gas compared to deploying full contracts
- Factory manages global settings (protocol fees, randomness provider)

**Flow**:

```
Factory.createRaffle()
  → Clone deployed (EIP-1167)
  → Clone.initialize() called
  → Assets transferred from seller to clone
```

### 2. Ticket Purchase Mechanism

**Function**: `buyTickets(uint256 n, address recipient)`

**Process**:

1. Validates raffle is active (`startTime <= now <= endTime`)
2. Checks ticket cap not exceeded (`totalTickets + n <= ticketCap`)
3. Enforces per-address limit (`tickets[buyer] + n <= MAX_TICKETS_PER_ADDRESS`)
4. Validates funds don't exceed sellerMin (`totalFunds + cost <= sellerMin`)
5. Transfers payment tokens from buyer to raffle contract
6. Updates state: `totalTickets`, `totalFunds`, `tickets[buyer]`, `ticketHolders[]`

**Key Constraints**:

- Maximum 10,000 tickets per address (prevents domination)
- Payment always from `msg.sender` (even if `recipient` is different)
- Tickets assigned to `recipient` (or `msg.sender` if `address(0)`)

### 3. Finalization & Success Determination

**Function**: `finalize()` (anyone can call after `endTime`)

**Success Criteria**:

- `totalFunds == sellerMin` exactly (all-or-nothing)
- Must be called after `endTime`

**Process**:

1. Sets `finalized = true`
2. Calculates `succeeded = (block.timestamp >= endTime) && (totalFunds == sellerMin)`
3. Stores `_succeededState = succeeded`
4. If succeeded:
   - Calculates protocol fee: `(totalFunds * feeBps) / 10000`
   - Transfers fee to `feeRecipient`
   - Sets seller payout in `pendingWithdrawals[seller]`
   - Records `finalizationBlock = block.number`
   - **Automatically picks winners** via `_pickWinners()`
5. Emits `Finalized(succeeded, totalFunds)`

**Important**: Raffle fails if `totalFunds < sellerMin` at `endTime`

### 4. Winner Selection Mechanism

**Function**: `_pickWinners()` (internal, called during `finalize()` if succeeded)

**Randomness Source**: Blockhashes from past blocks

**Process**:

1. Validates sufficient blocks exist: `finalizationBlock >= winnersCount`
2. For each winner (0 to `winnersCount-1`):
   - Uses blockhash: `blockhash(finalizationBlock - 1 - i)`
   - Converts to random: `uint256(blockHash) % totalTickets`
   - Handles collisions: if ticket already won, tries next ticket (up to 3 attempts)
   - Allows duplicate wins after 3 collision attempts (by design)
   - Adds winner to `winners[]` array
   - Calculates prize: `assetAmount / winnersCount` (+ remainder distributed to first winners)
   - Adds prize to `pendingWithdrawals[winner]`
3. Sets `winnersSet = true`
4. Emits `WinnersSet(winners)`

**Constraints**:

- Maximum 200 winners (ensures blockhashes available within 256-block window)
- Uses consecutive blocks going backwards from finalization block
- Users with many tickets can win multiple times (by design)

### 5. Pull-Based Withdrawal Mechanism

**Security Pattern**: Pull-over-push (prevents reentrancy and DoS)

**Withdrawal Functions**:

#### `claimPrize()` - Winners claim prizes

- Requires: `finalized`, `succeeded`, `winnersSet`, caller is in `winners[]`
- Transfers asset tokens from `pendingWithdrawals[winner]` to winner
- Sets `pendingWithdrawals[winner] = 0` (prevents double claim)

#### `claimRefund()` - Losers claim refunds

- Requires: `finalized`, `!succeeded`, caller has tickets
- Calculates: `tickets[caller] * ticketPrice`
- Transfers payment tokens back to caller
- Sets `tickets[caller] = 0` (prevents double claim)

#### `withdrawSeller()` - Seller withdraws proceeds

- Requires: `finalized`, `succeeded`, caller is seller
- Transfers payment tokens from `pendingWithdrawals[seller]` to seller
- Sets `pendingWithdrawals[seller] = 0`

#### `withdrawAsset()` - Seller withdraws assets (if failed)

- Requires: `finalized`, `!succeeded`, caller is seller
- Transfers full `assetAmount` back to seller

**Why Pull-Based?**

- Prevents reentrancy attacks
- Avoids DoS from unclaimable addresses
- Users control when they receive funds

### 6. State Management

**Pre-Finalization State**:

- `finalized = false`
- `_succeededState` not set
- `hasFailed()` calculates dynamically: `(block.timestamp >= endTime) && (totalFunds < sellerMin)`
- `succeeded()` calculates dynamically: `(block.timestamp >= endTime) && (totalFunds == sellerMin)`

**Post-Finalization State**:

- `finalized = true`
- `_succeededState` stored (true if succeeded, false if failed)
- `hasFailed()` returns `!_succeededState`
- `succeeded()` returns `_succeededState`
- Winners set if succeeded

### 7. Access Control

**Modifiers**:

- `onlyFactory`: Only factory can call (for initialization)
- `onlyActive`: Raffle must be active (`startTime <= now <= endTime`) and not finalized
- `onlyAfterEnd`: Must be called after `endTime`
- `nonReentrant`: Prevents reentrancy on all state-changing functions

**Function-Level Checks**:

- `withdrawSeller()`: `msg.sender == seller`
- `withdrawAsset()`: `msg.sender == seller`
- `claimPrize()`: Caller must be in `winners[]` array

### 8. Protocol Fee Mechanism

**Configuration**: Set in `RaffleFactory` (basis points, e.g., 200 = 2%)

**Collection**:

- Calculated during `finalize()`: `(totalFunds * feeBps) / 10000`
- Transferred immediately to `feeRecipient` (if > 0)
- Seller receives: `totalFunds - protocolFee`

**Admin Functions** (Factory owner only):

- `setFeeBps(uint256 _feeBps)`: Update fee percentage (max 10000 = 100%)
- `setFeeRecipient(address _feeRecipient)`: Update recipient address

## Design Decisions

### All-or-Nothing Success

- Raffle only succeeds if `totalFunds == sellerMin` exactly
- Requires all tickets to be sold
- Enforced by strict equality check: `sellerMin = ticketPrice * ticketCap`

### No Native ETH Support

- Only ERC20 tokens supported
- Use WETH (Wrapped ETH) for native ETH functionality
- Prevents complexity of handling ETH transfers

### Multiple Wins Allowed

- Users with many tickets can win multiple times
- Collision handling allows duplicates after 3 attempts
- By design - increases fairness for large ticket holders

### Blockhash-Based Randomness

- Uses past blockhashes (not future blocks)
- Accessible within 256-block window
- Limited manipulation window (blocks already mined)
- Can be upgraded to Chainlink VRF via `IRandomnessProvider`

## Security Features

1. **Reentrancy Protection**: `nonReentrant` modifier on all state-changing functions
2. **Safe Token Transfers**: Uses OpenZeppelin's `SafeERC20`
3. **Input Validation**: All parameters validated in `initialize()`
4. **Access Control**: Modifiers and function-level checks
5. **Pull-Based Withdrawals**: Prevents reentrancy and DoS
6. **Limits**: Max tickets per address (10,000), max winners (200)
7. **State Consistency**: Stored state after finalization prevents manipulation

## Gas Optimization

- **EIP-1167 Clones**: ~95% gas savings vs full deployment
- **Optimizer**: Runs = 200 (balance between size and runtime gas)
- **Storage Layout**: Packed structs where possible
- **Events**: Indexed parameters for efficient filtering

## Extensibility Hooks

- **IRandomnessProvider**: Interface for VRF integration
- **Factory Pattern**: Easy to add new raffle types
- **Event Emissions**: Comprehensive events for off-chain indexing
