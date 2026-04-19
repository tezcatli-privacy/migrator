import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadSharedManifest, saveDeployment, saveSharedManifest } from "./utils";

task("deploy-alpha-stack", "Deploy the Tezcatli alpha stack with multi-asset support").setAction(
  async (_, hre: HardhatRuntimeEnvironment) => {
    const { ethers, network } = hre;
    const [deployer] = await ethers.getSigners();
    const chainId = Number((await ethers.provider.getNetwork()).chainId);

    console.log(`Deploying Tezcatli alpha stack to ${network.name} (${chainId}) with ${deployer.address}`);

    const MockUSDC = await ethers.getContractFactory("MockUSDC");
    const mockUSDC = await MockUSDC.deploy();
    await mockUSDC.waitForDeployment();

    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const mockUSDT = await MockERC20.deploy("Mock Tether USD", "USDT", 6);
    await mockUSDT.waitForDeployment();
    const mockWBTC = await MockERC20.deploy("Mock Wrapped Bitcoin", "WBTC", 8);
    await mockWBTC.waitForDeployment();
    const mockWETH = await MockERC20.deploy("Mock Wrapped Ether", "WETH", 18);
    await mockWETH.waitForDeployment();

    const WrappedToken = await ethers.getContractFactory("TezcatliWrappedToken");
    const wrappedUSDC = await WrappedToken.deploy("Tezcatli Confidential USD Coin", "tzcUSDC", await mockUSDC.getAddress(), 6);
    await wrappedUSDC.waitForDeployment();
    const wrappedUSDT = await WrappedToken.deploy("Tezcatli Confidential Tether", "tzcUSDT", await mockUSDT.getAddress(), 6);
    await wrappedUSDT.waitForDeployment();
    const wrappedWBTC = await WrappedToken.deploy("Tezcatli Confidential Bitcoin", "tzcWBTC", await mockWBTC.getAddress(), 8);
    await wrappedWBTC.waitForDeployment();
    const wrappedWETH = await WrappedToken.deploy("Tezcatli Confidential Ether", "tzcWETH", await mockWETH.getAddress(), 18);
    await wrappedWETH.waitForDeployment();

    const Registry = await ethers.getContractFactory("TezcatliStealthRegistry");
    const registry = await Registry.deploy();
    await registry.waitForDeployment();

    const Announcer = await ethers.getContractFactory("TezcatliStealthAnnouncer");
    const announcer = await Announcer.deploy();
    await announcer.waitForDeployment();

    const Migrator = await ethers.getContractFactory("TezcatliMigrator");
    const migrator = await Migrator.deploy();
    await migrator.waitForDeployment();

    const MockDustToken = await ethers.getContractFactory("MockDustToken");
    const mockDustToken = await MockDustToken.deploy();
    await mockDustToken.waitForDeployment();

    const DustSwap = await ethers.getContractFactory("TezcatliDustSwap");
    const dustSwap = await DustSwap.deploy(await mockUSDC.getAddress(), deployer.address);
    await dustSwap.waitForDeployment();

    const SmartAccountFactory = await ethers.getContractFactory("TezcatliSmartAccountFactory");
    const smartAccountFactory = await SmartAccountFactory.deploy();
    await smartAccountFactory.waitForDeployment();

    const EntryPointMock = await ethers.getContractFactory("TezcatliEntryPointMock");
    const entryPointMock = await EntryPointMock.deploy();
    await entryPointMock.waitForDeployment();

    const Smart4337Factory = await ethers.getContractFactory("Tezcatli4337AccountFactory");
    const smart4337Factory = await Smart4337Factory.deploy(await entryPointMock.getAddress());
    await smart4337Factory.waitForDeployment();

    const Paymaster = await ethers.getContractFactory("TezcatliPaymaster");
    const paymaster = await Paymaster.deploy(
      await entryPointMock.getAddress(),
      await mockUSDC.getAddress(),
      deployer.address,
      5_000_000n,
      await smart4337Factory.getAddress(),
      deployer.address,
    );
    await paymaster.waitForDeployment();

    const VaultFactory = await ethers.getContractFactory("TezcatliConfidentialVaultFactory");
    const vaultFactory = await VaultFactory.deploy(deployer.address);
    await vaultFactory.waitForDeployment();

    const VaultCoordinator = await ethers.getContractFactory("TezcatliVaultCoordinator");
    const vaultCoordinator = await VaultCoordinator.deploy(deployer.address);
    await vaultCoordinator.waitForDeployment();

    const VaultFeeModel = await ethers.getContractFactory("TezcatliVaultFeeModel");
    const vaultFeeModel = await VaultFeeModel.deploy();
    await vaultFeeModel.waitForDeployment();

    const assets = [
      {
        key: "USDC",
        displaySymbol: "USDC",
        underlying: await mockUSDC.getAddress(),
        wrapped: await wrappedUSDC.getAddress(),
      },
      {
        key: "USDT",
        displaySymbol: "USDT",
        underlying: await mockUSDT.getAddress(),
        wrapped: await wrappedUSDT.getAddress(),
      },
      {
        key: "WBTC",
        displaySymbol: "WBTC",
        underlying: await mockWBTC.getAddress(),
        wrapped: await wrappedWBTC.getAddress(),
      },
      {
        key: "WETH",
        displaySymbol: "ETH",
        underlying: await mockWETH.getAddress(),
        wrapped: await wrappedWETH.getAddress(),
      },
    ] as const;

    const vaults: Record<string, string> = {};
    for (const asset of assets) {
      await (await vaultFactory.createVault(asset.wrapped, deployer.address)).wait();
      const vaultAddress = await vaultFactory.vaultByAsset(asset.wrapped);
      const vault = await ethers.getContractAt("TezcatliConfidentialVault", vaultAddress);
      await (await vault.setCoordinator(await vaultCoordinator.getAddress())).wait();
      await (await vault.setFeeModel(await vaultFeeModel.getAddress())).wait();
      await (await vault.setFeeRecipient(deployer.address)).wait();
      await (await vaultCoordinator.setApprovedVault(vaultAddress, true)).wait();
      vaults[asset.key] = vaultAddress;

      await (await paymaster.setApprovedTarget(asset.underlying, true)).wait();
      await (await paymaster.setApprovedTarget(asset.wrapped, true)).wait();
      await (await paymaster.setApprovedTarget(vaultAddress, true)).wait();
    }

    await (await paymaster.setApprovedTarget(await migrator.getAddress(), true)).wait();
    await (await paymaster.setApprovedTarget(await dustSwap.getAddress(), true)).wait();

    await (await mockUSDC.mint(deployer.address, 2_000_000_000n)).wait();
    await (await mockUSDC.approve(await dustSwap.getAddress(), 1_000_000_000n)).wait();
    await (await dustSwap.fundSettlement(1_000_000_000n)).wait();
    await (await dustSwap.setRate(
      await mockDustToken.getAddress(),
      2_000_000n,
      1_000_000_000_000_000_000n,
      true,
    )).wait();

    const sharedManifest = loadSharedManifest("arbitrum-sepolia");
    const complianceGateAddress =
      typeof sharedManifest?.compliance?.gate === "string" ? sharedManifest.compliance.gate : null;

    if (complianceGateAddress) {
      await (await migrator.setComplianceGate(complianceGateAddress)).wait();
      await (await migrator.setComplianceEnabled(true)).wait();
      await (await paymaster.setComplianceGate(complianceGateAddress)).wait();
      await (await paymaster.setComplianceEnabled(true)).wait();

      for (const vaultAddress of Object.values(vaults)) {
        const vault = await ethers.getContractAt("TezcatliConfidentialVault", vaultAddress);
        await (await vault.setComplianceGate(complianceGateAddress)).wait();
        await (await vault.setComplianceEnabled(true)).wait();
      }
    }

    const deployments = {
      MockUSDC: await mockUSDC.getAddress(),
      MockUSDT: await mockUSDT.getAddress(),
      MockWBTC: await mockWBTC.getAddress(),
      MockWETH: await mockWETH.getAddress(),
      MockDustToken: await mockDustToken.getAddress(),
      TezcatliWrappedUSDC: await wrappedUSDC.getAddress(),
      TezcatliWrappedUSDT: await wrappedUSDT.getAddress(),
      TezcatliWrappedWBTC: await wrappedWBTC.getAddress(),
      TezcatliWrappedWETH: await wrappedWETH.getAddress(),
      TezcatliStealthRegistry: await registry.getAddress(),
      TezcatliStealthAnnouncer: await announcer.getAddress(),
      TezcatliMigrator: await migrator.getAddress(),
      TezcatliDustSwap: await dustSwap.getAddress(),
      TezcatliSmartAccountFactory: await smartAccountFactory.getAddress(),
      TezcatliEntryPointMock: await entryPointMock.getAddress(),
      Tezcatli4337AccountFactory: await smart4337Factory.getAddress(),
      TezcatliPaymaster: await paymaster.getAddress(),
      TezcatliConfidentialVaultFactory: await vaultFactory.getAddress(),
      TezcatliVaultCoordinator: await vaultCoordinator.getAddress(),
      TezcatliVaultFeeModel: await vaultFeeModel.getAddress(),
      TezcatliVaultUSDC: vaults.USDC,
      TezcatliVaultUSDT: vaults.USDT,
      TezcatliVaultWBTC: vaults.WBTC,
      TezcatliVaultWETH: vaults.WETH,
    };

    for (const [name, address] of Object.entries(deployments)) {
      console.log(`${name}: ${address}`);
      saveDeployment(network.name, name, address);
    }

    saveSharedManifest("arbitrum-sepolia", chainId, "migrator", {
      registry: await registry.getAddress(),
      announcer: await announcer.getAddress(),
      migrator: await migrator.getAddress(),
      dustSwap: await dustSwap.getAddress(),
      smartAccountFactory: await smartAccountFactory.getAddress(),
      entryPoint: await entryPointMock.getAddress(),
      account4337Factory: await smart4337Factory.getAddress(),
      paymaster: await paymaster.getAddress(),
      vaultFactory: await vaultFactory.getAddress(),
      vaultCoordinator: await vaultCoordinator.getAddress(),
      vaultFeeModel: await vaultFeeModel.getAddress(),
      complianceGate: complianceGateAddress,
      assets: {
        USDC: {
          symbol: "USDC",
          displaySymbol: "USDC",
          underlying: await mockUSDC.getAddress(),
          wrapped: await wrappedUSDC.getAddress(),
          vault: vaults.USDC,
          decimals: 6,
        },
        USDT: {
          symbol: "USDT",
          displaySymbol: "USDT",
          underlying: await mockUSDT.getAddress(),
          wrapped: await wrappedUSDT.getAddress(),
          vault: vaults.USDT,
          decimals: 6,
        },
        WBTC: {
          symbol: "WBTC",
          displaySymbol: "WBTC",
          underlying: await mockWBTC.getAddress(),
          wrapped: await wrappedWBTC.getAddress(),
          vault: vaults.WBTC,
          decimals: 8,
        },
        WETH: {
          symbol: "WETH",
          displaySymbol: "ETH",
          underlying: await mockWETH.getAddress(),
          wrapped: await wrappedWETH.getAddress(),
          vault: vaults.WETH,
          decimals: 18,
        },
      },
      defi: {
        depositVaults: vaults,
        buyGoldAdapter: null,
      },
    });
  },
);
