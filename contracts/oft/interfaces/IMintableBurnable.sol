// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

interface IMintableBurnable {
    function mint(address to, uint256 amount) external returns (bool);

    function burn(uint256 amount) external;
    function burnFrom(address from, uint256 amount) external ;
}