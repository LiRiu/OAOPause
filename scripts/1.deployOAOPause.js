/// import libraries
const hre = require("hardhat");
require("dotenv").config();

const OAO_ADDRESS = "0x0A0f4321214BB6C7811dD8a71cF587bdaF03f0A0";
const OPERATOR = "0x8626f6940E2eb28930eFb4CeF49B2d1F2C9C1199";

async function deploy() {
  // deploy oao_pause
  const oao_pause = await hre.ethers.deployContract("OAOPause", [OAO_ADDRESS]);
  await oao_pause.waitForDeployment();
  console.log("oao_pause is deploy at: " + oao_pause.target);

  //deploy TestErc20
  const token = await hre.ethers.deployContract("TestERC20", []);
  await token.waitForDeployment();
  console.log("TestErc20 is deploy at: " + token.target);

  const secret_protocol_bounty_deployer = await hre.ethers.deployContract("SecretProtocolBountyDeployer", [
    oao_pause.target,
    "test_month",
    token.target,
    1000,
    OPERATOR,
  ]);
  await secret_protocol_bounty_deployer.waitForDeployment();
  console.log("secret_protocol_bounty_deployer is deploy at: " + secret_protocol_bounty_deployer.target);
}

deploy();
