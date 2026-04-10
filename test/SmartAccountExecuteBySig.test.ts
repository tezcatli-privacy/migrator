import { loadFixture, time } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import hre from "hardhat";
import { expect } from "chai";

describe("Tezcatli smart account executeBySig", function () {
  async function deployFixture() {
    const [deployer, owner, relayer, orderVault] = await hre.ethers.getSigners();

    const MockUSDC = await hre.ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    const MockGmxExchangeRouter = await hre.ethers.getContractFactory("MockGmxExchangeRouter");
    const gmxRouter = await MockGmxExchangeRouter.deploy();
    await gmxRouter.waitForDeployment();

    const SmartAccountFactory = await hre.ethers.getContractFactory("TezcatliSmartAccountFactory");
    const smartAccountFactory = await SmartAccountFactory.deploy();
    await smartAccountFactory.waitForDeployment();

    const sessionSalt = 20260410n;
    const sessionAccountAddress = await smartAccountFactory.predictAccountAddress(owner.address, sessionSalt);
    await (await smartAccountFactory.createAccount(owner.address, sessionSalt)).wait();

    const smartAccount = await hre.ethers.getContractAt("TezcatliSmartAccount", sessionAccountAddress);

    await (await usdc.mint(sessionAccountAddress, 80_000_000n)).wait();

    return {
      deployer,
      owner,
      relayer,
      orderVault,
      usdc,
      gmxRouter,
      smartAccountFactory,
      smartAccount,
      sessionSalt,
      sessionAccountAddress,
    };
  }

  it("executes a GMX-style order flow by relayer using executeBatchBySig", async function () {
    const { owner, relayer, orderVault, usdc, gmxRouter, smartAccount, sessionAccountAddress } =
      await loadFixture(deployFixture);

    const collateralAmount = 12_000_000n;
    const orderKey = hre.ethers.keccak256(hre.ethers.toUtf8Bytes("session-gmx-order-1"));
    const multicallPayload = [
      gmxRouter.interface.encodeFunctionData("sendTokens", [
        await usdc.getAddress(),
        orderVault.address,
        collateralAmount,
      ]),
      gmxRouter.interface.encodeFunctionData("createOrder", [orderKey]),
    ];

    const targets = [await usdc.getAddress(), await gmxRouter.getAddress()];
    const values = [0n, 0n];
    const datas = [
      usdc.interface.encodeFunctionData("approve", [await gmxRouter.getAddress(), collateralAmount]),
      gmxRouter.interface.encodeFunctionData("multicall", [multicallPayload]),
    ];

    const nonce = await smartAccount.executionNonce();
    const deadline = BigInt(await time.latest()) + 3600n;
    const digest = await smartAccount.getExecuteBatchDigest(targets, values, datas, nonce, deadline);
    const signature = await owner.signMessage(hre.ethers.getBytes(digest));

    await smartAccount.connect(relayer).executeBatchBySig(
      targets,
      values,
      datas,
      deadline,
      signature,
    );

    expect(await smartAccount.executionNonce()).to.equal(1n);
    expect(await usdc.balanceOf(orderVault.address)).to.equal(collateralAmount);
    expect(await usdc.balanceOf(sessionAccountAddress)).to.equal(68_000_000n);
    expect(await gmxRouter.orderCount()).to.equal(1n);
    expect(await gmxRouter.lastOrderAccount()).to.equal(sessionAccountAddress);
    expect(await gmxRouter.lastOrderKey()).to.equal(orderKey);
  });

  it("rejects replay for executeBySig due to nonce changes", async function () {
    const { owner, relayer, usdc, smartAccount } = await loadFixture(deployFixture);

    const amount = 1_000_000n;
    const transferCall = usdc.interface.encodeFunctionData("transfer", [relayer.address, amount]);
    const nonce = await smartAccount.executionNonce();
    const deadline = BigInt(await time.latest()) + 3600n;
    const digest = await smartAccount.getExecuteDigest(
      await usdc.getAddress(),
      0,
      transferCall,
      nonce,
      deadline,
    );
    const signature = await owner.signMessage(hre.ethers.getBytes(digest));

    await smartAccount.connect(relayer).executeBySig(
      await usdc.getAddress(),
      0,
      transferCall,
      deadline,
      signature,
    );

    await expect(
      smartAccount.connect(relayer).executeBySig(
        await usdc.getAddress(),
        0,
        transferCall,
        deadline,
        signature,
      ),
    ).to.be.revertedWith("Invalid signature");
  });

  it("rejects expired executeBatchBySig authorization", async function () {
    const { owner, relayer, usdc, smartAccount } = await loadFixture(deployFixture);

    const targets = [await usdc.getAddress()];
    const values = [0n];
    const datas = [usdc.interface.encodeFunctionData("approve", [relayer.address, 1_000_000n])];

    const nonce = await smartAccount.executionNonce();
    const deadline = BigInt(await time.latest()) + 60n;
    const digest = await smartAccount.getExecuteBatchDigest(targets, values, datas, nonce, deadline);
    const signature = await owner.signMessage(hre.ethers.getBytes(digest));

    await time.increase(120);

    await expect(
      smartAccount.connect(relayer).executeBatchBySig(
        targets,
        values,
        datas,
        deadline,
        signature,
      ),
    ).to.be.revertedWith("Expired authorization");
  });
});
