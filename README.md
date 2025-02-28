# USD FUN Contracts

This repository contains the implementation for the USD FUN smart contracts

## Contracts

### SimpleToken.sol

Core implementation contract for the funLP and USDFun tokens

### ERC20RebasingUpgradeable.sol

ERC20 implementation with rebasing logic

### ERC20RebasingPermitUpgradeable.sol

Inherits ERC20RebasingUpgradeable and adds permit

### StUSF.sol

Implements ERC20RebasingPermitUpgradeable with additional logic

### WstUSF.sol

Wrapped version of StUSF which allows users to keep their underlying balance fixed

### RewardsDistributor.sol

Interface for backend service to trigger minting of USDFun tokens as yield for holders

### UsfPriceStorage.sol

Price oracle for the USDFun token

### FlpPriceStorage.sol

Price oracle for the FunLP token

### AddressesWhitelist.sol

Whitelist contract used for ExternalRequestsManager and UsfExternalRequestsManager

### ExternalRequestsManager.sol

Interface for users to request to mint or burn FunLP tokens / USDFun tokens

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
