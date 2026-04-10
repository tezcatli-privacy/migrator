import { loadFixture } from "@nomicfoundation/hardhat-toolbox/network-helpers";
import hre from "hardhat";
import { expect } from "chai";

describe("Tezcatli GMX privacy wrapper", function () {
  async function buildRelayDigest(
    wrapperAddress: string,
    chainId: bigint,
    stealthAddress: string,
    gmxRouter: string,
    collateralToken: string,
    collateralAmount: bigint,
    collateralUsd: bigint,
    sizeUsd: bigint,
    nonce: bigint,
    deadline: bigint,
    multicallHash: string,
  ) {
    return hre.ethers.keccak256(
      hre.ethers.AbiCoder.defaultAbiCoder().encode(
        ["address", "uint256", "address", "address", "address", "uint256", "uint256", "uint256", "uint256", "uint256", "bytes32"],
        [
          wrapperAddress,
          chainId,
          stealthAddress,
          gmxRouter,
          collateralToken,
          collateralAmount,
          collateralUsd,
          sizeUsd,
          nonce,
          deadline,
          multicallHash,
        ],
      ),
    );
  }

  async function deployFixture() {
    const [deployer, stealthSigner, relayer, orderVault] = await hre.ethers.getSigners();

    const MockUSDC = await hre.ethers.getContractFactory("MockUSDC");
    const usdc = await MockUSDC.deploy();
    await usdc.waitForDeployment();

    const MockGmxExchangeRouter = await hre.ethers.getContractFactory("MockGmxExchangeRouter");
    const mockRouter = await MockGmxExchangeRouter.deploy();
    await mockRouter.waitForDeployment();

    const Wrapper = await hre.ethers.getContractFactory("TezcatliGmxPrivacyWrapper");
    const wrapper = await Wrapper.deploy(deployer.address);
    await wrapper.waitForDeployment();

    await (await wrapper.setApprovedRouter(await mockRouter.getAddress(), true)).wait();
    await (await wrapper.setApprovedCollateralToken(await usdc.getAddress(), true)).wait();

    await (await usdc.mint(stealthSigner.address, 100_000_000n)).wait();
    await (await usdc.connect(stealthSigner).approve(await wrapper.getAddress(), 100_000_000n)).wait();

    return {
      deployer,
      stealthSigner,
      relayer,
      orderVault,
      usdc,
      mockRouter,
      wrapper,
    };
  }

  it("relays a signed multicall order and funds GMX collateral flow", async function () {
    const { stealthSigner, relayer, orderVault, usdc, mockRouter, wrapper } = await loadFixture(deployFixture);

    const collateralAmount = 15_000_000n;
    const collateralUsd = 1_500_000_000000000000000000000000n; // 1500 * 1e30
    const sizeUsd = 3_000_000_000000000000000000000000n; // 3000 * 1e30 (2x)
    const orderKey = hre.ethers.keccak256(hre.ethers.toUtf8Bytes("gmx-order-1"));
    const multicallData = [
      mockRouter.interface.encodeFunctionData("sendTokens", [
        await usdc.getAddress(),
        orderVault.address,
        collateralAmount,
      ]),
      mockRouter.interface.encodeFunctionData("createOrder", [orderKey]),
    ];

    const multicallHash = hre.ethers.keccak256(
      hre.ethers.AbiCoder.defaultAbiCoder().encode(["bytes[]"], [multicallData]),
    );
    const nonce = await wrapper.nonces(stealthSigner.address);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const digest = await buildRelayDigest(
      await wrapper.getAddress(),
      BigInt((await hre.ethers.provider.getNetwork()).chainId),
      stealthSigner.address,
      await mockRouter.getAddress(),
      await usdc.getAddress(),
      collateralAmount,
      collateralUsd,
      sizeUsd,
      nonce,
      deadline,
      multicallHash,
    );
    const signature = await stealthSigner.signMessage(hre.ethers.getBytes(digest));

    await wrapper.connect(relayer).relayCreateOrder(
      {
        stealthAddress: stealthSigner.address,
        gmxRouter: await mockRouter.getAddress(),
        collateralToken: await usdc.getAddress(),
        collateralAmount,
        collateralUsd,
        sizeUsd,
        nonce,
        deadline,
        multicallHash,
      },
      signature,
      multicallData,
      hre.ethers.ZeroAddress,
    );

    expect(await usdc.balanceOf(orderVault.address)).to.equal(collateralAmount);
    expect(await usdc.balanceOf(await wrapper.getAddress())).to.equal(0n);
    expect(await wrapper.nonces(stealthSigner.address)).to.equal(1n);
    expect(await mockRouter.orderCount()).to.equal(1n);
    expect(await mockRouter.lastOrderAccount()).to.equal(await wrapper.getAddress());
    expect(await mockRouter.lastOrderKey()).to.equal(orderKey);
  });

  it("rejects unapproved routers", async function () {
    const { stealthSigner, relayer, usdc, mockRouter, wrapper } = await loadFixture(deployFixture);

    await (await wrapper.setApprovedRouter(await mockRouter.getAddress(), false)).wait();

    const collateralAmount = 1_000_000n;
    const collateralUsd = 100_000_000000000000000000000000n;
    const sizeUsd = 200_000_000000000000000000000000n;
    const multicallData = [
      mockRouter.interface.encodeFunctionData("sendTokens", [
        await usdc.getAddress(),
        relayer.address,
        collateralAmount,
      ]),
    ];

    const multicallHash = hre.ethers.keccak256(
      hre.ethers.AbiCoder.defaultAbiCoder().encode(["bytes[]"], [multicallData]),
    );
    const nonce = await wrapper.nonces(stealthSigner.address);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const digest = await buildRelayDigest(
      await wrapper.getAddress(),
      BigInt((await hre.ethers.provider.getNetwork()).chainId),
      stealthSigner.address,
      await mockRouter.getAddress(),
      await usdc.getAddress(),
      collateralAmount,
      collateralUsd,
      sizeUsd,
      nonce,
      deadline,
      multicallHash,
    );
    const signature = await stealthSigner.signMessage(hre.ethers.getBytes(digest));

    await expect(
      wrapper.connect(relayer).relayCreateOrder(
        {
          stealthAddress: stealthSigner.address,
          gmxRouter: await mockRouter.getAddress(),
          collateralToken: await usdc.getAddress(),
          collateralAmount,
          collateralUsd,
          sizeUsd,
          nonce,
          deadline,
          multicallHash,
        },
        signature,
        multicallData,
        hre.ethers.ZeroAddress,
      ),
    ).to.be.revertedWithCustomError(wrapper, "RouterNotApproved");
  });

  it("rejects tampered multicall payload", async function () {
    const { stealthSigner, relayer, orderVault, usdc, mockRouter, wrapper } = await loadFixture(deployFixture);

    const collateralAmount = 2_000_000n;
    const collateralUsd = 200_000_000000000000000000000000n;
    const sizeUsd = 400_000_000000000000000000000000n;
    const signedData = [
      mockRouter.interface.encodeFunctionData("sendTokens", [
        await usdc.getAddress(),
        orderVault.address,
        collateralAmount,
      ]),
    ];
    const sentData = [
      mockRouter.interface.encodeFunctionData("sendTokens", [
        await usdc.getAddress(),
        relayer.address,
        collateralAmount,
      ]),
    ];

    const multicallHash = hre.ethers.keccak256(
      hre.ethers.AbiCoder.defaultAbiCoder().encode(["bytes[]"], [signedData]),
    );
    const nonce = await wrapper.nonces(stealthSigner.address);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const digest = await buildRelayDigest(
      await wrapper.getAddress(),
      BigInt((await hre.ethers.provider.getNetwork()).chainId),
      stealthSigner.address,
      await mockRouter.getAddress(),
      await usdc.getAddress(),
      collateralAmount,
      collateralUsd,
      sizeUsd,
      nonce,
      deadline,
      multicallHash,
    );
    const signature = await stealthSigner.signMessage(hre.ethers.getBytes(digest));

    await expect(
      wrapper.connect(relayer).relayCreateOrder(
        {
          stealthAddress: stealthSigner.address,
          gmxRouter: await mockRouter.getAddress(),
          collateralToken: await usdc.getAddress(),
          collateralAmount,
          collateralUsd,
          sizeUsd,
          nonce,
          deadline,
          multicallHash,
        },
        signature,
        sentData,
        hre.ethers.ZeroAddress,
      ),
    ).to.be.revertedWithCustomError(wrapper, "InvalidMulticallHash");
  });

  it("rejects replay with stale nonce", async function () {
    const { stealthSigner, relayer, orderVault, usdc, mockRouter, wrapper } = await loadFixture(deployFixture);

    const collateralAmount = 3_000_000n;
    const collateralUsd = 300_000_000000000000000000000000n;
    const sizeUsd = 600_000_000000000000000000000000n;
    const multicallData = [
      mockRouter.interface.encodeFunctionData("sendTokens", [
        await usdc.getAddress(),
        orderVault.address,
        collateralAmount,
      ]),
    ];

    const multicallHash = hre.ethers.keccak256(
      hre.ethers.AbiCoder.defaultAbiCoder().encode(["bytes[]"], [multicallData]),
    );
    const nonce = await wrapper.nonces(stealthSigner.address);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const digest = await buildRelayDigest(
      await wrapper.getAddress(),
      BigInt((await hre.ethers.provider.getNetwork()).chainId),
      stealthSigner.address,
      await mockRouter.getAddress(),
      await usdc.getAddress(),
      collateralAmount,
      collateralUsd,
      sizeUsd,
      nonce,
      deadline,
      multicallHash,
    );
    const signature = await stealthSigner.signMessage(hre.ethers.getBytes(digest));

    const authorization = {
      stealthAddress: stealthSigner.address,
      gmxRouter: await mockRouter.getAddress(),
      collateralToken: await usdc.getAddress(),
      collateralAmount,
      collateralUsd,
      sizeUsd,
      nonce,
      deadline,
      multicallHash,
    };

    await wrapper.connect(relayer).relayCreateOrder(
      authorization,
      signature,
      multicallData,
      hre.ethers.ZeroAddress,
    );

    await expect(
      wrapper.connect(relayer).relayCreateOrder(
        authorization,
        signature,
        multicallData,
        hre.ethers.ZeroAddress,
      ),
    ).to.be.revertedWithCustomError(wrapper, "InvalidNonce");
  });

  it("rejects non-2x leverage policy", async function () {
    const { stealthSigner, relayer, orderVault, usdc, mockRouter, wrapper } = await loadFixture(deployFixture);

    const collateralAmount = 2_500_000n;
    const collateralUsd = 250_000_000000000000000000000000n;
    const sizeUsd = 300_000_000000000000000000000000n; // 1.2x, should fail
    const multicallData = [
      mockRouter.interface.encodeFunctionData("sendTokens", [
        await usdc.getAddress(),
        orderVault.address,
        collateralAmount,
      ]),
    ];

    const multicallHash = hre.ethers.keccak256(
      hre.ethers.AbiCoder.defaultAbiCoder().encode(["bytes[]"], [multicallData]),
    );
    const nonce = await wrapper.nonces(stealthSigner.address);
    const deadline = BigInt(Math.floor(Date.now() / 1000) + 3600);
    const digest = await buildRelayDigest(
      await wrapper.getAddress(),
      BigInt((await hre.ethers.provider.getNetwork()).chainId),
      stealthSigner.address,
      await mockRouter.getAddress(),
      await usdc.getAddress(),
      collateralAmount,
      collateralUsd,
      sizeUsd,
      nonce,
      deadline,
      multicallHash,
    );
    const signature = await stealthSigner.signMessage(hre.ethers.getBytes(digest));

    await expect(
      wrapper.connect(relayer).relayCreateOrder(
        {
          stealthAddress: stealthSigner.address,
          gmxRouter: await mockRouter.getAddress(),
          collateralToken: await usdc.getAddress(),
          collateralAmount,
          collateralUsd,
          sizeUsd,
          nonce,
          deadline,
          multicallHash,
        },
        signature,
        multicallData,
        hre.ethers.ZeroAddress,
      ),
    ).to.be.revertedWithCustomError(wrapper, "InvalidLeverage");
  });
});
