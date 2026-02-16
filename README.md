# Raffle Smart Contracts

A minimal, extensible smart contract system for running raffles on Ethereum. Built with Foundry and Solidity 0.8.20.

## Overview

This system implements a factory pattern that deploys minimal proxy clones (EIP-1167) for each raffle, making it gas-efficient and extensible. Each raffle:

- Accepts tickets purchased with ERC20 tokens (use WETH for native ETH)
- Locks seller assets until the raffle completes
- Uses pull-based withdrawals for security
- Supports configurable protocol fees
- Designed for easy integration with Chainlink VRF (via `IRandomnessProvider` interface)

## Architecture

### Contracts

1. **RaffleFactory** - Deploys raffle clones and manages global settings
   - `createRaffle(address raffleSeller, ...)` - Creates a new raffle clone (raffleSeller can be address(0) to use msg.sender)
   - `setFeeBps()` - Updates protocol fee (basis points)
   - `setFeeRecipient()` - Updates fee recipient address
   - `setRandomnessProvider()` - Sets randomness provider for VRF integration

2. **Raffle** - Individual raffle contract (deployed as clone)
   - `buyTickets(uint256 n, address recipient)` - Purchase tickets (ERC20 only, use WETH for native ETH)
   - `finalize()` - Finalize raffle after end time (automatically picks winners if succeeded)
   - `claimPrize()` - Winners claim their prizes
   - `claimRefund()` - Losers claim refunds (if raffle failed)
   - `withdrawSeller()` - Seller withdraws proceeds

3. **IRandomnessProvider** - Interface for randomness providers (extensibility hook)

## Features

- ✅ EIP-1167 minimal proxy clones (gas-efficient)
- ✅ Support for ERC20 payments (use WETH for native ETH)
- ✅ Pull-based withdrawals (secure)
- ✅ Reentrancy protection
- ✅ Configurable protocol fees
- ✅ Extensible randomness provider interface
- ✅ Comprehensive test coverage
- ✅ Fuzz testing

## Security

- Uses OpenZeppelin contracts (`ReentrancyGuard`, `SafeERC20`, `Ownable`)
- Pull-over-push pattern for fund transfers
- Access control on critical functions
- Maximum tickets per address limit (10,000)
- Maximum winners count limit (200)
- Input validation on all functions
- Winners picked automatically during finalize() using past blockhashes

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- Solidity 0.8.20+

### Setup

```bash
# Install dependencies
forge install

# Build
forge build

# Run tests
forge test

# Run tests with gas reporting
forge test --gas-report

# Run fuzz tests
forge test --fuzz-runs 10000
```

### Deployment

1. Set environment variables:
```bash
export PRIVATE_KEY=your_private_key
export FEE_RECIPIENT=0x...
export FEE_BPS=200  # Optional, defaults to 200 (2%)
```

2. Deploy:
```bash
forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast --verify
```

## Usage

### Creating a Raffle

```solidity
address raffle = factory.createRaffle(
    raffleSeller,    // Seller address (address(0) to use msg.sender)
    assetToken,      // ERC20 token address (must be non-zero, use WETH for native ETH)
    assetAmount,     // Amount of asset to raffle
    paymentToken,    // Payment token (must be non-zero, use WETH for native ETH)
    ticketPrice,     // Price per ticket
    ticketCap,       // Maximum tickets
    sellerMin,       // Minimum funds for success (must equal ticketPrice * ticketCap)
    startTime,       // Start timestamp
    endTime,         // End timestamp
    winnersCount     // Number of winners (max 200)
);
```

**Important Design Decisions:**
- **All-or-nothing success**: Raffle only succeeds if `totalFunds == sellerMin` exactly (all tickets must be sold)
- **Strict equality**: `sellerMin` must equal `ticketPrice * ticketCap` (enforced during initialization)
- **No ETH support**: Use WETH (Wrapped ETH) for native ETH functionality

### Buying Tickets

```solidity
// For ERC20 payment
paymentToken.approve(raffle, amount);
raffle.buyTickets(count, address(0)); // address(0) assigns tickets to msg.sender

// To buy tickets for someone else (gifting)
raffle.buyTickets(count, recipientAddress);

// For native ETH, use WETH instead:
// 1. Wrap ETH: weth.deposit{value: amount}()
// 2. Approve: weth.approve(raffle, amount)
// 3. Buy: raffle.buyTickets(count, address(0))
```

### Finalizing and Winner Selection

```solidity
// After endTime, anyone can finalize
// Winners are automatically picked during finalize() if raffle succeeded
raffle.finalize();

// Winners are selected using blockhashes from past blocks (finalizationBlock - 1, -2, -3, etc.)
// Note: Users with many tickets can win multiple times (by design)
address[] memory winners = raffle.getWinners();
```

### Claiming

```solidity
// Winners claim prizes
raffle.claimPrize();

// Losers claim refunds (if raffle failed)
raffle.claimRefund();

// Seller withdraws proceeds
raffle.withdrawSeller();
```

## Testing

The test suite includes:

- **Unit tests** - Core functionality (create, buy, finalize, claim)
- **Integration tests** - Full raffle lifecycle
- **Fuzz tests** - Property-based testing for invariants
- **Gas snapshots** - Track gas usage

Run all tests:
```bash
forge test -vv
```

## Trust Assumptions

- **Winner Selection**: Uses blockhashes from past blocks (finalizationBlock - 1, -2, etc.). While not as secure as Chainlink VRF, it's sufficient for many use cases. For high-value raffles, consider integrating Chainlink VRF via `IRandomnessProvider`.
- **Factory Owner**: Should be a Gnosis Safe multisig with timelock.
- **Randomness**: Blockhashes are manipulable by miners, but using past blocks reduces manipulation window. For production, integrate Chainlink VRF.

## Extensibility

The system is designed for easy extension:

1. **VRF Integration**: Implement `IRandomnessProvider` and set via `setRandomnessProvider()`
2. **Ticket NFTs**: Add optional ERC-1155 adapter via `ITicketMinter` interface
3. **Multi-asset**: Extend `AssetVault` for complex asset types

## License

MIT

## Audit Status

⚠️ **This code has not been audited. Do not use in production without a security audit.**

For production deployment:
1. Complete security audit
2. Integrate Chainlink VRF
3. Deploy factory owner as Gnosis Safe multisig
4. Add timelock for admin functions
5. Test extensively on testnets
