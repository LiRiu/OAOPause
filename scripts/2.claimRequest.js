/// import libraries
const hre = require("hardhat");
require("dotenv").config();

const OAO_ADDRESS = "0x0A0f4321214BB6C7811dD8a71cF587bdaF03f0A0";
const OPERATOR = "0x8626f6940E2eb28930eFb4CeF49B2d1F2C9C1199";

const oao_pause_address = "0xf53d008048D264c871d8a7e60190Ee1c4EF79090";
const secret_protocol_bounty_deployer_address = "0xDd402b9418f907F97AaB57c2ac90DFb1D12336eB"; 

async function claimRequest() {
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

  // deploy Exploit
  const exploiter = await hre.ethers.deployContract("SecretExploiter", [oao_pause_address]);
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
      value: 1000000000000000000n
    }
    );
  console.log("claimRequest is in txhash: " + claimRequest.hash);
}

claimRequest();
