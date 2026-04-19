import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadSharedManifest, saveDeployment, saveSharedManifest } from "./utils";

const ARB_SEPOLIA_REAL_USDC = "0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d";
const ARB_SEPOLIA_AAVE_POOL = "0xBfC91D59fdAA134A4ED45f7B584cAf96D7792Eff";
const ARB_SEPOLIA_AAVE_AUSDC = "0x460b97BD498E1157530AEb3086301d5225b91216";

task(
  "redeploy-alpha-usdc-real-lane",
  "Redeploy the alpha USDC lane using real Arbitrum Sepolia USDC, Aave real, and Morpho mock",
).setAction(async (_, hre: HardhatRuntimeEnvironment) => {
  const { ethers, network } = hre;
  const [deployer] = await ethers.getSigners();
  const chainId = Number((await ethers.provider.getNetwork()).chainId);

  const manifest = loadSharedManifest("arbitrum-sepolia");
  if (!manifest?.migrator) {
    throw new Error("Shared alpha manifest is missing migrator data");
  }

  const migratorSection = manifest.migrator as Record<string, unknown>;
  const vaultFactoryAddress = String(migratorSection.vaultFactory ?? "");
  const vaultCoordinatorAddress = String(migratorSection.vaultCoordinator ?? "");
  const vaultFeeModelAddress = String(migratorSection.vaultFeeModel ?? "");
  const migratorAddress = String(migratorSection.migrator ?? "");
  const paymasterAddress = String(migratorSection.paymaster ?? "");
  const complianceGateAddress =
    typeof manifest.compliance?.gate === "string" ? manifest.compliance.gate : undefined;

  if (!vaultFactoryAddress || !vaultCoordinatorAddress || !vaultFeeModelAddress || !migratorAddress || !paymasterAddress) {
    throw new Error("Shared alpha manifest is missing required migrator contract addresses");
  }

  const realUsdcAddress = process.env.ALPHA_REAL_USDC_ADDRESS?.trim() || ARB_SEPOLIA_REAL_USDC;
  const aavePoolAddress = process.env.ALPHA_AAVE_POOL_ADDRESS?.trim() || ARB_SEPOLIA_AAVE_POOL;
  const aaveATokenAddress = process.env.ALPHA_AAVE_ATOKEN_USDC_ADDRESS?.trim() || ARB_SEPOLIA_AAVE_AUSDC;
  const switchPaymasterFeeToken = (process.env.ALPHA_PAYMASTER_FEE_TOKEN_TO_REAL_USDC ?? "false").toLowerCase() === "true";

  const WrappedToken = await ethers.getContractFactory("TezcatliWrappedToken");
  const wrappedUsdc = await WrappedToken.deploy(
    "Tezcatli Confidential USD Coin",
    "tzcUSDC",
    realUsdcAddress,
    6,
  );
  await wrappedUsdc.waitForDeployment();

  const vaultFactory = await ethers.getContractAt("TezcatliConfidentialVaultFactory", vaultFactoryAddress);
  await (await vaultFactory.createVault(await wrappedUsdc.getAddress(), deployer.address)).wait();
  const usdcVaultAddress = await vaultFactory.vaultByAsset(await wrappedUsdc.getAddress());
  const usdcVault = await ethers.getContractAt("TezcatliConfidentialVault", usdcVaultAddress);

  await (await usdcVault.setCoordinator(vaultCoordinatorAddress)).wait();
  await (await usdcVault.setFeeModel(vaultFeeModelAddress)).wait();
  await (await usdcVault.setFeeRecipient(deployer.address)).wait();

  const coordinator = await ethers.getContractAt("TezcatliVaultCoordinator", vaultCoordinatorAddress);
  await (await coordinator.setApprovedVault(usdcVaultAddress, true)).wait();

  if (complianceGateAddress) {
    await (await usdcVault.setComplianceGate(complianceGateAddress)).wait();
    await (await usdcVault.setComplianceEnabled(true)).wait();
  }

  const AaveAdapter = await ethers.getContractFactory("TezcatliStrategyAdapterAaveV3");
  const aaveAdapter = await AaveAdapter.deploy(
    usdcVaultAddress,
    realUsdcAddress,
    aavePoolAddress,
    aaveATokenAddress,
    deployer.address,
  );
  await aaveAdapter.waitForDeployment();

  const MockYieldVault = await ethers.getContractFactory("MockYieldVault");
  const morphoMockVault = await MockYieldVault.deploy(realUsdcAddress);
  await morphoMockVault.waitForDeployment();

  const MorphoAdapter = await ethers.getContractFactory("TezcatliStrategyAdapterMorphoVault");
  const morphoAdapter = await MorphoAdapter.deploy(
    usdcVaultAddress,
    realUsdcAddress,
    await morphoMockVault.getAddress(),
    deployer.address,
  );
  await morphoAdapter.waitForDeployment();

  await (await usdcVault.setStrategyAdapterApproval(await aaveAdapter.getAddress(), true)).wait();
  await (await usdcVault.setStrategyAdapterApproval(await morphoAdapter.getAddress(), true)).wait();
  await (await usdcVault.setStrategyAdapter(await aaveAdapter.getAddress())).wait();

  await (await coordinator.setStrategyConfig(
    usdcVaultAddress,
    await aaveAdapter.getAddress(),
    0,
    7_000,
    8_500,
    true,
  )).wait();
  await (await coordinator.setStrategyConfig(
    usdcVaultAddress,
    await morphoAdapter.getAddress(),
    1,
    3_000,
    5_000,
    true,
  )).wait();

  const paymaster = await ethers.getContractAt("TezcatliPaymaster", paymasterAddress);
  await (await paymaster.setApprovedTarget(realUsdcAddress, true)).wait();
  await (await paymaster.setApprovedTarget(await wrappedUsdc.getAddress(), true)).wait();
  await (await paymaster.setApprovedTarget(usdcVaultAddress, true)).wait();
  if (switchPaymasterFeeToken) {
    await (await paymaster.setFeeToken(realUsdcAddress)).wait();
  }

  const migrator = await ethers.getContractAt("TezcatliMigrator", migratorAddress);
  if (complianceGateAddress) {
    await (await migrator.setComplianceGate(complianceGateAddress)).wait();
    await (await migrator.setComplianceEnabled(true)).wait();
  }

  saveDeployment(network.name, "TezcatliWrappedUSDCReal", await wrappedUsdc.getAddress());
  saveDeployment(network.name, "TezcatliVaultUSDCReal", usdcVaultAddress);
  saveDeployment(network.name, "TezcatliStrategyAdapterAaveV3USDCReal", await aaveAdapter.getAddress());
  saveDeployment(network.name, "MockMorphoVaultUSDCReal", await morphoMockVault.getAddress());
  saveDeployment(network.name, "TezcatliStrategyAdapterMorphoUSDCMock", await morphoAdapter.getAddress());

  const currentAssets =
    typeof migratorSection.assets === "object" && migratorSection.assets !== null
      ? (migratorSection.assets as Record<string, unknown>)
      : {};
  const currentDefi =
    typeof migratorSection.defi === "object" && migratorSection.defi !== null
      ? (migratorSection.defi as Record<string, unknown>)
      : {};
  const currentDepositVaults =
    typeof currentDefi.depositVaults === "object" && currentDefi.depositVaults !== null
      ? (currentDefi.depositVaults as Record<string, unknown>)
      : {};
  const currentStrategies =
    typeof currentDefi.strategies === "object" && currentDefi.strategies !== null
      ? (currentDefi.strategies as Record<string, unknown>)
      : {};

  saveSharedManifest("arbitrum-sepolia", chainId, "migrator", {
    assets: {
      ...currentAssets,
      USDC: {
        symbol: "USDC",
        displaySymbol: "USDC",
        underlying: realUsdcAddress,
        wrapped: await wrappedUsdc.getAddress(),
        vault: usdcVaultAddress,
        decimals: 6,
        liveUnderlying: true,
      },
    },
    defi: {
      ...currentDefi,
      depositVaults: {
        ...currentDepositVaults,
        USDC: usdcVaultAddress,
      },
      strategies: {
        ...currentStrategies,
        USDC: {
          active: "aave",
          aave: {
            pool: aavePoolAddress,
            aToken: aaveATokenAddress,
            adapter: await aaveAdapter.getAddress(),
          },
          morphoMock: {
            vault: await morphoMockVault.getAddress(),
            adapter: await morphoAdapter.getAddress(),
          },
        },
      },
    },
  });

  console.log(`Redeployed alpha USDC lane with real USDC ${realUsdcAddress}`);
  console.log(`Wrapped USDC: ${await wrappedUsdc.getAddress()}`);
  console.log(`USDC vault: ${usdcVaultAddress}`);
  console.log(`Aave adapter: ${await aaveAdapter.getAddress()}`);
  console.log(`Morpho mock vault: ${await morphoMockVault.getAddress()}`);
  console.log(`Morpho mock adapter: ${await morphoAdapter.getAddress()}`);
});
