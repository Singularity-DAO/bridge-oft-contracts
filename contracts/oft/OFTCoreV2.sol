// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./lzApp/NonblockingLzApp.sol";
import "./util/ExcessivelySafeCall.sol";
import "./interfaces/ICommonOFT.sol";
import "./interfaces/IOFTReceiverV2.sol";

abstract contract OFTCoreV2 is NonblockingLzApp {
  using BytesLib for bytes;
  using ExcessivelySafeCall for address;

  uint256 public constant NO_EXTRA_GAS = 0;

  // packet type
  uint8 public constant PT_SEND = 0;
  uint8 public constant PT_SEND_AND_CALL = 1;

  uint8 public immutable sharedDecimals;

  bool public useCustomAdapterParams;
  mapping(uint16 => mapping(bytes => mapping(uint64 => bool))) public creditedPackets;
  uint256 public totalCreditedAmount; // credited amount, which has not been consumed yet, but should be reserved for later consumption or reversal

  /**
   * @dev Emitted when `_amount` tokens are moved from the `_sender` to (`_dstChainId`, `_toAddress`)
   * `_nonce` is the outbound nonce
   */
  event SendToChain(uint16 indexed _dstChainId, address indexed _from, bytes32 indexed _toAddress, uint256 _amount);

  /**
   * @dev Emitted when `_amount` tokens are received from `_srcChainId` into the `_toAddress` on the local chain.
   * `_nonce` is the inbound nonce.
   */
  event ReceiveFromChain(uint16 indexed _srcChainId, address indexed _to, uint256 _amount, address indexed from);

  event SetUseCustomAdapterParams(bool _useCustomAdapterParams);

  event CallOFTReceivedSuccess(uint16 indexed _srcChainId, bytes _srcAddress, uint64 _nonce, bytes32 _hash);

  event NonContractAddress(address _address);

  // _sharedDecimals should be the minimum decimals on all chains
  constructor(uint8 _sharedDecimals, address _lzEndpoint) NonblockingLzApp(_lzEndpoint) {
    sharedDecimals = _sharedDecimals;
  }

  /************************************************************************
   * public functions
   ************************************************************************/
  function callOnOFTReceived(
    uint16 _srcChainId,
    bytes calldata _srcAddress,
    uint64 _nonce,
    bytes32 _from,
    address _to,
    uint256 _amount,
    bytes calldata _payload,
    uint256 _gasForCall
  ) public virtual {
    require(_msgSender() == address(this), "OFTCore: caller must be OFTCore");

    // send
    _amount = _transferFrom(address(this), _to, _amount);
    address from = address(uint160(uint256(_from)));
    emit ReceiveFromChain(_srcChainId, _to, _amount, from);

    // call
    IOFTReceiverV2(_to).onOFTReceived{ gas: _gasForCall }(_srcChainId, _srcAddress, _nonce, _from, _amount, _payload);
  }

  function setUseCustomAdapterParams(bool _useCustomAdapterParams) public virtual onlyOwner {
    useCustomAdapterParams = _useCustomAdapterParams;
    emit SetUseCustomAdapterParams(_useCustomAdapterParams);
  }

  /************************************************************************
   * internal functions
   ************************************************************************/
  function _estimateSendFee(
    uint16 _dstChainId,
    bytes32 _toAddress,
    uint256 _amount,
    bool _useZro,
    bytes memory _adapterParams
  ) internal view virtual returns (uint256 nativeFee, uint256 zroFee) {
    // mock the payload for sendFrom()
    bytes memory payload = _encodeSendPayload(_toAddress, _ld2sd(_amount), msg.sender);
    return lzEndpoint.estimateFees(_dstChainId, address(this), payload, _useZro, _adapterParams);
  }

  function _estimateSendAndCallFee(
    uint16 _dstChainId,
    bytes32 _toAddress,
    uint256 _amount,
    bytes memory _payload,
    uint64 _dstGasForCall,
    bool _useZro,
    bytes memory _adapterParams
  ) internal view virtual returns (uint256 nativeFee, uint256 zroFee) {
    // mock the payload for sendAndCall()
    bytes memory payload = _encodeSendAndCallPayload(msg.sender, _toAddress, _ld2sd(_amount), _payload, _dstGasForCall);
    return lzEndpoint.estimateFees(_dstChainId, address(this), payload, _useZro, _adapterParams);
  }

  function _nonblockingLzReceive(
    uint16 _srcChainId,
    bytes memory _srcAddress,
    uint64 _nonce,
    bytes memory _payload
  ) internal virtual override {
    uint8 packetType = _payload.toUint8(0);

    if (packetType == PT_SEND) {
      _sendAck(_srcChainId, _srcAddress, _nonce, _payload);
    } else if (packetType == PT_SEND_AND_CALL) {
      _sendAndCallAck(_srcChainId, _srcAddress, _nonce, _payload);
    } else {
      revert("OFTCore: unknown packet type");
    }
  }

  function _send(
    address _from,
    uint16 _dstChainId,
    bytes32 _toAddress,
    uint256 _amount,
    address payable _refundAddress,
    address _zroPaymentAddress,
    bytes memory _adapterParams
  ) internal virtual returns (uint256 amount) {
    _checkAdapterParams(_dstChainId, PT_SEND, _adapterParams, NO_EXTRA_GAS);

    (amount, ) = _removeDust(_amount);
    amount = _debitFrom(_from, _dstChainId, _toAddress, amount); // amount returned should not have dust
    require(amount > 0, "OFTCore: amount too small");

    bytes memory lzPayload = _encodeSendPayload(_toAddress, _ld2sd(amount), _from);
    _lzSend(_dstChainId, lzPayload, _refundAddress, _zroPaymentAddress, _adapterParams, msg.value);

    emit SendToChain(_dstChainId, _from, _toAddress, amount);
  }

  function _sendAck(
    uint16 _srcChainId,
    bytes memory,
    uint64,
    bytes memory _payload
  ) internal virtual {
    (address to, uint64 amountSD, address from) = _decodeSendPayload(_payload);
    if (to == address(0)) {
      to = address(0xdead);
    }

    uint256 amount = _sd2ld(amountSD);
    amount = _creditTo(_srcChainId, to, amount);

    emit ReceiveFromChain(_srcChainId, to, amount, from);
  }

  function _sendAndCall(
    address _from,
    uint16 _dstChainId,
    bytes32 _toAddress,
    uint256 _amount,
    bytes memory _payload,
    uint64 _dstGasForCall,
    address payable _refundAddress,
    address _zroPaymentAddress,
    bytes memory _adapterParams
  ) internal virtual returns (uint256 amount) {
    _checkAdapterParams(_dstChainId, PT_SEND_AND_CALL, _adapterParams, _dstGasForCall);

    (amount, ) = _removeDust(_amount);
    amount = _debitFrom(_from, _dstChainId, _toAddress, amount);
    require(amount > 0, "OFTCore: amount too small");

    // encode the msg.sender into the payload instead of _from
    bytes memory lzPayload = _encodeSendAndCallPayload(msg.sender, 
                                                       _toAddress, 
                                                       _ld2sd(amount), 
                                                       _payload, 
                                                       _dstGasForCall);
    _lzSend(_dstChainId, lzPayload, _refundAddress, _zroPaymentAddress, _adapterParams, msg.value);

    emit SendToChain(_dstChainId, _from, _toAddress, amount);
  }

  function _sendAndCallAck(
    uint16 _srcChainId,
    bytes memory _srcAddress,
    uint64 _nonce,
    bytes memory _payload
  ) internal virtual {
    (bytes32 from, address to, uint64 amountSD, bytes memory payloadForCall, uint64 gasForCall) 
        = _decodeSendAndCallPayload(_payload);

    bool credited = creditedPackets[_srcChainId][_srcAddress][_nonce];
    uint256 amount = _sd2ld(amountSD);

    // credit to this contract first, and then transfer to receiver only if callOnOFTReceived() succeeds
    if (!credited) {
      amount = _creditTo(_srcChainId, address(this), amount);
      creditedPackets[_srcChainId][_srcAddress][_nonce] = true;
      totalCreditedAmount += amount;
    }

    if (!_isContract(to)) {
      emit NonContractAddress(to);
      return;
    }

    // workaround for stack too deep
    uint16 srcChainId = _srcChainId;
    bytes memory srcAddress = _srcAddress;
    uint64 nonce = _nonce;
    bytes memory payload = _payload;
    bytes32 from_ = from;
    address to_ = to;
    uint256 amount_ = amount;
    bytes memory payloadForCall_ = payloadForCall;

    // no gas limit for the call if retry
    uint256 gas = credited ? gasleft() : gasForCall;
    (bool success, bytes memory reason) = address(this).excessivelySafeCall(
      gasleft(),
      150,
      abi.encodeWithSelector(this.callOnOFTReceived.selector, 
                             srcChainId, srcAddress, nonce, 
                             from_, to_, amount_, 
                             payloadForCall_, gas)
    );

    if (success) {
      bytes32 hash = keccak256(payload);
      emit CallOFTReceivedSuccess(srcChainId, srcAddress, nonce, hash);
      totalCreditedAmount -= amount;
    } else {
      // store the failed message into the nonblockingLzApp
      _storeFailedMessage(srcChainId, srcAddress, nonce, payload, reason);
    }
  }

  function _isContract(address _account) internal view returns (bool) {
    return _account.code.length > 0;
  }

  function _checkAdapterParams(
    uint16 _dstChainId,
    uint16 _pkType,
    bytes memory _adapterParams,
    uint256 _extraGas
  ) internal virtual {
    if (useCustomAdapterParams) {
      _checkGasLimit(_dstChainId, _pkType, _adapterParams, _extraGas);
    } else {
      require(_adapterParams.length == 0, "OFTCore: _adapterParams must be empty.");
    }
  }

  function _ld2sd(uint256 _amount) internal view virtual returns (uint64) {
    uint256 amountSD = _amount / _ld2sdRate();
    require(amountSD <= type(uint64).max, "OFTCore: amountSD overflow");
    return uint64(amountSD);
  }

  function _sd2ld(uint64 _amountSD) internal view virtual returns (uint256) {
    return _amountSD * _ld2sdRate();
  }

  function _removeDust(uint256 _amount) internal view virtual returns (uint256 amountAfter, uint256 dust) {
    dust = _amount % _ld2sdRate();
    amountAfter = _amount - dust;
  }

  function _encodeSendPayload(bytes32 _toAddress, uint64 _amountSD, address _from) internal view virtual returns (bytes memory) {
    return abi.encodePacked(PT_SEND, _toAddress, _amountSD, _addressToBytes32(_from));
  }
  
  function _decodeSendPayload(bytes memory _payload) internal view virtual returns (address to, uint64 amountSD, address from) {
    require(_payload.toUint8(0) == PT_SEND && _payload.length == 73, "OFTCore: invalid payload");

    to = _payload.toAddress(13); // drop the first 12 bytes of bytes32, we only need the 20 bytes of the address
    amountSD = _payload.toUint64(33);
    from = _payload.toAddress(53); // drop the first 12 bytes of bytes32, we only need the 20 bytes of the address
  }

  function _encodeSendAndCallPayload(
    address _from,
    bytes32 _toAddress,
    uint64 _amountSD,
    bytes memory _payload,
    uint64 _dstGasForCall
  ) internal view virtual returns (bytes memory) {
    return abi.encodePacked(PT_SEND_AND_CALL, 
                            _toAddress, 
                            _amountSD, 
                            _addressToBytes32(_from), 
                            _dstGasForCall, 
                            _payload);
  }

  function _decodeSendAndCallPayload(bytes memory _payload)
    internal
    view
    virtual
    returns (
      bytes32 from,
      address to,
      uint64 amountSD,
      bytes memory payload,
      uint64 dstGasForCall
    )
  {
    require(_payload.toUint8(0) == PT_SEND_AND_CALL, "OFTCore: invalid payload");

    to = _payload.toAddress(13); // drop the first 12 bytes of bytes32
    amountSD = _payload.toUint64(33);
    from = _payload.toBytes32(41);
    dstGasForCall = _payload.toUint64(73);
    payload = _payload.slice(81, _payload.length - 81);
  }

  function _addressToBytes32(address _address) internal pure virtual returns (bytes32) {
    return bytes32(uint256(uint160(_address)));
  }

  function _debitFrom(
    address _from,
    uint16 _dstChainId,
    bytes32 _toAddress,
    uint256 _amount
  ) internal virtual returns (uint256);

  function _creditTo(
    uint16 _srcChainId,
    address _toAddress,
    uint256 _amount
  ) internal virtual returns (uint256);

  function _transferFrom(
    address _from,
    address _to,
    uint256 _amount
  ) internal virtual returns (uint256);

  function _ld2sdRate() internal view virtual returns (uint256);
}
