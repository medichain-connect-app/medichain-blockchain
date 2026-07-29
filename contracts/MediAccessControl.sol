// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title  MediAccessControl
 * @notice Approach 2 — Hybrid Architecture
 *
 *  What this contract does:
 *  ┌──────────────────────────────────────────────────────────────────┐
 *  │  Supabase  →  handles auth, user profiles, record metadata       │
 *  │  IPFS      →  stores the actual encrypted medical files          │
 *  │  THIS CONTRACT →  handles ONLY:                                  │
 *  │    1. Access control  (who can decrypt which record)             │
 *  │    2. Encrypted key   (AES key re-encrypted for each doctor)     │
 *  │    3. Audit log       (immutable on-chain log of every access)   │
 *  └──────────────────────────────────────────────────────────────────┘
 *
 *  Record ID:
 *    recordId is a bytes32 — computed in Flutter as:
 *    keccak256(utf8.encode(supabaseRecordUUID))
 *    This links a Supabase record to its on-chain access control entry.
 *
 *  Key Flow:
 *    Upload  : Patient encrypts file (AES-256) → uploads to IPFS → stores
 *              metadata in Supabase. No contract call needed yet.
 *
 *    Share   : Patient re-encrypts AES key with doctor's public key (off-chain
 *              in Flutter), then calls grantAccess(). Encrypted key stored here.
 *
 *    Access  : Doctor calls getEncryptedKey() → decrypts with own private key
 *              locally → fetches IPFS file → decrypts with AES key.
 *              Doctor then calls logView() or logDownload() for the audit log.
 *
 *    Revoke  : Patient calls revokeAccess() → doctor's encrypted key is wiped
 *              from storage, grant deactivated. Future getEncryptedKey() reverts.
 */
contract MediAccessControl {

    // ─────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────

    enum ActionType { GRANTED, REVOKED, VIEWED, DOWNLOADED }

    struct AccessGrant {
        address doctor;
        address patient;
        bytes32 recordId;
        string  encryptedKeyForDoctor;  // AES key re-encrypted with doctor's public key
        uint256 grantedAt;
        uint256 expiresAt;              // 0 = no expiry
        bool    isActive;
    }

    struct AccessLog {
        address    doctor;
        address    patient;
        bytes32    recordId;
        ActionType action;
        uint256    timestamp;
        uint256    blockNumber;
    }

    // ─────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────

    // recordId → patient address (set on first grantAccess call)
    // This is how the contract knows who "owns" a record without IdentityRegistry
    mapping(bytes32 => address) private _recordOwner;

    // recordId → doctor → grant
    mapping(bytes32 => mapping(address => AccessGrant)) private _grants;

    // recordId → all doctors ever granted access (for enumeration)
    mapping(bytes32 => address[]) private _recordDoctors;

    // doctor → all recordIds ever shared with them
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

    // ─────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────

    /**
     * @dev Ensures caller is the patient who owns the record.
     *      On first call for a new recordId the caller becomes the owner.
     */
    modifier onlyRecordOwner(bytes32 recordId) {
        if (_recordOwner[recordId] == address(0)) {
            // First time this record is seen — register caller as owner
            _recordOwner[recordId] = msg.sender;
        }
        require(
            _recordOwner[recordId] == msg.sender,
            "MediAccessControl: caller is not the record owner"
        );
        _;
    }

    /**
     * @dev Ensures the calling doctor has an active, non-expired grant.
     */
    modifier hasValidAccess(bytes32 recordId) {
        AccessGrant storage g = _grants[recordId][msg.sender];
        require(g.isActive, "MediAccessControl: access not granted");
        require(
            g.expiresAt == 0 || block.timestamp <= g.expiresAt,
            "MediAccessControl: access has expired"
        );
        _;
    }

    // ─────────────────────────────────────────────
    //  Patient: Grant Access
    // ─────────────────────────────────────────────

    /**
     * @notice Patient grants a doctor access to one specific record.
     *
     * @param doctor                 Wallet address of the doctor.
     * @param recordId               keccak256 of the Supabase record UUID.
     * @param encryptedKeyForDoctor  AES key re-encrypted with doctor's public key
     *                               (done off-chain in Flutter before calling this).
     * @param expiresAt              Unix timestamp for expiry, or 0 for permanent.
     */
    function grantAccess(
        address doctor,
        bytes32 recordId,
        string  calldata encryptedKeyForDoctor,
        uint256 expiresAt
    )
        external
        onlyRecordOwner(recordId)
    {
        require(doctor != address(0),                    "MediAccessControl: invalid doctor address");
        require(doctor != msg.sender,                    "MediAccessControl: cannot grant access to yourself");
        require(bytes(encryptedKeyForDoctor).length > 0, "MediAccessControl: encrypted key required");
        require(
            expiresAt == 0 || expiresAt > block.timestamp,
            "MediAccessControl: expiry must be in the future"
        );
        require(
            !_grants[recordId][doctor].isActive,
            "MediAccessControl: access already granted, revoke first"
        );

        _grants[recordId][doctor] = AccessGrant({
            doctor:                doctor,
            patient:               msg.sender,
            recordId:              recordId,
            encryptedKeyForDoctor: encryptedKeyForDoctor,
            grantedAt:             block.timestamp,
            expiresAt:             expiresAt,
            isActive:              true
        });

        _recordDoctors[recordId].push(doctor);
        _doctorRecords[doctor].push(recordId);

        _accessLogs[recordId].push(AccessLog({
            doctor:      doctor,
            patient:     msg.sender,
            recordId:    recordId,
            action:      ActionType.GRANTED,
            timestamp:   block.timestamp,
            blockNumber: block.number
        }));

        emit AccessGranted(doctor, msg.sender, recordId, expiresAt, block.timestamp);
    }

    // ─────────────────────────────────────────────
    //  Patient: Revoke Access
    // ─────────────────────────────────────────────

    /**
     * @notice Patient revokes a doctor's access to a record.
     *         The encrypted key is wiped from storage immediately.
     *         Doctor's next call to getEncryptedKey() will revert.
     */
    function revokeAccess(address doctor, bytes32 recordId)
        external
        onlyRecordOwner(recordId)
    {
        require(
            _grants[recordId][doctor].isActive,
            "MediAccessControl: no active access to revoke"
        );

        _grants[recordId][doctor].isActive             = false;
        _grants[recordId][doctor].encryptedKeyForDoctor = "";  // wipe the key

        _accessLogs[recordId].push(AccessLog({
            doctor:      doctor,
            patient:     msg.sender,
            recordId:    recordId,
            action:      ActionType.REVOKED,
            timestamp:   block.timestamp,
            blockNumber: block.number
        }));

        emit AccessRevoked(doctor, msg.sender, recordId, block.timestamp);
    }

    // ─────────────────────────────────────────────
    //  Doctor: Get Encrypted Key
    // ─────────────────────────────────────────────

    /**
     * @notice Doctor retrieves the AES decryption key encrypted for them.
     *         Reverts if access was never granted, revoked, or expired.
     *
     *         The doctor decrypts this key locally using their private key,
     *         then uses the resulting AES key to decrypt the IPFS file.
     *
     * @param  recordId  The record to access.
     * @return           Base64-encoded AES key encrypted with doctor's public key.
     */
    function getEncryptedKey(bytes32 recordId)
        external
        view
        hasValidAccess(recordId)
        returns (string memory)
    {
        return _grants[recordId][msg.sender].encryptedKeyForDoctor;
    }

    // ─────────────────────────────────────────────
    //  Doctor: Log Actions (audit trail)
    // ─────────────────────────────────────────────

    /**
     * @notice Doctor logs a VIEW action — call this after opening a record.
     *         Emits RecordViewed and appends to the immutable on-chain audit log.
     */
    function logView(bytes32 recordId)
        external
        hasValidAccess(recordId)
    {
        address patient = _recordOwner[recordId];

        _accessLogs[recordId].push(AccessLog({
            doctor:      msg.sender,
            patient:     patient,
            recordId:    recordId,
            action:      ActionType.VIEWED,
            timestamp:   block.timestamp,
            blockNumber: block.number
        }));

        emit RecordViewed(msg.sender, patient, recordId, block.timestamp, block.number);
    }

    /**
     * @notice Doctor logs a DOWNLOAD action — call this after downloading a record.
     *         Emits RecordDownloaded and appends to the immutable on-chain audit log.
     */
    function logDownload(bytes32 recordId)
        external
        hasValidAccess(recordId)
    {
        address patient = _recordOwner[recordId];

        _accessLogs[recordId].push(AccessLog({
            doctor:      msg.sender,
            patient:     patient,
            recordId:    recordId,
            action:      ActionType.DOWNLOADED,
            timestamp:   block.timestamp,
            blockNumber: block.number
        }));

        emit RecordDownloaded(msg.sender, patient, recordId, block.timestamp, block.number);
    }

    // ─────────────────────────────────────────────
    //  Query Functions
    // ─────────────────────────────────────────────

    /// @notice Check if a doctor currently has valid (active + non-expired) access.
    function hasAccess(address doctor, bytes32 recordId)
        external
        view
        returns (bool)
    {
        AccessGrant storage g = _grants[recordId][doctor];
        if (!g.isActive) return false;
        if (g.expiresAt != 0 && block.timestamp > g.expiresAt) return false;
        return true;
    }

    /// @notice Returns full grant details for a doctor-record pair.
    function getAccessDetails(address doctor, bytes32 recordId)
        external
        view
        returns (AccessGrant memory)
    {
        return _grants[recordId][doctor];
    }

    /**
     * @notice Returns the full chronological audit log for a record.
     *         Contains every GRANT, REVOKE, VIEW, DOWNLOAD — immutable and
     *         tamper-proof. Anyone can read this (it's public).
     */
    function getAccessLog(bytes32 recordId)
        external
        view
        returns (AccessLog[] memory)
    {
        return _accessLogs[recordId];
    }

    /// @notice Returns all doctor addresses ever granted access to a record.
    function getDoctorsWithAccess(bytes32 recordId)
        external
        view
        returns (address[] memory)
    {
        return _recordDoctors[recordId];
    }

    /// @notice Returns the patient (owner) of a record.
    function getRecordOwner(bytes32 recordId)
        external
        view
        returns (address)
    {
        return _recordOwner[recordId];
    }

    /// @notice Doctor: returns all record IDs ever shared with caller.
    function getMySharedRecords()
        external
        view
        returns (bytes32[] memory)
    {
        return _doctorRecords[msg.sender];
    }

    /// @notice Returns only currently active (non-revoked, non-expired) records for a doctor.
    function getActiveRecordsForDoctor(address doctor)
        external
        view
        returns (bytes32[] memory)
    {
        bytes32[] storage all   = _doctorRecords[doctor];
        uint256            count = 0;

        for (uint256 i = 0; i < all.length; i++) {
            AccessGrant storage g = _grants[all[i]][doctor];
            if (g.isActive && (g.expiresAt == 0 || block.timestamp <= g.expiresAt)) {
                count++;
            }
        }

        bytes32[] memory active = new bytes32[](count);
        uint256   idx           = 0;

        for (uint256 i = 0; i < all.length; i++) {
            AccessGrant storage g = _grants[all[i]][doctor];
            if (g.isActive && (g.expiresAt == 0 || block.timestamp <= g.expiresAt)) {
                active[idx++] = all[i];
            }
        }

        return active;
    }
}
