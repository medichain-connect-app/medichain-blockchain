// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC2771Context} from "@openzeppelin/contracts/metatx/ERC2771Context.sol";

/**
 * @title  MediAccessControl
 * @notice Hybrid architecture — the chain is the tamper-proof record of WHO may
 *         access WHICH record and WHAT they did with it.
 *
 *  ┌──────────────────────────────────────────────────────────────────┐
 *  │  Supabase  →  auth, user profiles, record metadata, AES keys     │
 *  │  IPFS      →  the encrypted medical files                        │
 *  │  THIS CONTRACT →                                                 │
 *  │    1. Access grants (patient → doctor, per record, with expiry)  │
 *  │    2. Immutable audit log (granted / revoked / viewed / download)│
 *  └──────────────────────────────────────────────────────────────────┘
 *
 *  No decryption keys are stored here. Everything on a public chain — storage
 *  and transaction input — is readable by anyone, so keys stay off-chain.
 *
 *  Record ID:  keccak256(utf8(supabaseRecordUUID)), linking a Supabase record
 *              to its on-chain grants and log.
 *
 *  Gas:  users never hold gas. Each user's wallet signs an EIP-712 request and
 *        the backend relayer submits it through the trusted ERC2771Forwarder,
 *        paying the gas. `_msgSender()` is still the signing user, so ownership
 *        and access checks work exactly as if the user had sent the transaction.
 */
contract MediAccessControl is ERC2771Context {

    // ─────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────

    enum ActionType { GRANTED, REVOKED, VIEWED, DOWNLOADED }

    // Fields are ordered and sized to pack into two storage slots each — the
    // relayer pays for every write, so storage is kept as small as possible.
    // The recordId is the mapping key, so it isn't stored again.

    struct AccessGrant {
        address doctor;
        uint64  grantedAt;
        bool    isActive;
        address patient;
        uint64  expiresAt;   // 0 = no expiry
    }

    struct AccessLog {
        address    doctor;
        uint64     timestamp;
        ActionType action;
        address    patient;
        uint64     blockNumber;
    }

    // ─────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────

    // recordId → patient address (set on the first grantAccess call)
    mapping(bytes32 => address) private _recordOwner;

    // recordId → doctor → grant
    mapping(bytes32 => mapping(address => AccessGrant)) private _grants;

    // recordId → every doctor ever granted access (each listed once)
    mapping(bytes32 => address[]) private _recordDoctors;

    // doctor → every recordId ever shared with them (each listed once)
    mapping(address => bytes32[]) private _doctorRecords;

    // recordId → full chronological audit log
    mapping(bytes32 => AccessLog[]) private _accessLogs;

    // ─────────────────────────────────────────────
    //  Events  (immutable on-chain audit trail)
    // ─────────────────────────────────────────────

    event AccessGranted(
        address indexed doctor,
        address indexed patient,
        bytes32 indexed recordId,
        uint256 expiresAt,
        uint256 timestamp
    );

    event AccessRevoked(
        address indexed doctor,
        address indexed patient,
        bytes32 indexed recordId,
        uint256 timestamp
    );

    event RecordViewed(
        address indexed doctor,
        address indexed patient,
        bytes32 indexed recordId,
        uint256 timestamp,
        uint256 blockNumber
    );

    event RecordDownloaded(
        address indexed doctor,
        address indexed patient,
        bytes32 indexed recordId,
        uint256 timestamp,
        uint256 blockNumber
    );

    constructor(address trustedForwarder) ERC2771Context(trustedForwarder) {}

    // ─────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────

    /**
     * @dev Ensures the caller is the patient who owns the record.
     *      On the first call for a new recordId the caller becomes the owner.
     */
    modifier onlyRecordOwner(bytes32 recordId) {
        address sender = _msgSender();
        if (_recordOwner[recordId] == address(0)) {
            _recordOwner[recordId] = sender;
        }
        require(
            _recordOwner[recordId] == sender,
            "MediAccessControl: caller is not the record owner"
        );
        _;
    }

    /// @dev Ensures the calling doctor has an active, non-expired grant.
    modifier hasValidAccess(bytes32 recordId) {
        require(_isValid(_grants[recordId][_msgSender()]), "MediAccessControl: no valid access");
        _;
    }

    // ─────────────────────────────────────────────
    //  Patient: grant / revoke
    // ─────────────────────────────────────────────

    /**
     * @notice Patient grants a doctor access to one record.
     * @param doctor     Wallet address of the doctor.
     * @param recordId   keccak256 of the Supabase record UUID.
     * @param expiresAt  Unix timestamp for expiry, or 0 for permanent.
     */
    function grantAccess(address doctor, bytes32 recordId, uint256 expiresAt)
        external
        onlyRecordOwner(recordId)
    {
        address patient = _msgSender();
        require(doctor != address(0), "MediAccessControl: invalid doctor address");
        require(doctor != patient,     "MediAccessControl: cannot grant access to yourself");
        require(
            expiresAt == 0 || (expiresAt > block.timestamp && expiresAt <= type(uint64).max),
            "MediAccessControl: invalid expiry"
        );
        require(
            !_isValid(_grants[recordId][doctor]),
            "MediAccessControl: access already granted, revoke first"
        );

        // Only list a doctor/record pair once, however often it is re-granted.
        if (_grants[recordId][doctor].grantedAt == 0) {
            _recordDoctors[recordId].push(doctor);
            _doctorRecords[doctor].push(recordId);
        }

        _grants[recordId][doctor] = AccessGrant({
            doctor:    doctor,
            grantedAt: uint64(block.timestamp),
            isActive:  true,
            patient:   patient,
            expiresAt: uint64(expiresAt)
        });

        _log(doctor, patient, recordId, ActionType.GRANTED);
        emit AccessGranted(doctor, patient, recordId, expiresAt, block.timestamp);
    }

    /// @notice Patient revokes a doctor's access to a record.
    function revokeAccess(address doctor, bytes32 recordId)
        external
        onlyRecordOwner(recordId)
    {
        require(
            _grants[recordId][doctor].isActive,
            "MediAccessControl: no active access to revoke"
        );

        _grants[recordId][doctor].isActive = false;

        address patient = _msgSender();
        _log(doctor, patient, recordId, ActionType.REVOKED);
        emit AccessRevoked(doctor, patient, recordId, block.timestamp);
    }

    // ─────────────────────────────────────────────
    //  Doctor: audit-log actions
    // ─────────────────────────────────────────────

    /// @notice Doctor logs that they opened a record.
    function logView(bytes32 recordId) external hasValidAccess(recordId) {
        address doctor  = _msgSender();
        address patient = _recordOwner[recordId];
        _log(doctor, patient, recordId, ActionType.VIEWED);
        emit RecordViewed(doctor, patient, recordId, block.timestamp, block.number);
    }

    /// @notice Doctor logs that they downloaded a record.
    function logDownload(bytes32 recordId) external hasValidAccess(recordId) {
        address doctor  = _msgSender();
        address patient = _recordOwner[recordId];
        _log(doctor, patient, recordId, ActionType.DOWNLOADED);
        emit RecordDownloaded(doctor, patient, recordId, block.timestamp, block.number);
    }

    // ─────────────────────────────────────────────
    //  Queries
    // ─────────────────────────────────────────────

    /// @notice True if the doctor currently has active, non-expired access.
    function hasAccess(address doctor, bytes32 recordId) external view returns (bool) {
        return _isValid(_grants[recordId][doctor]);
    }

    /// @notice Full grant details for a doctor/record pair.
    function getAccessDetails(address doctor, bytes32 recordId)
        external
        view
        returns (AccessGrant memory)
    {
        return _grants[recordId][doctor];
    }

    /// @notice Full chronological audit log for a record.
    function getAccessLog(bytes32 recordId) external view returns (AccessLog[] memory) {
        return _accessLogs[recordId];
    }

    /// @notice Every doctor ever granted access to a record.
    function getDoctorsWithAccess(bytes32 recordId) external view returns (address[] memory) {
        return _recordDoctors[recordId];
    }

    /// @notice The patient who owns a record.
    function getRecordOwner(bytes32 recordId) external view returns (address) {
        return _recordOwner[recordId];
    }

    /// @notice Records currently (active + non-expired) shared with a doctor.
    function getActiveRecordsForDoctor(address doctor) external view returns (bytes32[] memory) {
        bytes32[] storage all = _doctorRecords[doctor];
        uint256 count = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_isValid(_grants[all[i]][doctor])) count++;
        }

        bytes32[] memory active = new bytes32[](count);
        uint256 idx = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_isValid(_grants[all[i]][doctor])) active[idx++] = all[i];
        }
        return active;
    }

    // ─────────────────────────────────────────────
    //  Internal
    // ─────────────────────────────────────────────

    function _isValid(AccessGrant storage g) private view returns (bool) {
        return g.isActive && (g.expiresAt == 0 || block.timestamp <= g.expiresAt);
    }

    function _log(address doctor, address patient, bytes32 recordId, ActionType action) private {
        _accessLogs[recordId].push(AccessLog({
            doctor:      doctor,
            timestamp:   uint64(block.timestamp),
            action:      action,
            patient:     patient,
            blockNumber: uint64(block.number)
        }));
    }
}
