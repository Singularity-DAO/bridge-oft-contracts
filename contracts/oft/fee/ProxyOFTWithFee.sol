// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./BaseOFTWithFee.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title ProxyOFTWithFee
 * @notice ProxyOFTV2WithFee from Layer Zero extended with the ability to reverse failed messages and withdraw tokens.
 * @notice the caller of reverseMessage must pay for the nativeFee and gasFee.
 * @notice Non standard erc20 tokens such as erc777 are not supported.
 *         Using such token as innerToken can lead to unexpected behavior and loss of funds
 */
contract ProxyOFTWithFee is BaseOFTWithFee {
    using SafeERC20 for IERC20;
    using BytesLib for bytes;

    event ReverseMessageSuccess(
        uint16 _srcChainId,
        bytes _srcAddress,
        uint64 _nonce,
        bytes32 _payloadHash
    );

    IERC20 internal immutable innerToken;
    uint256 internal immutable ld2sdRate;

    // total amount is transferred from this chain to other chains, ensuring the total is less than uint64.max in sd
    uint256 public outboundAmount;

    constructor(
        address _token,
        uint8 _sharedDecimals,
        address _lzEndpoint
    ) BaseOFTWithFee(_sharedDecimals, _lzEndpoint) {
        innerToken = IERC20(_token);

        (bool success, bytes memory data) = _token.staticcall(
            abi.encodeWithSignature("decimals()")
        );
        require(success, "ProxyOFTWithFee: failed to get token decimals");
        uint8 decimals = abi.decode(data, (uint8));

        require(
            _sharedDecimals <= decimals && _sharedDecimals <= 10,
            "ProxyOFTWithFee: sharedDecimals is too big"
        );
        ld2sdRate = 10 ** (decimals - _sharedDecimals);
    }

    /************************************************************************
     * public functions
     ************************************************************************/
    function circulatingSupply()
        public
        view
        virtual
        override
        returns (uint256)
    {
        return innerToken.totalSupply() - outboundAmount;
    }

    function token() public view virtual override returns (address) {
        return address(innerToken);
    }

    /************************************************************************
     * internal functions
     ************************************************************************/
    function _debitFrom(
        address _from,
        uint16,
        bytes32,
        uint256 _amount
    ) internal virtual override returns (uint256) {
        require(
            _from == _msgSender(),
            "ProxyOFTWithFee: owner is not send caller"
        );

        _amount = _transferFrom(_from, address(this), _amount);

        // _amount still may have dust if the token has transfer fee, then give the dust back to the sender
        (uint256 amount, uint256 dust) = _removeDust(_amount);
        if (dust > 0) innerToken.safeTransfer(_from, dust);

        // check total outbound amount
        outboundAmount += amount;
        uint256 cap = _sd2ld(type(uint64).max);
        require(
            cap >= outboundAmount,
            "ProxyOFTWithFee: outboundAmount overflow"
        );

        return amount;
    }

    function _creditTo(
        uint16,
        address _toAddress,
        uint256 _amount
    ) internal virtual override returns (uint256) {
        outboundAmount -= _amount;

        // tokens are already in this contract, so no need to transfer
        if (_toAddress == address(this)) {
            return _amount;
        }

        return _transferFrom(address(this), _toAddress, _amount);
    }

    function _transferFrom(
        address _from,
        address _to,
        uint256 _amount
    ) internal virtual override returns (uint256) {
        uint256 before = innerToken.balanceOf(_to);
        if (_from == address(this)) {
            innerToken.safeTransfer(_to, _amount);
        } else {
            innerToken.safeTransferFrom(_from, _to, _amount);
        }
        return innerToken.balanceOf(_to) - before;
    }

    function _ld2sdRate() internal view virtual override returns (uint256) {
        return ld2sdRate;
    }

    /**
     * @notice Recover erc20 tokens sent to the contract instead of bridged properly.
     * @param _token The address of the token to recover
     * @param _amount The amount of tokens to recover
     * @notice This function can only be called by the owner
     * For the innerToken it should only be allowed to recover the difference between the balance and the outboundAmount
     * also excluding any tokens which have been credited in a sendAndCall where the call has not yet succeeded
     * This prevents the owner from withdrawing tokens which have been locked as collateral
     * due to bridging to other chains
     */
    function recoverTokens(address _token, uint256 _amount) public onlyOwner {
        if (_token == address(innerToken)) {
            uint256 maxAmount = innerToken.balanceOf(address(this)) -
                outboundAmount -
                totalCreditedAmount;
            require(
                _amount <= maxAmount,
                "ProxyOFTWithFee: not enough tokens to withdraw"
            );
        }
        IERC20(_token).safeTransfer(_msgSender(), _amount);
    }

    /**
     * @notice Reverses a failed message to source chain.
     * @param _srcChainId The source chain ID.
     * @param _srcAddress The source address.
     * @param _nonce The nonce of the failed message. you can get it from the local endpoint by calling getInboundNonce.
     * @param _payload The payload of the failed message.
     */
    function reverseMessage(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint64 _nonce,
        bytes calldata _payload
    ) public payable virtual {
        // assert there is message to reverse
        bytes32 payloadHash = failedMessages[_srcChainId][_srcAddress][_nonce];
        require(
            payloadHash != bytes32(0),
            "NonblockingLzApp: no stored message"
        );
        require(
            keccak256(_payload) == payloadHash,
            "NonblockingLzApp: invalid payload"
        );

        // clear the stored message
        failedMessages[_srcChainId][_srcAddress][_nonce] = bytes32(0);

        bytes memory _adapterParams = bytes("");
        address from = _msgSender();
        address zroPaymentAddress = address(0);

        _checkAdapterParams(_srcChainId, PT_SEND, _adapterParams, NO_EXTRA_GAS);

        // Decode original source address and amount
        bytes32 srcAddress = _payload.toBytes32(41);
        uint64 amountSD = _payload.toUint64(33);
        uint256 amount = _sd2ld(amountSD);

        // Debit already credited packets
        if (creditedPackets[_srcChainId][_srcAddress][_nonce]) {
            creditedPackets[_srcChainId][_srcAddress][_nonce] = false;
            outboundAmount += amount;
            totalCreditedAmount -= amount;
        }

        // construct new payload
        bytes memory lzPayload = _encodeSendPayload(srcAddress, amountSD, from);

        // execute the message. revert if it fails
        _lzSend(
            _srcChainId,
            lzPayload,
            payable(from),
            zroPaymentAddress,
            _adapterParams,
            msg.value
        );

        emit ReverseMessageSuccess(
            _srcChainId,
            _srcAddress,
            _nonce,
            payloadHash
        );
    }
}
