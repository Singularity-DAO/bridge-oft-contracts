// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "./BaseOFTWithFee.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/IMintableBurnable.sol";

contract IndirectOFTV2WithFee is BaseOFTWithFee {
    using SafeERC20 for IERC20;
    
    address public immutable innerToken;
    uint public immutable ld2sdRate;

    constructor(
        address _token,
        uint8 _sharedDecimals,
        address _lzEndpoint
    )  BaseOFTWithFee(_sharedDecimals, _lzEndpoint) {
        innerToken = _token;

        (bool success, bytes memory data) = _token.staticcall(abi.encodeWithSignature("decimals()"));
        require(success, "IndirectOFTWithFee: failed to get token decimals");
        uint8 decimals = abi.decode(data, (uint8));

        require(_sharedDecimals <= decimals && _sharedDecimals <= 10, "IndirectOFTWithFee: sharedDecimals is too big");
        ld2sdRate = 10 ** (decimals - _sharedDecimals);
    }

    /************************************************************************
     * public functions
     ************************************************************************/
    function circulatingSupply() public view virtual override returns (uint) {
        return IERC20(innerToken).totalSupply();
    }

    function token() public view virtual override returns (address) {
        return innerToken;
    }

    /************************************************************************
     * internal functions
     ************************************************************************/
    function _debitFrom(address _from, uint16, bytes32, uint _amount) internal virtual override returns (uint) {
        require(_from == _msgSender(), "IndirectOFTWithFee: owner is not send caller");
        IMintableBurnable(innerToken).burnFrom(_from, _amount);

        return _amount;
    }

    function _creditTo(uint16, address _toAddress, uint _amount) internal virtual override returns (uint) {
        IMintableBurnable(innerToken).mint(_toAddress, _amount);

        return _amount;
    }

    function _transferFrom(address _from, address _to, uint _amount) internal virtual override returns (uint){
        if (_from == address(this)) {
            IERC20(innerToken).safeTransfer(_to, _amount);
        } else {
            IERC20(innerToken).safeTransferFrom(_from, _to, _amount);
        }

        return _amount;
    }

    function _ld2sdRate() internal view virtual override returns (uint) {
        return ld2sdRate;
    }
}