import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadSharedManifest, saveDeployment, saveSharedManifest } from "./utils";

const CANONICAL_PERMIT2_ADDRESS = "0x000000000022D473030F116dDEE9F6B43aC78BA3";

task("deploy-alpha-batch-migrator", "Deploy the alpha Permit2 batch migrator and wire supported assets").setAction(
  async (_, hre: HardhatRuntimeEnvironment) => {
    const { ethers, network } = hre;
    const [deployer] = await ethers.getSigners();
    const chainId = Number((await ethers.provider.getNetwork()).chainId);
    const manifest = loadSharedManifest("arbitrum-sepolia");

    const account4337Factory = manifest?.migrator?.account4337Factory;
    const assets = manifest?.migrator?.assets;
    const complianceGate = manifest?.migrator?.complianceGate;

    if (typeof account4337Factory !== "string") {
      throw new Error("Shared alpha manifest is missing migrator.account4337Factory");
    }

    if (!assets || typeof assets !== "object") {
      throw new Error("Shared alpha manifest is missing migrator.assets");
    }

    const underlyings: string[] = [];
    const wrappedTokens: string[] = [];

    for (const asset of Object.values(assets as Record<string, { underlying?: unknown; wrapped?: unknown }>)) {
      if (typeof asset.underlying !== "string" || typeof asset.wrapped !== "string") {
        continue;
      }

      underlyings.push(asset.underlying);
      wrappedTokens.push(asset.wrapped);
    }

    if (underlyings.length === 0) {
      throw new Error("No asset mappings were found in the shared alpha manifest");
    }

    console.log(`Deploying Permit2 batch migrator to ${network.name} (${chainId}) with ${deployer.address}`);
    console.log(`Using canonical Permit2 at ${CANONICAL_PERMIT2_ADDRESS}`);
    console.log(`Using 4337 account factory at ${account4337Factory}`);

    const BatchMigrator = await ethers.getContractFactory("TezcatliBatchMigratorPermit2");
    const batchMigrator = await BatchMigrator.deploy(CANONICAL_PERMIT2_ADDRESS, account4337Factory);
    await batchMigrator.waitForDeployment();

    await (await batchMigrator.setWrappedTokens(underlyings, wrappedTokens)).wait();

    if (typeof complianceGate === "string" && complianceGate !== ethers.ZeroAddress) {
      await (await batchMigrator.setComplianceGate(complianceGate)).wait();
      await (await batchMigrator.setComplianceEnabled(true)).wait();
    }

    const batchMigratorAddress = await batchMigrator.getAddress();
    saveDeployment(network.name, "TezcatliBatchMigratorPermit2", batchMigratorAddress);

    saveSharedManifest("arbitrum-sepolia", chainId, "migrator", {
      batchMigrator: batchMigratorAddress,
      permit2: CANONICAL_PERMIT2_ADDRESS,
    });

    console.log(`TezcatliBatchMigratorPermit2: ${batchMigratorAddress}`);
  },
);
