## Stablecoin

## Stablecoin Comparison

In the analysis we will compare:

- USDC
- DAI
- USDS
- USDT
- PYUSD
- Ethena USDe

Using the following criteria:

- What interfaces/features does it implements?
- Does it have pauser role?
- Does it have freezer role?
- Does it have blacklisting?
- Does it have max mint amount?
- Does it have max burn amount?
- Does it have max transfer amount?
- Does they use OpenZeppelin?
- What kind of proxy do they use?


| Stablecoin | Pauser | Freezer | Blacklisting | Max Mint Amount | Max Burn Amount | Max Transfer Amount | OpenZeppelin | Proxy |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| USDC | Yes | Yes | Yes | Yes | No | No | IERC20, Ownable, SafeMath, Address | Yes (based on old OpenZeppelin) |
| USDT | Yes | No | Yes | No | No | No | No | No |
| PYUSD(PaxosToken) | Yes | No | No | Yes(SupplyControl) | No | No | Yes (AccessControlDefaultAdminRulesUpgradeable) | Yes |
| Ethena USDe | No | No | No | No | No | No | Yes(IERC20, IERC20Permit, IERC20Metadata, Ownable2Step, ERC20Burnable, ERC20Permit) | No |
| DAI | No | No | No | No | No | No | No (impls 712 manually) | No |
| USDS | No | No | No | No | No | No | Yes(UUPSUpgradeable, 712) | Yes(UUPSUpgradeable) |


Nice to have:
- ERC20PermitUpgradeable
- AccessControlUpgradeable
- EIP2612 (ERC20Permit)
- EIP3009
- EIP712 (Typed structured data hashing and signing)

## Setup 
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
