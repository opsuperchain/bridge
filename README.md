# Universal Bridge

A single bridge for all tokens and all EVM chains.

1. **Select your bridge provider** (adapter) to customize your trust assumptions
2. **Bridge all the tokens** — permissionless, anyone can wrap any ERC20

## Live Deployment

Successfully bridged VIRTUALS from Base to OP Mainnet with a Uniswap V4 liquidity pool.

| Contract | Address | Chains |
|----------|---------|--------|
| BridgeTokenFactory | `0x025Bdd1b4B4ea743F12435B589698f1B6D132437` | Same on all chains |
| TokenVault | `0x4F6c625C9073A21F52a4d830e94426609F2Ad1f2` | Same on all chains |
| LZ Adapter (OP Mainnet) | `0x4470EdA280Fc21c40dc4E5F5997aFA7434b491D3` | OP Mainnet |
| LZ Adapter (Base) | `0x037a19b1AFebE1C146e2E0b0BcC45A8338c3145F` | Base |
| Wrapped VIRTUAL | `0xa29BbDAa47Da95Ab1EC829DCb12AcFd004a0df6C` | OP Mainnet |

## Architecture

```
Remote Chain (spoke)              OP Mainnet (hub)
┌──────────────┐                  ┌─────────────────────┐
│  TokenVault   │  ──adapter──▶  │  BridgeTokenFactory  │
│  (lock/unlock)│  ◀──adapter──  │  (CREATE2 deploy,    │
│               │                 │   mint/burn)         │
└──────────────┘                  └─────────────────────┘
                                          │
                                  ┌───────┴───────┐
                                  │ BridgeToken   │ (one per remote
                                  │ (ERC20)       │  token+adapter)
                                  └───────────────┘
```

### Components

- **TokenVault** — deployed on spoke chains. Locks tokens when bridging in, unlocks when bridging out.
- **BridgeTokenFactory** — deployed on the hub chain (OP Mainnet). CREATE2-deploys a wrapped `BridgeToken` per (remoteChainId, remoteToken, adapter) tuple. Mints on bridge-in, burns on bridge-out.
- **BridgeToken** — plain ERC20 with mint/burn restricted to the factory. Immutable: `remoteChainId`, `remoteToken`, `factory`.
- **IBridgeAdapter** — pluggable interface for cross-chain messaging. Ship with LayerZero v2, but can implement for any protocol (CCIP, Hyperlane, native OP interop, etc).

### Design Principles

- **Permissionless** — anyone can wrap any ERC20 on any chain. No whitelists, no governance.
- **Configurable trust model** — the bridge itself is trust-neutral. Your trust assumptions are determined entirely by which adapter you choose. Want Chainlink's oracle network? Use a CCIP adapter. Prefer LayerZero's DVN model? Use the LZ adapter. Want native OP Stack interop when it goes live? Write that adapter. Different adapters produce different wrapped tokens, so risk is isolated per adapter.
- **Fully immutable** — no owner, no admin, no pause, no upgrades on any contract. All configuration is write-once.
- **Deterministic** — Factory and Vault deploy to the same address on every chain via the [CREATE2 deployer](https://github.com/Arachnid/deterministic-deployment-proxy).
- **Adapter-gated registration** — only the adapter contract itself can register vault/factory pairings, preventing front-running attacks.

## Setup

```bash
forge install
forge build
forge test   # 34 tests
```

## Deployment

```bash
# Predict deterministic addresses
./bridge predict

# Deploy factory + vault on each chain
./bridge deploy --chain op
./bridge deploy --chain base

# Deploy adapters + configure (see script/DeployAndRegister.s.sol)
# Or manually:
forge create src/adapters/LzBridgeAdapter.sol:LzBridgeAdapter \
  --constructor-args <LZ_ENDPOINT> <LOCAL_EID> <DST_GAS_LIMIT> \
  --rpc-url <RPC> --private-key <KEY> --broadcast
```

After deploying adapters on both chains, configure them:

```bash
# Map chains (write-once)
cast send <ADAPTER> "mapChain(uint256,uint32)" <CHAIN_ID> <LZ_EID>

# Set peers (write-once, each adapter trusts the other)
cast send <OP_ADAPTER> "setPeer(uint32,address)" <BASE_EID> <BASE_ADAPTER>
cast send <BASE_ADAPTER> "setPeer(uint32,address)" <OP_EID> <OP_ADAPTER>

# Register pairings (adapter calls factory/vault as msg.sender)
cast send <OP_ADAPTER> "registerVault(address,uint256,address)" <FACTORY> <REMOTE_CHAIN_ID> <VAULT>
cast send <BASE_ADAPTER> "registerFactory(address,uint256,address)" <VAULT> <HUB_CHAIN_ID> <FACTORY>
```

## CLI Usage

```bash
# Bridge tokens from Base → OP Mainnet
./bridge wrap --token 0x... --amount 1.5 --chain base

# Bridge tokens back from OP Mainnet → Base
./bridge unwrap --token 0x... --amount 1.0

# Compute wrapped token address (before it exists)
./bridge address --token 0x... --chain 8453 --adapter 0x...

# Check balance
./bridge balance --token 0x...

# Show deployed contracts
./bridge status
```

## Configuration

Copy `.env.example` to `.env`:

```
PRIVATE_KEY=0x...
OP_RPC=https://mainnet.optimism.io
BASE_RPC=https://mainnet.base.org
FACTORY_ADDRESS=0x...    # same on all chains
VAULT_ADDRESS=0x...      # same on all chains
ADAPTER_ADDRESS=0x...    # chain-specific
```

## How It Works

### Bridge In (Remote → Hub)

1. User approves ERC20 to `TokenVault` on the remote chain
2. User calls `vault.bridge(token, amount, adapter, dstChainId, recipient)` with ETH for bridge fee
3. Vault locks tokens, calls `adapter.sendMessage()` to send a cross-chain message
4. On the hub chain, the adapter delivers → `factory.onBridgeMessage()`
5. Factory CREATE2-deploys a `BridgeToken` if it's the first time, mints to recipient

### Bridge Out (Hub → Remote)

1. User calls `factory.bridgeBack(wrappedToken, amount, recipient)` with ETH for bridge fee
2. Factory burns wrapped tokens, calls `adapter.sendMessage()` to send a cross-chain message
3. On the remote chain, the adapter delivers → `vault.onBridgeMessage()`
4. Vault unlocks the original tokens to recipient

### Trust Model

The bridge core (Factory, Vault, BridgeToken) is trust-neutral — it makes no assumptions about how messages get from chain A to chain B. All trust lives in the adapter layer.

```
Message Protocol ──guarantees delivery──▶ Adapter ──checks peer mapping──▶ Factory/Vault ──checks sender mapping──▶ Mint/Unlock
```

Three layers of verification:
1. **Message protocol** (LZ, CCIP, native interop, etc.) guarantees the message was actually sent on the source chain
2. **Adapter** checks the message came from its registered peer on the remote chain
3. **Factory/Vault** checks the sender (decoded from the message) matches the registered counterpart

Different adapters = different trust assumptions = different wrapped tokens. This is by design — if one adapter is compromised, only tokens bridged through that adapter are affected.

## Adapters

The `IBridgeAdapter` interface is intentionally simple:

```solidity
interface IBridgeAdapter {
    function sendMessage(uint256 dstChainId, address receiver, bytes calldata payload)
        external payable returns (bytes32 messageId);

    function estimateFee(uint256 dstChainId, address receiver, bytes calldata payload)
        external view returns (uint256);
}
```

### Included: LayerZero v2 Adapter

We built a LayerZero v2 adapter (`LzBridgeAdapter`) as the first implementation. It wraps LZ's endpoint directly (no OApp inheritance), is fully immutable, and costs ~$0.01-0.10 per L2-to-L2 message.

### Future Adapters

The interface is simple enough to implement for any cross-chain messaging protocol:

- **Chainlink CCIP** — Chainlink's DON-backed messaging
- **Hyperlane** — permissionless, customizable security modules
- **OP Stack native interop** — `L2ToL2CrossDomainMessenger` (when it goes live on mainnet)
- **Wormhole**, **Axelar**, or any other protocol

Each adapter is independent. You can run multiple adapters in parallel — users choose which one to bridge through based on their trust preferences.

### Writing Your Own Adapter

Implement `IBridgeAdapter` for your protocol. The adapter must:
1. Forward `sendMessage()` calls to the messaging protocol
2. On the destination, call `IBridgeMessageReceiver(receiver).onBridgeMessage(srcChainId, srcSender, payload)`
3. Authenticate that messages actually came from the source chain (protocol-specific)

## Deterministic Addresses

### Core Contracts

Factory and Vault are deployed via the deterministic deployment proxy (`0x4e59b44847b379578588920cA78FbF26c0B4956C`) with `salt = 0`. Same address on every EVM chain.

### Wrapped Tokens

Each wrapped token address is deterministic:

```
salt = keccak256(abi.encode(remoteChainId, remoteToken, adapter))
address = CREATE2(factory, salt, BridgeToken(remoteChainId, remoteToken, factory))
```

Compute before deployment: `factory.computeAddress(remoteChainId, remoteToken, adapter)`
