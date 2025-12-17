import Safe, {
  PredictedSafeProps,
  SafeAccountConfig,
  SafeDeploymentConfig
} from '@safe-global/protocol-kit'
import { sepolia } from 'viem/chains'
import dotenv from 'dotenv'
import { createPublicClient, http } from "viem";

// configure dotenv for reading environment variables
dotenv.config()


const SIGNER_PRIVATE_KEY = process.env.PRIVATE_KEY;

// 
const signer1: string = process.env.SIGNER1!;

// 
const signer2: string = process.env.SIGNER2!;

const signer3: string = process.env.SIGNER3!;

const safeAccountConfig: SafeAccountConfig = {
  owners: [signer1, signer2, signer3],
  threshold: 2
  // More optional properties
}

const predictedSafe: PredictedSafeProps = {
  safeAccountConfig
  // More optional properties
}

const protocolKit = await Safe.init({
  provider: sepolia.rpcUrls.default.http[0],
  signer: SIGNER_PRIVATE_KEY,
  predictedSafe,
})


const predictedSafeAddress = await protocolKit.getAddress()

console.log("Predicted safe address: ", predictedSafeAddress)

// Deployment

const deploymentTransaction = await protocolKit.createSafeDeploymentTransaction()

const client = (await protocolKit.getSafeProvider().getExternalSigner())!
const rpcUrl = sepolia.rpcUrls.default.http[0];

const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(rpcUrl),
});

const to = deploymentTransaction.to! as `0x${string}`;

const transactionHash = await client.sendTransaction({
  to: to,
  value: BigInt(deploymentTransaction.value),
  data: deploymentTransaction.data as `0x${string}`,
  chain: sepolia
})

const transactionReceipt = await publicClient.waitForTransactionReceipt({
  hash: transactionHash,
});

const newProtocolKit = await protocolKit.connect({
  safeAddress: predictedSafeAddress   
})

// checks 
const isSafeDeployed = await newProtocolKit.isSafeDeployed() // True
console.log("Is safe deployed: ", isSafeDeployed)
const safeAddress = await newProtocolKit.getAddress()
console.log("Safe address: ", safeAddress)
const safeOwners = await newProtocolKit.getOwners()
console.log("Safe owners: ", safeOwners)
const safeThreshold = await newProtocolKit.getThreshold()
console.log("Safe threshold: ", safeThreshold)
