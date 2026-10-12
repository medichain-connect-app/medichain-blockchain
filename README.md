# MediChain — Blockchain

The smart contracts behind MediChain's tamper-proof access history.

| Contract | What it does |
|---|---|
| `MediAccessControl` | Records which doctor may access which record (with optional expiry) and keeps an immutable audit log of every **grant**, **revoke**, **view** and **download**. |
| `MediChainForwarder` | OpenZeppelin's ERC-2771 forwarder. Lets the backend pay gas on users' behalf. |

Everything else lives off-chain: auth, profiles, record metadata and the AES keys in
Supabase; the encrypted files on IPFS. **No decryption keys ever go on-chain** —
on a public chain every byte of storage and every transaction is readable by anyone.

## How a transaction happens

Users never hold gas. For every action:

1. The backend builds the call (e.g. `grantAccess(doctor, recordId, expiresAt)`).
2. The acting user's server-custodied wallet signs it as an EIP-712 `ForwardRequest`.
3. The backend's **relayer** wallet submits it through `MediChainForwarder` and pays the gas.
4. The contract sees the user as the sender (`_msgSender()`), so ownership and
   access checks work as if the user had sent it themselves.

`recordId` is `keccak256(utf8(supabaseRecordUUID))`.

The backend logs a doctor's **view/download** on-chain itself when it serves a shared
file, so neither the website nor the app can skip it.

## Setup

```bash
npm install
npx hardhat compile
npx hardhat test
```

Requires Node.js ≥ 18. Contracts compile with Solidity 0.8.24 (EVM `cancun`).

## Deploy to Polygon Amoy (testnet)

1. Create `.env` (git-ignored — never commit it):
   ```
   PRIVATE_KEY=<deployer/relayer private key, no 0x>
   POLYGON_AMOY_RPC_URL=https://polygon-amoy-bor-rpc.publicnode.com
   ```
2. Fund that wallet with test POL: https://faucet.polygon.technology/
3. Deploy:
   ```bash
   npx hardhat run scripts/deploy.js --network amoy
   ```
   Addresses are saved to `deployments/amoy.json`, and the script prints the
   backend `.env` lines to copy (`CONTRACT_ADDRESS`, `FORWARDER_ADDRESS`, …).
4. In the backend `.env`, set `BLOCKCHAIN_RPC_URL`, `BLOCKCHAIN_CHAIN_ID=80002` and
   `RELAYER_PRIVATE_KEY` (the funded wallet), then rebuild the backend.

The relayer pays for every action, so keep it topped up. Approximate gas per action:

| Action | Gas |
|---|---|
| Deploy both contracts (once) | ~2.0M |
| Share a record (grant) | ~250k |
| Log a view / download | ~81k |
| Revoke | ~83k |

Multiply by the network's gas price (check `eth_gasPrice`) for the cost in POL.

## Local development

```bash
npx hardhat node                                       # terminal 1 — wiped on restart
npx hardhat run scripts/deploy.js --network localhost  # terminal 2
```

Point the backend at `http://127.0.0.1:8545`, chain `31337`, and use the printed
addresses. Use one of the node's printed test accounts as `RELAYER_PRIVATE_KEY`
(local only — those keys are public).

## Mainnet

Same contracts and script with `--network polygon`. Use a dedicated relayer wallet
with only a few dollars of POL in it, and an RPC provider such as Alchemy or Infura.
