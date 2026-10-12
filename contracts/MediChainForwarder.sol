// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC2771Forwarder} from "@openzeppelin/contracts/metatx/ERC2771Forwarder.sol";

/**
 * @title  MediChainForwarder
 * @notice OpenZeppelin's audited ERC-2771 forwarder. The backend relayer submits
 *         users' EIP-712-signed requests through it and pays the gas, so user
 *         wallets never need to hold POL. The EIP-712 domain name is
 *         "MediChainForwarder", version "1".
 */
contract MediChainForwarder is ERC2771Forwarder {
    constructor() ERC2771Forwarder("MediChainForwarder") {}
}
