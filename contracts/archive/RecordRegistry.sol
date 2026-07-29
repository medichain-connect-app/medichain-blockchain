// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IdentityRegistry.sol";

/**
 * @title RecordRegistry
 * @notice Stores medical record metadata on-chain.
 *         Actual encrypted files live on IPFS; only the CID, title,
 *         category, encrypted AES key, and SHA-256 hash are stored here.
 *
 *         Only registered patients (from IdentityRegistry) may upload records.
 *         Record IDs are auto-incremented starting from 1.
 */
contract RecordRegistry {

    // ─────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────

    struct MedicalRecord {
        uint256 id;
        address patient;
        string  cid;            // IPFS content identifier of the encrypted file
        string  title;
        string  category;       // e.g. "Lab Report", "Prescription", "X-Ray"
        string  encryptedKey;   // AES-256 key encrypted with patient's public key
        string  sha256Hash;     // SHA-256 of the original (pre-encryption) file
        uint256 uploadedAt;     // block.timestamp
        bool    isActive;
    }

    // ─────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────

    IdentityRegistry public identityRegistry;

    uint256 private _nextRecordId;

    mapping(uint256  => MedicalRecord) private _records;
    mapping(address  => uint256[])     private _patientRecords;

    // ─────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────

    event RecordUploaded(
        uint256 indexed recordId,
        address indexed patient,
        string  cid,
        string  title,
        string  category,
        uint256 timestamp
    );

    event RecordDeleted(
        uint256 indexed recordId,
        address indexed patient,
        uint256 timestamp
    );

    // ─────────────────────────────────────────────
    //  Modifiers
    // ─────────────────────────────────────────────

    modifier onlyPatient() {
        require(
            identityRegistry.isPatient(msg.sender),
            "RecordRegistry: caller is not a registered patient"
        );
        _;
    }

    modifier recordExists(uint256 recordId) {
        require(
            _records[recordId].isActive,
            "RecordRegistry: record does not exist or was deleted"
        );
        _;
    }

    modifier onlyRecordOwner(uint256 recordId) {
        require(
            _records[recordId].patient == msg.sender,
            "RecordRegistry: caller is not the record owner"
        );
        _;
    }

    // ─────────────────────────────────────────────
    //  Constructor
    // ─────────────────────────────────────────────

    constructor(address _identityRegistry) {
        require(_identityRegistry != address(0), "RecordRegistry: zero address");
        identityRegistry = IdentityRegistry(_identityRegistry);
        _nextRecordId    = 1;
    }

    // ─────────────────────────────────────────────
    //  Patient Actions
    // ─────────────────────────────────────────────

    /**
     * @notice Upload medical record metadata on-chain.
     * @param cid           IPFS CID of the encrypted file.
     * @param title         Human-readable title.
     * @param category      Record category (e.g. "Lab Report").
     * @param encryptedKey  AES key encrypted with the patient's public key.
     * @param sha256Hash    SHA-256 of the original file for integrity checks.
     * @return recordId     The newly assigned record ID.
     */
    function uploadRecord(
        string calldata cid,
        string calldata title,
        string calldata category,
        string calldata encryptedKey,
        string calldata sha256Hash
    ) external onlyPatient returns (uint256 recordId) {
        require(bytes(cid).length          > 0, "RecordRegistry: CID required");
        require(bytes(title).length        > 0, "RecordRegistry: title required");
        require(bytes(category).length     > 0, "RecordRegistry: category required");
        require(bytes(encryptedKey).length > 0, "RecordRegistry: encrypted key required");
        require(bytes(sha256Hash).length   > 0, "RecordRegistry: SHA-256 hash required");

        recordId = _nextRecordId++;

        _records[recordId] = MedicalRecord({
            id:           recordId,
            patient:      msg.sender,
            cid:          cid,
            title:        title,
            category:     category,
            encryptedKey: encryptedKey,
            sha256Hash:   sha256Hash,
            uploadedAt:   block.timestamp,
            isActive:     true
        });

        _patientRecords[msg.sender].push(recordId);

        emit RecordUploaded(
            recordId,
            msg.sender,
            cid,
            title,
            category,
            block.timestamp
        );
    }

    /**
     * @notice Soft-delete a record. Access control contract should also be notified
     *         (the patient must revoke all grants before or after deleting).
     */
    function deleteRecord(uint256 recordId)
        external
        recordExists(recordId)
        onlyRecordOwner(recordId)
    {
        _records[recordId].isActive = false;
        emit RecordDeleted(recordId, msg.sender, block.timestamp);
    }

    // ─────────────────────────────────────────────
    //  Queries
    // ─────────────────────────────────────────────

    /// @notice Returns the full metadata for a given record.
    function getRecord(uint256 recordId)
        external
        view
        recordExists(recordId)
        returns (MedicalRecord memory)
    {
        return _records[recordId];
    }

    /// @notice Returns the patient address that owns a record.
    function getRecordOwner(uint256 recordId)
        external
        view
        recordExists(recordId)
        returns (address)
    {
        return _records[recordId].patient;
    }

    /// @notice Returns all record IDs uploaded by the caller (patient only).
    function getMyRecords() external view onlyPatient returns (uint256[] memory) {
        return _patientRecords[msg.sender];
    }

    /// @notice Returns all record IDs for a given patient address.
    ///         Used by the AccessControl contract to list shared records.
    function getPatientRecords(address patient)
        external
        view
        returns (uint256[] memory)
    {
        return _patientRecords[patient];
    }

    /// @notice Total records ever uploaded (includes deleted ones).
    function totalRecords() external view returns (uint256) {
        return _nextRecordId - 1;
    }
}
