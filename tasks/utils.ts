import fs from 'fs'
import path from 'path'
import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { HardhatEthersSigner } from '@nomicfoundation/hardhat-ethers/signers'
import { createCofheConfig, createCofheClient as createCofheClientBase } from '@cofhe/sdk/node'
import { getChainById } from '@cofhe/sdk/chains'

// Directory to store deployed contract addresses
const DEPLOYMENTS_DIR = path.join(__dirname, '../deployments')
const SHARED_DEPLOYMENTS_DIR = path.join(__dirname, '../../shared/deployments')

// Ensure the deployments directory exists
if (!fs.existsSync(DEPLOYMENTS_DIR)) {
	fs.mkdirSync(DEPLOYMENTS_DIR, { recursive: true })
}

if (!fs.existsSync(SHARED_DEPLOYMENTS_DIR)) {
	fs.mkdirSync(SHARED_DEPLOYMENTS_DIR, { recursive: true })
}

// Helper to get deployment file path for a network
const getDeploymentPath = (network: string) => path.join(DEPLOYMENTS_DIR, `${network}.json`)
const getSharedManifestPath = (network: string) =>
	path.join(SHARED_DEPLOYMENTS_DIR, `${network}.alpha.json`)

// Helper to save deployment info
export const saveDeployment = (network: string, contractName: string, address: string) => {
	const deploymentPath = getDeploymentPath(network)

	let deployments: Record<string, string> = {}
	if (fs.existsSync(deploymentPath)) {
		deployments = JSON.parse(fs.readFileSync(deploymentPath, 'utf8')) as Record<string, string>
	}

	deployments[contractName] = address

	fs.writeFileSync(deploymentPath, JSON.stringify(deployments, null, 2))
	console.log(`Deployment saved to ${deploymentPath}`)
}

// Helper to get deployment info
export const getDeployment = (network: string, contractName: string): string | null => {
	const deploymentPath = getDeploymentPath(network)

	if (!fs.existsSync(deploymentPath)) {
		return null
	}

	const deployments = JSON.parse(fs.readFileSync(deploymentPath, 'utf8')) as Record<string, string>
	return deployments[contractName] || null
}

export type SharedAlphaManifest = {
	network: string
	chainId: number
	updatedAt: string
	compliance?: Record<string, unknown>
	migrator?: Record<string, unknown>
}

export const loadSharedManifest = (network: string): SharedAlphaManifest | null => {
	const manifestPath = getSharedManifestPath(network)
	if (!fs.existsSync(manifestPath)) {
		return null
	}
	return JSON.parse(fs.readFileSync(manifestPath, 'utf8')) as SharedAlphaManifest
}

export const saveSharedManifest = (
	network: string,
	chainId: number,
	section: 'compliance' | 'migrator',
	payload: Record<string, unknown>
) => {
	const manifestPath = getSharedManifestPath(network)
	const current = loadSharedManifest(network) ?? {
		network,
		chainId,
		updatedAt: new Date().toISOString(),
	}

	const next: SharedAlphaManifest = {
		...current,
		network,
		chainId,
		updatedAt: new Date().toISOString(),
		[section]: {
			...(current[section] ?? {}),
			...payload,
		},
	}

	fs.writeFileSync(manifestPath, JSON.stringify(next, null, 2))
	console.log(`Shared alpha manifest saved to ${manifestPath}`)
}

// Helper to create a cofhe SDK client that works on both local hardhat and real networks
export const createCofheClient = async (hre: HardhatRuntimeEnvironment, signer: HardhatEthersSigner) => {
	const chainId = Number((await signer.provider.getNetwork()).chainId)
	const chain = getChainById(chainId)

	if (!chain) {
		throw new Error(`No CoFHE chain configuration found for chainId ${chainId}. Supported chains can be found in @cofhe/sdk/chains.`)
	}

	// On hardhat network, use the batteries-included client (handles mock ZK verifier)
	if (chain.environment === 'MOCK') {
		return hre.cofhe.createClientWithBatteries(signer)
	}

	// On real networks, use the SDK directly
	const config = createCofheConfig({
		environment: 'node',
		supportedChains: [chain],
	})

	const client = createCofheClientBase(config)

	const { publicClient, walletClient } = await hre.cofhe.hardhatSignerAdapter(signer)
	await client.connect(publicClient, walletClient)

	await client.permits.createSelf({
		issuer: signer.address,
	})

	return client
}
