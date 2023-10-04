// scripts/create-box.js
const { ethers, upgrades, deployments } = require("hardhat");
const { BigNumber } = require("@ethersproject/bignumber");
const CryptoJS = require("crypto-js");
const crypto1 = require("crypto");

const crypto  = globalThis.crypto;


async function main() {
  const { deployer } = await getNamedAccounts();

  const DERC20_Token = "0xfe4F5145f6e09952a5ba9e956ED0C25e3Fa4c7F1";
  // const payCrestValidator = "0x69Afc555868Db29C6514Aea195210DeEeB72B8b2";
  const DERC20_Contract_Instance = await ethers.getContractAt(
    "MockUSDC",
    DERC20_Token
  );

  console.log("DERC20_Contract_Instance", DERC20_Contract_Instance.address);

  // check balance of deployer in DERC20_Contract_Instance
  const deployerBalance = await DERC20_Contract_Instance.balanceOf(deployer);
  console.log("deployerBalance", deployerBalance.toString());

  const Paycrest = await ethers.getContractFactory("Paycrest");
  const paycrest = await upgrades.deployProxy(Paycrest, [DERC20_Token]);
  console.log("paycrest deployed to:", await paycrest.address);
  console.log("✅ Deployed Paycrest.");

  const PaycrestValidator = await ethers.getContractFactory(
    "PaycrestValidator"
  );
  const paycrestValidator = await upgrades.deployProxy(PaycrestValidator, [
    paycrest.address,
  ]);

  // const paycrest = await ethers.getContractAt(
  //   "Paycrest",
  //   "0x8759Aa5d49CcBC659F7c62C6458EbEAD2E188cC9"
  // );

  console.log(
    "paycrestValidator deployed to:",
    paycrestValidator.address
  );
  console.log("✅ Deployed paycrestValidator.");

  const protocolFeePercent = BigNumber.from(10_000);
  const validatorFeePercent = BigNumber.from(5_000); // 5%
  const usdcMinimumStakeAmount = ethers.utils.parseUnits("1", 12); // not usdc has 6 decimals

  const currency = ethers.utils.formatBytes32String("NGN");

  const firstBank = {
    code: ethers.utils.formatBytes32String("191"),
    name: ethers.utils.formatBytes32String("First Bank"),
  };
  const opay = {
    code: ethers.utils.formatBytes32String("192"),
    name: ethers.utils.formatBytes32String("Opay"),
  };
  const palmpay = {
    code: ethers.utils.formatBytes32String("193"),
    name: ethers.utils.formatBytes32String("Palmpay Bank"),
  };
  const accessBank = {
    code: ethers.utils.formatBytes32String("194"),
    name: ethers.utils.formatBytes32String("Access Bank"),
  };
  const gtb = {
    code: ethers.utils.formatBytes32String("195"),
    name: ethers.utils.formatBytes32String("GTB"),
  };
  const stanbic = {
    code: ethers.utils.formatBytes32String("196"),
    name: ethers.utils.formatBytes32String("Stanbic IBTC Bank"),
  };

  await paycrest.setSupportedInstitutions(currency, [
    firstBank,
    opay,
    palmpay,
    accessBank,
    gtb,
    stanbic,
  ]);
  console.log(
    "======================================================= SETTING MANAGER FOR PROTOCOL FEES RECIPIENTS ======================================================="
  );

  await paycrest.updateProtocolFees(protocolFeePercent, validatorFeePercent);

  console.log(
    "======================================================= SETTING MANAGER FOR PROTOCOL ADDRESSES ======================================================="
  );
  const fee = ethers.utils.formatBytes32String("fee");
  const aggregatorInit = ethers.utils.formatBytes32String("aggregator");
  const stakeContract = ethers.utils.formatBytes32String("stake");

  await paycrest.updateFeeRecipient(fee, deployer);
  await paycrest.updateFeeRecipient(aggregatorInit, deployer);
  await paycrest.updateFeeRecipient(stakeContract, paycrestValidator.address);

  console.log(
    "======================================================= SETTING MANAGER FOR MINIMUM AND MAXIMUM ON PAYCREST VALIDATOR======================================================="
  );

  const whitelist = ethers.utils.formatBytes32String("whitelist");

  // await paycrestValidator.setMinimumAmountForTokens(
  //   DERC20_Contract_Instance.address,
  //   usdcMinimumStakeAmount
  // );

  // deployer approving paycrest contract to spend DERC20_Contract_Instance
  await DERC20_Contract_Instance.approve(paycrest.address, deployerBalance);

  // create order
  const amount = ethers.utils.parseUnits("1", 15);

  const data = [
    { bank_account: "09090990901" },
    { bank_name: "opay" },
    { accoun_name: "opay opay" },
  ];
  const password = "h9wt*pasj6796jw(w8=xaje8tpi6+k2)";

  // const cipher = CryptoJS.AES.encrypt(
  //   JSON.stringify(data),
  //   password
  // ).toString();
  const nonce = CryptoJS.lib.WordArray.random(12);
  // console.log("nonce", CryptoJS.mode);

  const ciphertext = CryptoJS.AES.encrypt(JSON.stringify(data), password, {
    nonce: nonce,
    // mode: CryptoJS.mode.GCM,
    padding: CryptoJS.pad.NoPadding,
  });

  const messageHash =
    "0xa3c6bfc43a5f2297001a72039b835698bae96310babf9ff34acc52ad530316f37b961cdf6b119f9422a424b9ad4ac949e282c276131fa7820535a01eb7703cd76350a190e1b6ee4ecc84f6a0f7d090b52e1f565319af139a557fab64b027427e1812576dbfd6c5a2e95166c9a0bc02e967a45be472259572e166758c7865cdc24255f200de23f84f1ac1cc8035b1";
  
  await paycrest.createOrder(
    DERC20_Contract_Instance.address,
    amount,
    ethers.utils.formatBytes32String("191"),
    970,
    deployer,
    0,
    deployer,
    messageHash.toString()
  );
}

main();
