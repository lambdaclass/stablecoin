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
| TIP-20 (Tempo) | Yes | Yes | Yes | Yes | Yes | Yes | No | Yes |
| LatamStables (Ripio) | Yes | Yes | Yes | No | No | No | Yes (Initializable, ERC20Upgradeable, ERC20BurnableUpgradeable, ERC20PausableUpgradeable, AccessControlUpgradeable, ERC20PermitUpgradeable) | Yes (UUPSUpgradeable) |


Nice to have:
- ERC20PermitUpgradeable
- AccessControlUpgradeable
- EIP2612 (ERC20Permit)
- EIP3009
- EIP712 (Typed structured data hashing and signing)

## Interfaces comparison

| Interface | Reasons to include it |
| --- | --- |
| `AccessControlUpgradeable` |  It provides access control, useful to implement roles (like `minter`, `pauser`, etc). |
| `AccessControlDefaultAdminRulesUpgradeable` |  It also provides access control, but additionally contains functions to handle the `DEFAULT_ADMIN` rules in a more secure way (compared to `AccessControlUpgradeable`). |
| `ERC20Permit` (EIP2612) |  Offers more flexibility to token holders. |
| `EIP3009` |  Offers more flexibility to token holders. |
| `ERC20Burnable` | When users redeem their tokens, these must be burned. |
| `Ownable2Step` | Provides the same functionality as OpenZeppelin's `Ownable`, but allows to transfer ownership in a more secure way (2-step mechanism). |

The following is a brief description of each interface, along with links to the documentation.

### AccessControlUpgradeable
This contract implements role-based access control mechanisms.
Allows to `grant` or `revoke` a given role to a specific address, and provides the `onlyRole(role)` modifier. [Docs](https://docs.openzeppelin.com/contracts/5.x/access-control#using-accesscontrol)

### AccessControlDefaultAdminRulesUpgradeable

Extends `AccessControlUpgradeable` with functions that allows specifying special rules to manage the `DEFAULT_ADMIN_ROLE` holder, which is a sensitive role with special permissions over other roles that may potentially have privileged rights in the system. [Docs](https://docs.openzeppelin.com/contracts/5.x/api/access#AccessControlDefaultAdminRules)


### ERC20Permit
Extends the `ERC20` with the `permit()` function, which can be used to change an account's ERC20 allowance by submitting a message signed by the account. By not relying on `IERC20.approve`, the token holder account doesn't need to send a transaction, and thus is not required to hold Ether at all. [Docs](https://docs.openzeppelin.com/contracts/4.x/api/token/erc20#erc20permit)

### EIP3009

Extends the `ERC20` with the `transferWithAuthorization` method, which allows a token holder to authorize a transfer off-chain by signing a message, and then anyone can submit that signed authorization on-chain to move the tokens.

It enables gasless transfers for the sender, since the sender only signs a message; the caller who submits it pays the gas. [Docs](https://eips.ethereum.org/EIPS/eip-3009#reference-implementation)


### ERC20Burnable
Extends the `ERC20` contract with the `burn()` function, which allows token holders to destroy both their own tokens and those that they have an allowance for, in a way that can be recognized off-chain (via event analysis). [Docs](https://docs.openzeppelin.com/contracts/4.x/api/token/erc20#ERC20Burnable)

### Ownable2Step
This extension of the `Ownable` contract includes a two-step mechanism to transfer ownership, where the new owner must call `acceptOwnership` in order to replace the old one. This can help prevent common mistakes, such as transfers of ownership to incorrect accounts, or to contracts that are unable to interact with the permission system. [Docs](https://docs.openzeppelin.com/contracts/5.x/api/access#Ownable2Step)


## Smart contract

### Description

The stablecoin smart contract extends the `ERC20` interface and adds functionality for burning tokens, freezing accounts and pausing the smart contract. It also implements role-based access control so that operations such as mint, burn, freeze and pause can only be performed by authorized accounts.

### Deployment

Before deploying the smart contract, make sure to setup the environment variables. Copy the `.env.example` with the following command and fill the missing variables

```bash
cp .env.example .env
```

To deploy the stablecoin smart contract, run the following command (make sure to set the right `RPC_URL`)

```bash
forge clean
forge script script/DeployStablecoin.s.sol --broadcast --rpc-url RPC_URL
```

### Upgrade with Safe

To upgrade the stablecoin from a Safe smart account, run the following steps.

#### 1. Deploy the new implementation

Head to the [script/DeployNewImplementation.s.sol](script/DeployNewImplementation.s.sol) script and update it so that it deploys the new implementation instead of the default `Stablecoin.sol` contract. Also, make sure the new implementation contract includes a [`@custom:oz-upgrades-from` reference](https://docs.openzeppelin.com/upgrades-plugins/api-core#define-reference-contracts) to validate whether the upgrade is safe.

To deploy the new implementation, run the following command (make sure to set the right `RPC_URL`)

```bash
forge clean
forge script script/DeployNewImplementation.s.sol --broadcast --rpc-url RPC_URL
```

#### 2. Build the upgrade transaction on Safe

To build a transaction on Safe, it is required to have the ABI of the contract. To generate the ABI, run the following command

```bash
forge build
cat out/Stablecoin.sol/Stablecoin.json | jq .abi > Stablecoin.abi
```

This will write the `Stablecoin` ABI to the `Stablecoin.abi` file.

Then, navigate to [https://app.safe.global](https://app.safe.global), and create a new transaction using the **Transaction Builder**. In the transaction builder, fill the required fields as follows:
* **Enter Address or ENS Name:** enter the Stablecoin proxy address.
* **Enter ABI:** paste the generated ABI.
* **To Address:** enter the Stablecoin proxy address.
* **ETH value:** fill it with 0.
* **Contract Method Selector:** select the `upgradeToAndCall` function.
* **newImplementation:** enter the address of the new implementation (deployed in the step 1).
* **data:** enter `0x`.

Then, follow the steps to create the transaction, and wait for the signers to sign the transaction.

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

