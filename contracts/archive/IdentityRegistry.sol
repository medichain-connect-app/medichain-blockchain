// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IdentityRegistry
 * @notice Manages patient and doctor identities on-chain.
 *         Wallet address = identity. No username/password needed.
 *         Doctors register with a license document hash (IPFS CID) for verifiability.
 */
contract IdentityRegistry {

    // ─────────────────────────────────────────────
    //  Types
    // ─────────────────────────────────────────────

    enum Role { None, Patient, Doctor }

    struct UserProfile {
        Role     role;
        string   name;
        string   licenseHash;   // IPFS CID of doctor's license document (empty for patients)
        bool     isActive;
        uint256  registeredAt;  // block.timestamp at registration
    }

    // ─────────────────────────────────────────────
    //  State
    // ─────────────────────────────────────────────

    mapping(address => UserProfile) private _profiles;

    address[] private _patientList;
    address[] private _doctorList;

    // ─────────────────────────────────────────────
    //  Events
    // ─────────────────────────────────────────────

    event PatientRegistered(
        address indexed patient,
        string  name,
        uint256 timestamp
    );

    event DoctorRegistered(
        address indexed doctor,
        string  name,
        string  licenseHash,
        uint256 timestamp
    );

    // ─────────────────────────────────────────────
    //  Registration
    // ─────────────────────────────────────────────

    /**
     * @notice Register the caller as a patient.
     * @param name  Full name of the patient.
     */
    function registerAsPatient(string calldata name) external {
        require(_profiles[msg.sender].role == Role.None, "IdentityRegistry: already registered");
        require(bytes(name).length > 0, "IdentityRegistry: name required");

        _profiles[msg.sender] = UserProfile({
            role:        Role.Patient,
            name:        name,
            licenseHash: "",
            isActive:    true,
            registeredAt: block.timestamp
        });

        _patientList.push(msg.sender);

        emit PatientRegistered(msg.sender, name, block.timestamp);
    }

    /**
     * @notice Register the caller as a doctor.
     * @param name         Full name of the doctor.
     * @param licenseHash  IPFS CID of the uploaded license document.
     */
    function registerAsDoctor(
        string calldata name,
        string calldata licenseHash
    ) external {
        require(_profiles[msg.sender].role == Role.None, "IdentityRegistry: already registered");
        require(bytes(name).length > 0,        "IdentityRegistry: name required");
        require(bytes(licenseHash).length > 0, "IdentityRegistry: license hash required");

        _profiles[msg.sender] = UserProfile({
            role:        Role.Doctor,
            name:        name,
            licenseHash: licenseHash,
            isActive:    true,
            registeredAt: block.timestamp
        });

        _doctorList.push(msg.sender);

        emit DoctorRegistered(msg.sender, name, licenseHash, block.timestamp);
    }

    // ─────────────────────────────────────────────
    //  Queries
    // ─────────────────────────────────────────────

    /// @notice Returns full profile of any address.
    function getProfile(address user)
        external
        view
        returns (
            Role    role,
            string  memory name,
            string  memory licenseHash,
            bool    isActive,
            uint256 registeredAt
        )
    {
        UserProfile storage p = _profiles[user];
        return (p.role, p.name, p.licenseHash, p.isActive, p.registeredAt);
    }

    /// @notice Returns true if the address is an active registered patient.
    function isPatient(address user) external view returns (bool) {
        return _profiles[user].role == Role.Patient && _profiles[user].isActive;
    }

    /// @notice Returns true if the address is an active registered doctor.
    function isDoctor(address user) external view returns (bool) {
        return _profiles[user].role == Role.Doctor && _profiles[user].isActive;
    }

    /// @notice Returns true if the address has any registered role.
    function isRegistered(address user) external view returns (bool) {
        return _profiles[user].role != Role.None;
    }

    /// @notice Returns the list of all registered doctor addresses.
    function getAllDoctors() external view returns (address[] memory) {
        return _doctorList;
    }

    /// @notice Returns the list of all registered patient addresses.
    function getAllPatients() external view returns (address[] memory) {
        return _patientList;
    }

    /// @notice Returns total number of registered patients.
    function totalPatients() external view returns (uint256) {
        return _patientList.length;
    }

    /// @notice Returns total number of registered doctors.
    function totalDoctors() external view returns (uint256) {
        return _doctorList.length;
    }
}
