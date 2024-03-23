// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from './lib/ERC20.sol';
import { LibBytes } from './lib/LibBytes.sol';
import { LibSandbox, SandboxFailedError, SandboxSucceededError } from './lib/LibSandbox.sol';
import { AIOracleCallbackReceiver } from './AIOracleCallbackReceiver.sol';
import { IAIOracle } from './interfaces/IAIOracle.sol';
import "hardhat/console.sol";

/// @dev Interface for a protocol's verifier contract.
interface IVerifier {
    /// @dev just return the status of protocol
    function status() external returns (bytes memory verifierStateData);
}

/// @dev Interface for a protocol's pauser contract.
interface IPauser {
    /// @dev Pause a protocol.
    ///      The implementer MUST check that the caller of this function is the HoneyPause contract
    ///      and that the `bountyId` is one they recognize as their own.
    /// @param bountyId ID of the bounty that triggered it.
    function pause(uint256 bountyId) external;
}

/// @dev Interface for an exploit contract provided by a whitehat making a claim.
interface IExploiter {
    /// @dev Perform the exploit.
    /// @param exploiterData Arbitrary data that the caller of `claim()` can pass in.
    function exploit(bytes memory exploiterData) external;
}

/// @dev Interface for a protocol's payer contract.
interface IPayer {
    /// @dev Pay the whitehat the bounty after proving an exploit was possible.
    ///      The implementer MUST check that the caller of this function is the HoneyPause contract
    ///      and that the `bountyId` is one they recognize as their own.
    ///      This payment mechanism should be distinct from user operations
    ///      interactions because this function will be called AFTER the pauser has been invoked.
    /// @param bountyId ID of the bounty that triggered it.
    /// @param token The bounty token.
    /// @param to The receving account for payment.
    /// @param amount The bounty amount.
    function payExploiter(uint256 bountyId, ERC20 token, address payable to, uint256 amount) external;
}

/// @dev ERC20 type alias for ETH.
ERC20 constant ETH_TOKEN = ERC20(address(0));

error OnlyBountyOperatorError();
error InvalidClaimError();
error InvalidExploitError();
error InvalidBountyConfigError();
error InsufficientPayoutError();

event OperatorChanged(uint256 indexed bountyId, address oldOperator, address newOperator);
event Created(uint256 bountyId, string name, ERC20 payoutToken, uint256 payoutAmount, IVerifier verifier);
event Updated(uint256 indexed bountyId, ERC20 payoutToken, uint256 payoutAmount, IVerifier verifier);
event Cancelled(uint256 bountyId);
event Claimed(uint256 indexed bountyId, ERC20 payoutToken);

/// @notice An on-chain mechanism for atomically verifying an exploit,
///         pausing a protocol, and paying out a reward. Works only with
///         private mempools.
contract OAOPause is AIOracleCallbackReceiver {
    using LibBytes for bytes;
    using LibSandbox for address;

    /// @dev A bounty record.
    struct Bounty {
        address operator;
        ERC20 payoutToken;
        uint256 payoutAmount;
        IVerifier verifier;
        IPauser pauser;
        IPayer payer; 
    }

    struct AIOracleRequest {
        address sender;
        bytes input;
        bytes output;
        uint256 bountyId;
        address payReceiver;
    }

    mapping(uint256 => AIOracleRequest) public requests;
    mapping(uint256 => uint256) public requestIdOfBountyId;

    /// @notice Number of bounties that have been registered, in total.
    ///         The next bounty ID is simply this value + 1.
    uint256 public bountyCount;
    /// @notice Bounty ID -> bounty information.
    mapping (uint256 bountyId => Bounty bounty) public getBounty;

    bytes public beforeStatus;
    bytes public afterStatus;
    
    modifier onlyBountyOperator(uint256 bountyId) {
        if (msg.sender != getBounty[bountyId].operator) {
            revert OnlyBountyOperatorError();
        }
        _; 
    }

    constructor(IAIOracle AIOracle) AIOracleCallbackReceiver(AIOracle) {}

    /// @notice Check whether a bounty has been claimed or is valid.
    /// @param bountyId The bounty.
    function isBountyClaimed(uint256 bountyId) external view returns (bool claimed) {
        return getBounty[bountyId].operator == address(0);
    }

    /// @notice Add a new bounty for a protocol.
    /// @param name Name of the protocol to emit as part of the listing.
    /// @param payoutToken The token the bounty will be paid out in. 0 for ETH.
    /// @param payoutAmount The bounty amount (in wei).
    /// @param verifier The protocol's verifier contract, which asserts that critical invariants have been broken.
    /// @param pauser A privileged contract that can pause the protocol when called.
    /// @param payer A contract that can pay the bounty when called.
    /// @param operator Who can cancel this bounty.
    /// @return bountyId The ID of the created bounty.
    function add(
        string memory name,
        ERC20 payoutToken,
        uint256 payoutAmount,
        IVerifier verifier,
        IPauser pauser,
        IPayer payer,
        address operator
    )
        external returns (uint256 bountyId)
    {
        bountyId = ++bountyCount;
        _validateBountyConfig({ operator: operator, pauser: pauser, verifier: verifier, payer: payer });
        getBounty[bountyId] = Bounty({
            operator: operator,
            payoutToken: payoutToken,
            payoutAmount: payoutAmount,
            verifier: verifier,
            pauser: pauser,
            payer: payer
        });
        emit Created(bountyId, name, payoutToken, payoutAmount, verifier);
    }

    /// @notice Update an existing, unclaimed bounty.
    /// @dev    Must be called by the current operator of a bounty.
    /// @param bountyId ID of an existing bounty.
    /// @param payoutToken The token the bounty will be paid out in. 0 for ETH.
    /// @param payoutAmount The bounty amount (in wei).
    /// @param verifier The protocol's verifier contract, which asserts that critical invariants have been broken.
    /// @param pauser A privileged contract that can pause the protocol when called.
    /// @param payer A contract that can pay the bounty when called.
    /// @param operator Who can cancel this bounty.
    function update(
        uint256 bountyId,
        ERC20 payoutToken,
        uint256 payoutAmount,
        IVerifier verifier,
        IPauser pauser,
        IPayer payer,
        address operator 
    )
        external onlyBountyOperator(bountyId) 
    {
        _validateBountyConfig({ operator: operator, pauser: pauser, verifier: verifier, payer: payer });
        getBounty[bountyId]  = Bounty({
            operator: operator,
            payoutToken: payoutToken,
            payoutAmount: payoutAmount,
            verifier: verifier,
            pauser: pauser,
            payer: payer
        });
        emit Updated(bountyId, payoutToken, payoutAmount, verifier);
    }

    /// @notice Cancel a bounty that has not been claimed.
    /// @dev    Must be called by the current operator of a bounty.
    /// @param bountyId The bounty.
    function cancel(uint256 bountyId)
        external onlyBountyOperator(bountyId)
    {
        Bounty storage bounty = getBounty[bountyId];
        bounty.operator = address(0);
        emit Cancelled(bountyId);
    }

    /// @notice The mechanism for whitehats to claim a bounty by proving an exploit.
    ///         The exploit will be carried out but then reverted. If considered valid by
    ///         the bounty protocol's verifier then the protocol will be paused and a payment
    ///         for the bounty will be made to the whtiehat.
    ///         WARNING: The transaction that calls this MUST be submitted to a private
    ///         mempool to prevent bots from frontrunning the transaction and
    ///         actually carrying out the exploit. Even a reverting transaction may
    ///         leak details of the exploit to be dangerous. Only sophisticated whitehats,
    ///         or someone under the guidance of one should attempt to perform this action.
    /// @param bountyId The bounty to claim.
    /// @param payReceiver Where the bounty should go to.
    /// @param exploiter The contract that will carry out the exploit.
    /// @param exploiterData Arbitrary data supplied by the caller to pass to the exploiter contract.
    function claim(
        uint256 bountyId,
        address payable payReceiver,
        IExploiter exploiter,
        bytes memory exploiterData
    )
        external payable returns (uint256 payAmount)
    {
        Bounty memory bounty;
       (bounty) = _claim({
           bountyId: bountyId,
           payReceiver: payReceiver,
           exploiter: exploiter,
           exploiterData: exploiterData,
           skipExploit: false
       }); 
        emit Claimed(bountyId, bounty.payoutToken);
    }

    /// @notice Carries out an exploit, verifies it, then reverts the call frame.
    /// @dev Not intended to be called directly, but through `claim()`. Unprotected because
    ///      it always reverts anyway.
    function sandboxExploit(
        IExploiter exploiter,
        IVerifier verifier,
        bytes memory exploiterData,
        address payReceiver,
        uint256 bountyId
    )
        external
    {
        beforeStatus = IVerifier(verifier).status();
        console.logAddress(address(exploiter));
        address(exploiter).safeCall(abi.encodeCall(
            exploiter.exploit,
            (exploiterData)
        ));
        console.log("try exp done");
        afterStatus = IVerifier(verifier).status();
        revert SandboxSucceededError(afterStatus);
    }

    /// @notice Check whether a bounty can actually pay out its reward.
    /// @dev    Not read-only because state needs to be temporarily modified to make this
    ///         determination. All state is reverted before returning so this can
    ///         be safely called on-chain but most likely it will be consumed off-chain
    ///         via eth_call.
    /// @param bountyId ID of a valid, active bounty.
    /// @param payReceiver Recepient of bounty.
    /// @return bountyCanPay Whether the payer sent at least the bounty amount to the receiver.
    /// @return payAmount Actual amount sent to receiver (may be more than bounty amount).
    function verifyBountyCanPay(uint256 bountyId, address payable payReceiver)
        external returns (bool bountyCanPay, uint256 payAmount)
    {
        try this.sandboxTryPayBounty(bountyId, payReceiver) {
            // Should always fail. 
            assert(false);
        } catch (bytes memory errData) {
            if (!LibSandbox.handleSandboxCallRevert(errData, true)) {
                return (false, 0);
            }
            // The data inside the SandboxSucceededError is the pay amount.
            payAmount = abi.decode(abi.decode(errData.skip(4), (bytes)), (uint256));
        }
        return (true, payAmount);
    }

    /// @notice Mimics the logic for a successful claim() to verify that a bounty can
    ///         pay its reward.
    /// @dev Not intended to be called directly, but through `verifyBountyCanPay()`.
    ///      Unprotected because it always reverts anyway.
    function sandboxTryPayBounty(uint256 bountyId, address payable payReceiver)
        external
    {
        Bounty memory bounty = _claim({
            bountyId: bountyId,
            payReceiver: payReceiver,
            exploiter: IExploiter(address(0)),
            exploiterData: '',
            // To match state to that during a claim() we'll do everything
            // it does minus the exploit verification.
            skipExploit: true
        });
        revert SandboxSucceededError(abi.encode(0));
    }

    function _requestJudgement(uint256 bountyId, bytes memory beforeStatus, bytes memory afterStatus, address payReceiver) internal {
        bytes memory input = bytes(afterStatus);

        uint256 requestId = aiOracle.requestCallback{value: address(this).balance}(
            11, input, address(this), 500000000, ""
        );
        AIOracleRequest storage request = requests[requestId];
        request.input = input;
        request.sender = msg.sender;
        request.bountyId = bountyId;
        request.payReceiver = payReceiver;
        requestIdOfBountyId[bountyId] = requestId;
    }

    /// @dev The logic of claim(), refactored out for sandboxTryPayBounty().
    function _claim(
        uint256 bountyId,
        address payable payReceiver,
        IExploiter exploiter,
        bytes memory exploiterData,
        bool skipExploit
    )
        internal
        returns (Bounty memory bounty)
    {
        bounty = getBounty[bountyId];
        if (bounty.operator == address(0)) {
            // Invalid bounty or already claimed.
            revert InvalidClaimError();
        }
        if (address(exploiter) == address(bounty.pauser) ||
            address(exploiter) == address(bounty.payer))
        {
            revert InvalidExploitError();
        }
        // Preemptively mark the bounty as claimed/closed.
        getBounty[bountyId].operator = address(0);

        if (!skipExploit) {
            // Perform the exploit in a sandbox.
            try this.sandboxExploit(exploiter, bounty.verifier, exploiterData, payReceiver, bountyId) {
                assert(false);
            } catch (bytes memory errData) {
                console.logBytes(this.beforeStatus()); // 0x
                console.logBytes(errData);
                _requestJudgement(bountyId, beforeStatus, errData, payReceiver);
                console.log("request success");
                LibSandbox.handleSandboxCallRevert(errData, true);
            }
        }
    }

    // OAO call this.
    function aiOracleCallback(uint256 requestId, bytes calldata output, bytes calldata callbackData) external override onlyAIOracleCallback() {
        AIOracleRequest storage request = requests[requestId];
        request.output = output;
        uint256 bountyId = request.bountyId;
        address payReceiver = request.payReceiver;
        Bounty memory bounty = getBounty[bountyId];
        bytes memory outputString = output;
        if(outputString.length == 4) { // true
            // Pause the protocol.
            address(bounty.pauser).safeCall(abi.encodeCall(bounty.pauser.pause, (bountyId)));
            // Pay the bounty.
            uint256 payAmount = _payout(
                bountyId,
                bounty.payer,
                bounty.payoutToken,
                payable(payReceiver),
                bounty.payoutAmount
            );
        }
    }
   

    // Call a bounty's payer contract, verify that it transferred the payment, and
    // return the amount transferred.
    function _payout(
        uint256 bountyId,
        IPayer payer,
        ERC20 token,
        address payable to,
        uint256 amount
    )
        internal
        returns (uint256 payAmount)
    {
        uint256 balBefore = _balanceOf(token, to);
        address(payer).safeCall(abi.encodeCall(
            payer.payExploiter,
            (bountyId, token, to, amount)
        ));
        uint256 balAfter = _balanceOf(token, to);
        if (balBefore > balAfter || balAfter - balBefore < amount) {
            revert InsufficientPayoutError();
        }
        return balAfter - balBefore;
    }

    // Get the balance of a token (or ETH) of an account.
    function _balanceOf(ERC20 token, address owner)
        internal view returns (uint256 bal)
    {
        if (token == ETH_TOKEN) {
            return owner.balance;
        }
        return abi.decode(address(token).safeStaticCall(abi.encodeCall(
                token.balanceOf,
                (owner)
            )), (uint256)
        );
    }

    // Check that all bounty addresses are nonzero.
    function _validateBountyConfig(
        address operator,
        IPauser pauser,
        IVerifier verifier,
        IPayer payer
    ) internal pure {
        if (operator == address(0) ||
            address(pauser) == address(0) ||
            address(verifier) == address(0) ||
            address(payer)  == address(0)
        ) {
            revert InvalidBountyConfigError();
        }
    }
}
