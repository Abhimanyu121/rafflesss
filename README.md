# Raffle Smart Contracts

A minimal, extensible smart contract system for running raffles on Ethereum. Built with Foundry and Solidity 0.8.20.

## Overview

This system implements a factory pattern that deploys minimal proxy clones (EIP-1167) for each raffle, making it gas-efficient and extensible. Each raffle:

- Accepts tickets purchased with ETH or ERC20 tokens
- Locks seller assets until the raffle completes
- Uses pull-based withdrawals for security
- Supports configurable protocol fees
- Designed for easy integration with Chainlink VRF (via `IRandomnessProvider` interface)

## Architecture

### Contracts

1. **RaffleFactory** - Deploys raffle clones and manages global settings
   - `createRaffle()` - Creates a new raffle clone
   - `setFeeBps()` - Updates protocol fee (basis points)
   - `setFeeRecipient()` - Updates fee recipient address
   - `setRandomnessProvider()` - Sets randomness provider for VRF integration

2. **Raffle** - Individual raffle contract (deployed as clone)
   - `buyTickets(uint256 n)` - Purchase tickets (ETH or ERC20)
   - `finalize()` - Finalize raffle after end time
   - `setWinners(address[] winners)` - Set winners (called by factory/relayer)
   - `claimPrize()` - Winners claim their prizes
   - `claimRefund()` - Losers claim refunds (if raffle failed)
   - `withdrawSeller()` - Seller withdraws proceeds

3. **IRandomnessProvider** - Interface for randomness providers (extensibility hook)

## Features

- ✅ EIP-1167 minimal proxy clones (gas-efficient)
- ✅ Support for ETH and ERC20 payments
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
- Maximum tickets per address limit
- Input validation on all functions

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
    assetToken,      // ERC20 token address (0x0 for ETH)
    assetAmount,     // Amount of asset to raffle
    paymentToken,    // Payment token (0x0 for ETH)
    ticketPrice,     // Price per ticket
    ticketCap,       // Maximum tickets
    sellerMin,       // Minimum funds for success
    startTime,       // Start timestamp
    endTime,         // End timestamp
    winnersCount     // Number of winners
);
```

### Buying Tickets

```solidity
// For ERC20 payment
paymentToken.approve(raffle, amount);
raffle.buyTickets(count);

// For ETH payment
raffle.buyTickets{value: amount}(count);
```

### Finalizing and Setting Winners

```solidity
// After endTime, anyone can finalize
raffle.finalize();

// Factory/relayer sets winners (off-chain selection for MVP)
address[] memory winners = [...];
factory.setWinners(raffle, winners);
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

## Trust Assumptions (MVP)

- **Winner Selection**: Currently off-chain via factory/relayer. For production, integrate Chainlink VRF.
- **Factory Owner**: Should be a Gnosis Safe multisig with timelock.
- **Relayer**: Must be trusted (multisig) until VRF integration.

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
