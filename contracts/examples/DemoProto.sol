// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { OAOPause, IVerifier, IPauser, IPayer, IExploiter, ETH_TOKEN } from '../OAOPause.sol';
import { TestERC20, ERC20 } from "./TestToken.sol";
import "hardhat/console.sol";

contract SecretProtocol {
    address public immutable pauser;
    uint256 public month;
    bool public paused;

    constructor(address pauser_) {
        pauser = pauser_;
    }

    function solve(uint256 _month) external {
        // require(!paused, 'paused');
        month = _month;
    }

    function pause() external {
        require(msg.sender == pauser, 'not pauser');
        paused = true;
    }
}

contract SecretProtocolVerifier is IVerifier {
    SecretProtocol immutable public proto;

    constructor(SecretProtocol proto_) { proto = proto_; }

    function status()
        external view returns (bytes memory)
    {
        return abi.encodePacked(proto.month);
    }
}

contract SecretExploiter is IExploiter {
  SecretProtocol public proto;
  constructor(SecretProtocol proto_) { proto = proto_; }
    function exploit(bytes memory data) external {
    //   uint256 _new_month = uint256(bytes32(data));
      proto.solve(13);
    }
}

contract SecretProtocolPauser is IPauser {
    OAOPause immutable oao_pause;
    SecretProtocol public immutable proto;
    uint256 immutable public bountyId;

    constructor(
        SecretProtocol proto_,
        OAOPause oao_pause_,
        uint256 bountyId_
    ) {
        oao_pause = oao_pause_;
        proto = proto_;
        bountyId = bountyId_;
    }

    function pause(uint256 bountyId_) external {
        require(msg.sender == address(oao_pause), 'not oao_pause');
        require(bountyId_ == bountyId, 'wrong bounty');
        proto.pause();
    }
}

contract SecretProtocolPayer is IPayer {
    OAOPause immutable oao_pause;
    uint256 immutable bountyId;

    constructor(OAOPause oao_pause_, uint256 bountyId_) {
        oao_pause = oao_pause_;
        bountyId = bountyId_;
    }

    function payExploiter(
        uint256 bountyId_,
        ERC20 token,
        address payable to,
        uint256 amount
    )
        external
    {
        require(msg.sender == address(oao_pause), 'not oao_pause');
        require(bountyId_ == bountyId, 'wrong bounty');
        token.transfer(to, amount);
    }
}

contract SecretProtocolBountyDeployer {
    event Deployed(
        uint256 bountyId,
        SecretProtocol proto,
        SecretProtocolPauser pauser,
        SecretProtocolVerifier verifier,
        SecretProtocolPayer payer
    );

    SecretProtocol immutable public proto;
    SecretProtocolPauser immutable public pauser;
    SecretProtocolVerifier immutable public verifier;
    SecretProtocolPayer immutable public payer;
    uint256 immutable public bountyId;

    constructor(
        OAOPause oao_pause,
        string memory name,
        TestERC20 token,
        uint256 amount,
        address operator
    ) {
        bountyId = oao_pause.bountyCount() + 1;
        address pauserAddress = _getDeployedAddress(address(this), 2);
        proto = new SecretProtocol(pauserAddress);
        pauser = new SecretProtocolPauser(proto, oao_pause, bountyId);
        assert(address(pauser) == pauserAddress);
        verifier = new SecretProtocolVerifier(proto);
        payer = new SecretProtocolPayer(oao_pause, bountyId);
        token.mint(address(payer), amount);
        uint256 bountyId_ = oao_pause.add({
            name: name,
            payoutToken: token,
            payoutAmount: amount,
            verifier: verifier,
            pauser: pauser,
            payer: payer, 
            operator: operator
        });
        assert(bountyId_ == bountyId);
        emit Deployed(bountyId, proto, pauser, verifier, payer);
    }

    function _getDeployedAddress(address deployer, uint32 deployNonce)
        private
        pure
        returns (address deployed)
    {
        assembly {
            mstore(0x02, shl(96, deployer))
            let rlpNonceLength
            switch gt(deployNonce, 0xFFFFFF)
                case 1 { // 4 byte nonce
                    rlpNonceLength := 5
                    mstore8(0x00, 0xD8)
                    mstore8(0x16, 0x84)
                    mstore(0x17, shl(224, deployNonce))
                }
                default {
                    switch gt(deployNonce, 0xFFFF)
                        case 1 {
                            // 3 byte nonce
                            rlpNonceLength := 4
                            mstore8(0x16, 0x83)
                            mstore(0x17, shl(232, deployNonce))
                        }
                        default {
                            switch gt(deployNonce, 0xFF)
                                case 1 {
                                    // 2 byte nonce
                                    rlpNonceLength := 3
                                    mstore8(0x16, 0x82)
                                    mstore(0x17, shl(240, deployNonce))
                                }
                                default {
                                    switch gt(deployNonce, 0x7F)
                                        case 1 {
                                            // 1 byte nonce >= 0x80
                                            rlpNonceLength := 2
                                            mstore8(0x16, 0x81)
                                            mstore8(0x17, deployNonce)
                                        }
                                        default {
                                            rlpNonceLength := 1
                                            switch iszero(deployNonce)
                                                case 1 {
                                                    // zero nonce
                                                    mstore8(0x16, 0x80)
                                                }
                                                default {
                                                    // 1 byte nonce < 0x80
                                                    mstore8(0x16, deployNonce)
                                                }
                                        }
                                }
                        }
                }
            mstore8(0x00, add(0xD5, rlpNonceLength))
            mstore8(0x01, 0x94)
            deployed := and(
                keccak256(0x00, add(0x16, rlpNonceLength)),
                0xffffffffffffffffffffffffffffffffffffffff
            )
        }
    }
}