import Safe from '@safe-global/protocol-kit'

import { sepolia } from 'viem/chains'
import dotenv from 'dotenv'
import { createPublicClient, http } from "viem";

const SIGNER_PRIVATE_KEY = process.env.PRIVATE_KEY;

const existingSafeAddress = ""

const newProtocolKit = await Safe.init({
  provider: sepolia.rpcUrls.default.http[0],
  signer: SIGNER_PRIVATE_KEY,
  safeAddress: existingSafeAddress,
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
