/// import libraries
const hre = require("hardhat");
require("dotenv").config();

const OAO_ADDRESS = "0x0A0f4321214BB6C7811dD8a71cF587bdaF03f0A0";
const OPERATOR = "0x8626f6940E2eb28930eFb4CeF49B2d1F2C9C1199";
let GAS = 0;

async function deploy() {
  // deploy oao_pause
  const oao_pause = await hre.ethers.deployContract("OAOPause", [OAO_ADDRESS]);
  await oao_pause.waitForDeployment();
  console.log("oao_pause is deploy at: " + oao_pause.target);

  // get oao
  const oao = await hre.ethers.getContractAt("IAIOracle", OAO_ADDRESS);
  GAS = await oao.estimateFee(11, 50000000);
  console.log("estimateFee:" + GAS);

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

  await claimRequest(oao_pause.target, secret_protocol_bounty_deployer.target);
}

async function claimRequest(oao_pause_address, secret_protocol_bounty_deployer_address) {
  // get oao_pause
  const oao_pause = await ethers.getContractAt(
    "OAOPause",
    oao_pause_address
  );
  console.log("oao_pause is: " + oao_pause.target);

  // get secret_protocol_bounty_deployer
  const secret_protocol_bounty_deployer = await ethers.getContractAt(
    "SecretProtocolBountyDeployer",
    secret_protocol_bounty_deployer_address
  )

  // get proto address
  const proto_address = await secret_protocol_bounty_deployer.proto();

  // deploy Exploit
  const exploiter = await hre.ethers.deployContract("SecretExploiter", [proto_address]);
  await exploiter.waitForDeployment();
  console.log("exploiter is deploy at: " + exploiter.target);

  // get bountyId
  const bountyId = await secret_protocol_bounty_deployer.bountyId();

  // claim request
  const claimRequest = await oao_pause.claim(
    bountyId,
    OPERATOR,
    exploiter.target,
    "0x",
    {
      value: GAS
    }
    );
  console.log("claimRequest is in txhash: " + claimRequest.hash);
  console.log("[+] Request AI Adjudgement SUCCESS!!");
}

deploy();
