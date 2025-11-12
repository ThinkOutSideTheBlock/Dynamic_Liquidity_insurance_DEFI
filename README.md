# Dynamic Liquidity Insurance

A decentralized insurance protocol for smart contract liquidations with dynamic premium adjustment and capital adequacy monitoring.

## Overview

Dynamic Liquidity Insurance provides protection against liquidation risks in DeFi protocols through:

- **Dynamic Premium Adjustment**: Risk-based premium pricing that adapts to market conditions
- **Capital Adequacy Monitoring**: Real-time monitoring of insurance pool capital reserves
- **Multi-tranche Capital Structure**: Segregated capital layers with different risk/return profiles
- **Integrated Liquidation Management**: Flash loan-enabled liquidation execution with yield optimization
- **Advanced Risk Models**: GBM-based stochastic risk assessment and pricing

## Project Structure

```
src/
├── core/                 # Core insurance protocol contracts
├── libraries/            # Utility libraries and types
├── modules/              # Capital adequacy and monitoring modules
├── risk/                 # Risk modeling and assessment
├── integrations/         # DeFi protocol integrations (Aave, Uniswap)
├── security/             # Security-related contracts
├── tokens/               # Share token contracts
├── oracles/              # Price oracle implementations
└── utils/                # Utility contracts

test/
├── unit/                 # Unit tests for core functionality
├── integration/          # Integration tests
├── analysis/             # Analysis and simulation tests
├── fixtures/             # Test fixtures and helpers
└── mocks/                # Mock contracts for testing
```

## Getting Started

### Prerequisites

- [Foundry](https://book.getfoundry.sh/)
- Solidity 0.8.20+

### Installation

```bash
git clone https://github.com/ThinkOutSideTheBlock/Dynamic_Liquidity_insurance.git
cd Dynamic_Liquidity_insurance
forge install
```

### Building

```bash
forge build
```

### Running Tests

```bash
forge test
```

Run specific tests:
```bash
forge test --match-path "test/unit/InsurancePool.t.sol"
```

With verbosity:
```bash
forge test -vvv
```

### Gas Snapshots

```bash
forge snapshot
```

## Key Components

### Insurance Pool
Core contract managing premium collection, claims processing, and capital allocation across multiple tranches.

### Premium Adjustment Module
Dynamically calculates and adjusts insurance premiums based on risk metrics and market conditions.

### Capital Adequacy Monitor
Monitors reserve levels and triggers rebalancing when capital ratios fall below thresholds.

### Risk Metrics
GBM-based stochastic model for dynamic risk assessment and pricing optimization.

### Liquidation Purchase
Handles liquidation execution with integrated flash loan and DEX trading capabilities.

### Integrations
- **Aave V3**: Yield generation and flash loan integration
- **Uniswap V3**: Liquidation execution and price discovery

## Security

This is experimental software. Use at your own risk. Extensive testing and auditing is recommended before production deployment.

## Citation
If you use this software, please cite it as:

Khoshakhlagh, Sajjad. (2025). Dynamic Liquidity Insurance: A Decentralized Protocol for Defi Liquidations (v1.0.0-alpha). Zenodo. https://doi.org/10.5281/zenodo.17593498

## License

MIT License
