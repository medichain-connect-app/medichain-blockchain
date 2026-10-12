require("@nomicfoundation/hardhat-ethers");
require("dotenv").config();

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: {
      // OpenZeppelin 5.x uses MCOPY; Polygon Amoy and mainnet run Cancun.
      evmVersion: "cancun",
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },

  networks: {
    // ── Local development ──────────────────────────────────────────────
    hardhat: {
      chainId: 31337,
    },

    // ── Polygon Amoy (testnet — replaced Mumbai in 2024) ──────────────
    amoy: {
      url: process.env.POLYGON_AMOY_RPC_URL || "https://polygon-amoy-bor-rpc.publicnode.com",
      chainId: 80002,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      // Gas price is estimated live; Amoy fees swing well above the 25 gwei floor.
    },

    // ── Polygon Mainnet ────────────────────────────────────────────────
    polygon: {
      url: process.env.POLYGON_MAINNET_RPC_URL || "https://polygon-rpc.com",
      chainId: 137,
      accounts: process.env.PRIVATE_KEY ? [process.env.PRIVATE_KEY] : [],
      gasPrice: "auto",
    },
  },

  // Contract verification on Polygonscan
  etherscan: {
    apiKey: {
      polygon:     process.env.POLYGONSCAN_API_KEY || "",
      polygonAmoy: process.env.POLYGONSCAN_API_KEY || "",
    },
  },

  paths: {
    sources:   "./contracts",
    tests:     "./test",
    cache:     "./cache",
    artifacts: "./artifacts",
  },
};
