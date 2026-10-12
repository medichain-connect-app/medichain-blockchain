const assert = require("node:assert/strict");
const { ethers } = require("hardhat");

// Same EIP-712 type the backend relayer signs (medichain-backend contractService.js).
const FORWARD_REQUEST_TYPES = {
  ForwardRequest: [
    { name: "from", type: "address" },
    { name: "to", type: "address" },
    { name: "value", type: "uint256" },
    { name: "gas", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint48" },
    { name: "data", type: "bytes" },
  ],
};

const GRANTED = 0n, REVOKED = 1n, VIEWED = 2n, DOWNLOADED = 3n;
const recordId = (uuid) => ethers.keccak256(ethers.toUtf8Bytes(uuid));

describe("MediAccessControl", function () {
  let forwarder, access, relayer, patient, doctor, stranger;
  const RECORD = recordId("3f6c1d8e-0000-4000-8000-000000000001");

  beforeEach(async function () {
    [relayer] = await ethers.getSigners();
    // Users get fresh, unfunded wallets — exactly like the backend's custodied ones.
    patient = ethers.Wallet.createRandom().connect(ethers.provider);
    doctor = ethers.Wallet.createRandom().connect(ethers.provider);
    stranger = ethers.Wallet.createRandom().connect(ethers.provider);

    forwarder = await (await ethers.getContractFactory("MediChainForwarder")).deploy();
    access = await (await ethers.getContractFactory("MediAccessControl")).deploy(await forwarder.getAddress());
  });

  /** Sign `fn(args)` as `user` and have the relayer submit it through the forwarder. */
  async function relay(user, fn, args) {
    const to = await access.getAddress();
    const data = access.interface.encodeFunctionData(fn, args);
    const { chainId } = await ethers.provider.getNetwork();
    // Estimated as a direct call from the user, with the same headroom as the backend.
    const estimated = await ethers.provider.estimateGas({ from: user.address, to, data }).catch(() => 500000n);
    const request = {
      from: user.address,
      to,
      value: 0n,
      gas: (estimated * 12n) / 10n + 10000n,
      nonce: await forwarder.nonces(user.address),
      deadline: (await ethers.provider.getBlock("latest")).timestamp + 600,
      data,
    };
    const signature = await user.signTypedData(
      { name: "MediChainForwarder", version: "1", chainId, verifyingContract: await forwarder.getAddress() },
      FORWARD_REQUEST_TYPES,
      request
    );
    const { nonce, ...rest } = request;
    return (await forwarder.connect(relayer).execute({ ...rest, signature })).wait();
  }

  it("lets an unfunded patient grant access through the relayer", async function () {
    assert.equal(await ethers.provider.getBalance(patient.address), 0n);

    await relay(patient, "grantAccess", [doctor.address, RECORD, 0]);

    assert.equal(await access.hasAccess(doctor.address, RECORD), true);
    assert.equal(await access.getRecordOwner(RECORD), patient.address);
    const log = await access.getAccessLog(RECORD);
    assert.equal(log.length, 1);
    assert.equal(log[0].action, GRANTED);
    assert.equal(log[0].patient, patient.address);
    assert.equal(log[0].doctor, doctor.address);
  });

  it("stores no key material on-chain", async function () {
    await relay(patient, "grantAccess", [doctor.address, RECORD, 0]);
    const grant = await access.getAccessDetails(doctor.address, RECORD);
    assert.deepEqual(
      Object.keys(grant.toObject()),
      ["doctor", "grantedAt", "isActive", "patient", "expiresAt"]
    );
  });

  it("logs a doctor's view and download, then blocks them after revoke", async function () {
    await relay(patient, "grantAccess", [doctor.address, RECORD, 0]);
    await relay(doctor, "logView", [RECORD]);
    await relay(doctor, "logDownload", [RECORD]);
    await relay(patient, "revokeAccess", [doctor.address, RECORD]);

    assert.equal(await access.hasAccess(doctor.address, RECORD), false);
    const actions = (await access.getAccessLog(RECORD)).map((e) => e.action);
    assert.deepEqual(actions, [GRANTED, VIEWED, DOWNLOADED, REVOKED]);

    await assert.rejects(relay(doctor, "logView", [RECORD]), /FailedCall|reverted/);
  });

  it("only lets the record owner grant or revoke", async function () {
    await relay(patient, "grantAccess", [doctor.address, RECORD, 0]);
    await assert.rejects(relay(stranger, "revokeAccess", [doctor.address, RECORD]), /FailedCall|reverted/);
    await assert.rejects(relay(stranger, "grantAccess", [relayer.address, RECORD, 0]), /FailedCall|reverted/);
    assert.equal(await access.hasAccess(doctor.address, RECORD), true);
  });

  it("rejects a request whose signature does not match the sender", async function () {
    const to = await access.getAddress();
    const data = access.interface.encodeFunctionData("grantAccess", [doctor.address, RECORD, 0]);
    const { chainId } = await ethers.provider.getNetwork();
    const deadline = (await ethers.provider.getBlock("latest")).timestamp + 600;
    // Stranger signs, but claims to be the patient.
    const signature = await stranger.signTypedData(
      { name: "MediChainForwarder", version: "1", chainId, verifyingContract: await forwarder.getAddress() },
      FORWARD_REQUEST_TYPES,
      { from: patient.address, to, value: 0n, gas: 300000n, nonce: 0n, deadline, data }
    );
    await assert.rejects(
      forwarder.connect(relayer).execute({ from: patient.address, to, value: 0n, gas: 300000n, deadline, data, signature }),
      /ERC2771ForwarderInvalidSigner|reverted/
    );
  });

  it("lists a doctor once even after revoke and re-grant", async function () {
    await relay(patient, "grantAccess", [doctor.address, RECORD, 0]);
    await relay(patient, "revokeAccess", [doctor.address, RECORD]);
    await relay(patient, "grantAccess", [doctor.address, RECORD, 0]);

    assert.deepEqual([...(await access.getDoctorsWithAccess(RECORD))], [doctor.address]);
    assert.deepEqual([...(await access.getActiveRecordsForDoctor(doctor.address))], [RECORD]);
  });

  it("treats an expired grant as no access", async function () {
    const now = (await ethers.provider.getBlock("latest")).timestamp;
    await relay(patient, "grantAccess", [doctor.address, RECORD, now + 60]);
    assert.equal(await access.hasAccess(doctor.address, RECORD), true);

    await ethers.provider.send("evm_increaseTime", [120]);
    await ethers.provider.send("evm_mine", []);

    assert.equal(await access.hasAccess(doctor.address, RECORD), false);
    assert.deepEqual([...(await access.getActiveRecordsForDoctor(doctor.address))], []);
  });
});
