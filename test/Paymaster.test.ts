import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import hre from "hardhat";
import { expect } from "chai";

describe("Tezcatli paymaster", function () {
  async function deployFixture() {
    const [deployer, owner, treasury] = await hre.ethers.getSigners();

    const MockUSDC = await hre.ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    const EntryPoint = await hre.ethers.getContractFactory("TezcatliEntryPointMock");
    const entryPoint = await EntryPoint.deploy();
    await entryPoint.waitForDeployment();

    const AccountFactory = await hre.ethers.getContractFactory("Tezcatli4337AccountFactory");
    const accountFactory = await AccountFactory.deploy(await entryPoint.getAddress());
    await accountFactory.waitForDeployment();

    const Paymaster = await hre.ethers.getContractFactory("TezcatliPaymaster");
    const paymaster = await Paymaster.deploy(
      await entryPoint.getAddress(),
      await usdc.getAddress(),
      treasury.address,
      5_000_000n,
      await accountFactory.getAddress(),
      deployer.address,
    );
    await paymaster.waitForDeployment();

    const MockComplianceGate = await hre.ethers.getContractFactory("MockComplianceGate");
    const complianceGate = await MockComplianceGate.deploy();
    await complianceGate.waitForDeployment();

    const Target = await hre.ethers.getContractFactory("MockTarget");
    const target = await Target.deploy();
    await target.waitForDeployment();

    await (await paymaster.setApprovedTarget(await target.getAddress(), true)).wait();

    const salt = 1n;
    const accountAddress = await accountFactory.predictAccountAddress(owner.address, salt);
    await (await accountFactory.createAccount(owner.address, salt)).wait();

    const account = await hre.ethers.getContractAt("Tezcatli4337Account", accountAddress);

    await (await usdc.mint(accountAddress, 2_000_000_000n)).wait();
    const approveCalldata = usdc.interface.encodeFunctionData("approve", [await paymaster.getAddress(), hre.ethers.MaxUint256]);
    await (await account.connect(owner).execute(await usdc.getAddress(), 0, approveCalldata)).wait();

    return {
      deployer,
      owner,
      treasury,
      usdc,
      entryPoint,
      accountFactory,
      paymaster,
      complianceGate,
      target,
      account,
      accountAddress,
    };
  }

  function buildPaymasterAndData(paymaster: string, transferAmount: bigint) {
    return hre.ethers.solidityPacked(["address", "uint256"], [paymaster, transferAmount]);
  }

  it("sponsors an approved execute call and charges fee in USDC", async function () {
    const { owner, treasury, usdc, entryPoint, paymaster, target, account, accountAddress } = await loadFixture(deployFixture);

    const transferAmount = 400_000n;
    const paymasterAndData = buildPaymasterAndData(await paymaster.getAddress(), transferAmount);
    const callData = account.interface.encodeFunctionData("execute", [
      await target.getAddress(),
      0,
      target.interface.encodeFunctionData("ping", [42]),
    ]);

    const userOp = {
      sender: accountAddress,
      nonce: 0n,
      initCode: "0x",
      callData,
      accountGasLimits: hre.ethers.ZeroHash,
      preVerificationGas: 0n,
      gasFees: hre.ethers.ZeroHash,
      paymasterAndData,
      signature: "0x",
    };

    const userOpHash = await entryPoint.getUserOpHash(userOp);
    userOp.signature = await owner.signMessage(hre.ethers.getBytes(userOpHash));

    await entryPoint.handleOps([userOp], treasury.address);

    expect(await target.counter()).to.equal(1n);
    expect(await target.lastValue()).to.equal(42n);

    const expectedFee = (transferAmount * 100n) / 10_000n;
    expect(await usdc.balanceOf(treasury.address)).to.equal(expectedFee);
  });

  it("rejects non-approved targets", async function () {
    const { owner, treasury, entryPoint, paymaster, account, accountAddress } = await loadFixture(deployFixture);

    const AnotherTarget = await hre.ethers.getContractFactory("MockTarget");
    const anotherTarget = await AnotherTarget.deploy();
    await anotherTarget.waitForDeployment();

    const userOp = {
      sender: accountAddress,
      nonce: 0n,
      initCode: "0x",
      callData: account.interface.encodeFunctionData("execute", [
        await anotherTarget.getAddress(),
        0,
        anotherTarget.interface.encodeFunctionData("ping", [7]),
      ]),
      accountGasLimits: hre.ethers.ZeroHash,
      preVerificationGas: 0n,
      gasFees: hre.ethers.ZeroHash,
      paymasterAndData: buildPaymasterAndData(await paymaster.getAddress(), 100_000n),
      signature: "0x",
    };

    const userOpHash = await entryPoint.getUserOpHash(userOp);
    userOp.signature = await owner.signMessage(hre.ethers.getBytes(userOpHash));

    await expect(entryPoint.handleOps([userOp], treasury.address))
      .to.be.revertedWithCustomError(paymaster, "UnapprovedTarget");
  });

  it("rejects unsupported account call selectors for sponsorship", async function () {
    const { owner, treasury, entryPoint, paymaster, target, account, accountAddress } = await loadFixture(deployFixture);

    const userOp = {
      sender: accountAddress,
      nonce: 0n,
      initCode: "0x",
      callData: account.interface.encodeFunctionData("executeBatch", [
        [await target.getAddress()],
        [0],
        [target.interface.encodeFunctionData("ping", [9])],
      ]),
      accountGasLimits: hre.ethers.ZeroHash,
      preVerificationGas: 0n,
      gasFees: hre.ethers.ZeroHash,
      paymasterAndData: buildPaymasterAndData(await paymaster.getAddress(), 100_000n),
      signature: "0x",
    };

    const userOpHash = await entryPoint.getUserOpHash(userOp);
    userOp.signature = await owner.signMessage(hre.ethers.getBytes(userOpHash));

    await expect(entryPoint.handleOps([userOp], treasury.address))
      .to.be.revertedWithCustomError(paymaster, "UnsupportedAccountCall");
  });

  it("rejects account deployments from unapproved factories", async function () {
    const { owner, treasury, usdc, entryPoint, accountFactory, paymaster, target } = await loadFixture(deployFixture);

    await (await paymaster.setApprovedFactory(hre.ethers.Wallet.createRandom().address)).wait();

    const salt = 333n;
    const sender = await accountFactory.predictAccountAddress(owner.address, salt);
    await (await usdc.mint(sender, 100_000_000n)).wait();

    const accountFactoryCall = accountFactory.interface.encodeFunctionData("createAccount", [owner.address, salt]);
    const initCode = hre.ethers.concat([await accountFactory.getAddress(), accountFactoryCall]);

    const tempAccount = await hre.ethers.getContractAt("Tezcatli4337Account", sender);
    const callData = tempAccount.interface.encodeFunctionData("execute", [
      await target.getAddress(),
      0,
      target.interface.encodeFunctionData("ping", [11]),
    ]);

    const userOp = {
      sender,
      nonce: 0n,
      initCode,
      callData,
      accountGasLimits: hre.ethers.ZeroHash,
      preVerificationGas: 0n,
      gasFees: hre.ethers.ZeroHash,
      paymasterAndData: buildPaymasterAndData(await paymaster.getAddress(), 0n),
      signature: "0x",
    };

    const userOpHash = await entryPoint.getUserOpHash(userOp);
    userOp.signature = await owner.signMessage(hre.ethers.getBytes(userOpHash));

    await expect(entryPoint.handleOps([userOp], treasury.address))
      .to.be.revertedWithCustomError(paymaster, "UnapprovedFactory");
  });

  it("rejects sponsored calls when compliance gate denies the wallet", async function () {
    const { owner, treasury, entryPoint, paymaster, complianceGate, target, account, accountAddress } = await loadFixture(deployFixture);

    await (await paymaster.setComplianceGate(await complianceGate.getAddress())).wait();
    await (await paymaster.setComplianceEnabled(true)).wait();
    await (await complianceGate.setShieldDecision(false, 2)).wait();

    const userOp = {
      sender: accountAddress,
      nonce: 0n,
      initCode: "0x",
      callData: account.interface.encodeFunctionData("execute", [
        await target.getAddress(),
        0,
        target.interface.encodeFunctionData("ping", [17]),
      ]),
      accountGasLimits: hre.ethers.ZeroHash,
      preVerificationGas: 0n,
      gasFees: hre.ethers.ZeroHash,
      paymasterAndData: buildPaymasterAndData(await paymaster.getAddress(), 100_000n),
      signature: "0x",
    };

    const userOpHash = await entryPoint.getUserOpHash(userOp);
    userOp.signature = await owner.signMessage(hre.ethers.getBytes(userOpHash));

    await expect(entryPoint.handleOps([userOp], treasury.address))
      .to.be.revertedWithCustomError(paymaster, "ComplianceRejected")
      .withArgs(2);
  });

  it("keeps report-only compliance decisions non-blocking", async function () {
    const { owner, treasury, usdc, entryPoint, paymaster, complianceGate, target, account, accountAddress } = await loadFixture(deployFixture);

    await (await paymaster.setComplianceGate(await complianceGate.getAddress())).wait();
    await (await paymaster.setComplianceEnabled(true)).wait();
    await (await complianceGate.setShieldDecision(true, 7)).wait();

    const transferAmount = 320_000n;
    const paymasterAndData = buildPaymasterAndData(await paymaster.getAddress(), transferAmount);
    const callData = account.interface.encodeFunctionData("execute", [
      await target.getAddress(),
      0,
      target.interface.encodeFunctionData("ping", [99]),
    ]);

    const userOp = {
      sender: accountAddress,
      nonce: 0n,
      initCode: "0x",
      callData,
      accountGasLimits: hre.ethers.ZeroHash,
      preVerificationGas: 0n,
      gasFees: hre.ethers.ZeroHash,
      paymasterAndData,
      signature: "0x",
    };

    const userOpHash = await entryPoint.getUserOpHash(userOp);
    userOp.signature = await owner.signMessage(hre.ethers.getBytes(userOpHash));

    await expect(entryPoint.handleOps([userOp], treasury.address))
      .to.emit(paymaster, "ComplianceReportRequired")
      .withArgs(accountAddress, hre.ethers.ZeroHash, 7);

    expect(await target.lastValue()).to.equal(99n);
    expect(await usdc.balanceOf(treasury.address)).to.equal((transferAmount * 100n) / 10_000n);
  });
});
