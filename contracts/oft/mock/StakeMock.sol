// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "../interfaces/IOFTReceiverV2.sol";

contract StakeMock is IOFTReceiverV2 {
    bool failure;
    function onOFTReceived(uint16 /*_srcChainId*/, 
                           bytes calldata /*_srcAddress*/, 
                           uint64 /*_nonce*/, 
                           bytes32 /*_from*/, 
                           uint /*_amount*/, 
                           bytes calldata /*_payload*/) override external view {
       if (failure) {
          revert("forced-failure");
       }
    }
    
    function setFailure(bool _failure) external {
       failure = _failure;
    }
}