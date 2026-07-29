# Medichain — Blockchain

The Solidity contract (`MediAccessControl`) plus the Hardhat scripts that deploy it.
The contract is the only on-chain piece of Medichain — it stores access grants
and emits immutable audit-log events. Auth, metadata, and files live elsewhere
(Supabase + IPFS).

For the full app setup, see the [root README](../README.md).
This file is just the blockchain workflow.

## Prerequisites

- [Node.js](https://nodejs.org/) ≥ 18
- npm (bundled with Node)

## Install

```bash
cd blockchain
npm install
```

## Configure secrets (testnet/mainnet only)

```bash
cp .env .env
```

Edit `.env`:

```
PRIVATE_KEY=your-deployer-private-key-no-0x-prefix
POLYGON_AMOY_RPC_URL=https://polygon-amoy.g.alchemy.com/v2/YOUR_KEY
POLYGON_MAINNET_RPC_URL=https://polygon-mainnet.g.alchemy.com/v2/YOUR_KEY
POLYGONSCAN_API_KEY=your-polygonscan-api-key
```

For purely local development you can skip this — Hardhat's local node gives you
20 pre-funded test accounts automatically.

## Local development — your laptop is the server

The Flutter app talks to a local Hardhat node running on your machine.
**As long as the node process is running, your laptop is acting as a JSON-RPC
server.** When you close the terminal, the node dies and all on-chain state
disappears.

### 1. Start the Hardhat node

```bash
npx hardhat node
```

You'll see something like:

```
Started HTTP and WebSocket JSON-RPC server at http://127.0.0.1:8545/

Accounts
========
Account #0: 0xf39Fd6e51aad88F6F4ce6aB8827279cfFFb92266 (10000 ETH)
Private Key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
... (19 more)
```

Leave this terminal running. Defaults:

- **RPC URL** (from the host): `http://127.0.0.1:8545`
- **RPC URL** (from Android emulator): `http://10.0.2.2:8545`
- **Chain ID**: `31337`
- **State**: kept in memory only — every restart wipes everything

### 2. Deploy the contract

In a **second** terminal:

```bash
npx hardhat run scripts/deploy.js --network localhost
```

Expected output:

```
MediAccessControl : 0x5FbDB2315678afecb367f032d93F642f64180aa3
Contract address saved to: deployments/localhost.json
```

The address `0x5FbDB2…aa3` is deterministic: the first contract deployed against
a fresh Hardhat node always lands there, which is why it's hardcoded in
[lib/services/contract_service.dart:71-72](../lib/services/contract_service.dart#L71-L72).
If you deploy anything else first, the address shifts and you'll need to update
that constant.

### 3. Run the Flutter app

From the project root:

```bash
flutter run
```

### Restart workflow

Every time you stop the Hardhat node and restart it, you must redeploy:

```bash
# Terminal 1
npx hardhat node                                       # restart

# Terminal 2
npx hardhat run scripts/deploy.js --network localhost  # redeploy
```

Otherwise the Flutter app will call into an address with no contract behind it
and every transaction will revert.

## Connecting from a phone on the same Wi-Fi

By default `npx hardhat node` binds to `127.0.0.1`, which only accepts
connections from your laptop itself. To let a physical Android/iOS device on
the same Wi-Fi reach it, expose it on your LAN.

### 1. Bind Hardhat to all interfaces

```bash
npx hardhat node --hostname 0.0.0.0
```

### 2. Find your laptop's LAN IP

On Windows (PowerShell):

```powershell
ipconfig
```

Look for the `IPv4 Address` line under your active adapter (usually
`Wi-Fi`) — something like `192.168.1.42`.

On macOS / Linux:

```bash
ifconfig | grep "inet "
```

### 3. Open Windows Firewall for port 8545

PowerShell, run as Administrator:

```powershell
New-NetFirewallRule -DisplayName "Hardhat Node" -Direction Inbound `
    -LocalPort 8545 -Protocol TCP -Action Allow
```

### 4. Point the Flutter app at your laptop's IP

Edit [lib/services/contract_service.dart:65](../lib/services/contract_service.dart#L65):

```dart
static const String _rpcUrl = 'http://192.168.1.42:8545';  // your laptop's LAN IP
```

Then hot-restart the app. The phone and laptop must be on the **same Wi-Fi
network**; mobile data won't reach a private IP.

> ⚠️ `--hostname 0.0.0.0` exposes the RPC to anyone on your network. The default
> Hardhat accounts have their private keys printed at startup, so anyone with
> network access could submit transactions. Use this only on a trusted home
> network, and switch back to the default bind when you're done.

## Useful Hardhat commands

```bash
npx hardhat compile                              # just compile, don't deploy
npx hardhat clean                                # delete cache/ and artifacts/
npx hardhat console --network localhost          # interactive JS console against the node
npx hardhat node --port 9545                     # use a different port
npx hardhat run scripts/deploy.js --network amoy # deploy to Polygon Amoy testnet
```

## Deploying to Polygon Amoy (testnet)

1. Make sure `blockchain/.env` has a real `PRIVATE_KEY` and `POLYGON_AMOY_RPC_URL`.
2. Fund that wallet with testnet MATIC from the
   [Polygon Amoy faucet](https://faucet.polygon.technology/).
3. Deploy:
   ```bash
   npx hardhat run scripts/deploy.js --network amoy
   ```
4. Copy the printed contract address into
   [lib/services/contract_service.dart](../lib/services/contract_service.dart),
   and update `_rpcUrl` and `_chainId`:
   ```dart
   static const String _rpcUrl = 'https://polygon-amoy.g.alchemy.com/v2/YOUR_KEY';
   static const int _chainId = 80002;
   static const String _contractAddress = '0x...new address...';
   ```

Unlike the local node, Amoy is persistent — you only deploy once, and the
address survives restarts.

## Project layout

```
blockchain/
├── contracts/
│   ├── MediAccessControl.sol     # the only contract Medichain uses
│   └── archive/                  # superseded designs, kept for reference
├── scripts/
│   ├── deploy.js                 # main deploy script
│   └── deploy_remaining.js
├── deployments/                  # JSON files written by deploy.js, per network
├── test/                         # Hardhat tests (if/when added)
├── hardhat.config.js
├── package.json
└── .env                          # gitignored — deployer key + RPC URLs
```

## Troubleshooting

| Problem | Fix |
|---|---|
| `Error: cannot find module 'hardhat'` | Run `npm install` inside `blockchain/`. |
| Deploy fails with `nonce too high` | You restarted the node mid-session. Reset the MetaMask/wallet nonce, or just restart Hardhat too. |
| Flutter app: `SocketException: Connection refused` | Hardhat node isn't running, or you're on a physical device pointing at `10.0.2.2`. Use your laptop's LAN IP (see above). |
| Flutter app calls revert with `"contract not deployed"` | Hardhat restarted and state was wiped. Re-run `npx hardhat run scripts/deploy.js --network localhost`. |
| Pre-funded accounts have no MATIC after restart | That's expected — Hardhat's state is in-memory and resets every launch. |
