import { deployBot } from "./contracts.mjs";
import { Bot } from "./models/Bot.mjs";

// The following Hardhat-derived beneficiary address should be replaced with
// the mainnet beneficiary address.
import { ethers } from "hardhat";
const beneficiary = await ethers.getSigner(0);
const beneficiaryAddress = beneficiary.address;
const contracts = await deployBot(beneficiaryAddress);

const bot = new Bot(contracts);
await bot.start();
