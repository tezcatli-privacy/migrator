import { task } from "hardhat/config";
import { HardhatRuntimeEnvironment } from "hardhat/types";
import { loadSharedManifest, saveSharedManifest } from "./utils";

task("wire-alpha-compliance", "Wire alpha migrator contracts to the shared compliance gate").setAction(
  async (_, hre: HardhatRuntimeEnvironment) => {
    const { ethers } = hre;
    const manifest = loadSharedManifest("arbitrum-sepolia");

    if (!manifest?.migrator || !manifest?.compliance) {
      throw new Error("Shared alpha manifest is missing migrator or compliance data");
    }

    const complianceGateAddress =
      typeof manifest.compliance.gate === "string" ? manifest.compliance.gate : null;
    if (!complianceGateAddress) {
      throw new Error("Compliance gate address is missing in the shared alpha manifest");
    }

    const migratorAddress =
      typeof manifest.migrator.migrator === "string" ? manifest.migrator.migrator : null;
    const paymasterAddress =
      typeof manifest.migrator.paymaster === "string" ? manifest.migrator.paymaster : null;
    const assets =
      typeof manifest.migrator.assets === "object" && manifest.migrator.assets !== null
        ? (manifest.migrator.assets as Record<string, { vault?: string; wrapped?: string; underlying?: string }>)
        : {};

    if (!migratorAddress || !paymasterAddress) {
      throw new Error("Migrator or paymaster address is missing in the shared alpha manifest");
    }

    const migrator = await ethers.getContractAt("TezcatliMigrator", migratorAddress);
    const paymaster = await ethers.getContractAt("TezcatliPaymaster", paymasterAddress);

    await (await migrator.setComplianceGate(complianceGateAddress)).wait();
    await (await migrator.setComplianceEnabled(true)).wait();

    await (await paymaster.setComplianceGate(complianceGateAddress)).wait();
    await (await paymaster.setComplianceEnabled(true)).wait();

    for (const asset of Object.values(assets)) {
      if (!asset.vault) continue;
      const vault = await ethers.getContractAt("TezcatliConfidentialVault", asset.vault);
      await (await vault.setComplianceGate(complianceGateAddress)).wait();
      await (await vault.setComplianceEnabled(true)).wait();
    }

    saveSharedManifest("arbitrum-sepolia", manifest.chainId, "migrator", {
      complianceGate: complianceGateAddress,
      complianceWiredAt: new Date().toISOString(),
    });

    console.log(`Alpha compliance wiring completed with gate ${complianceGateAddress}`);
  },
);
