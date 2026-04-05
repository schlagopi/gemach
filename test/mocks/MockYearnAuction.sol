// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MockERC20} from "./MockERC20.sol";

/// @title MockYearnAuction
/// @notice Mock for the Yearn V3 Auction v1.0.4. Tracks state for testing
///         the pool's auction integration including pricing configuration.
contract MockYearnAuction {
    address public want; // debt token
    address public receiver; // where want goes on takes

    uint256 public startingPrice;
    uint256 public minimumPrice;
    uint256 public stepDecayRate;
    uint256 public stepDuration;
    bool public governanceOnlyKick;

    mapping(address => bool) public enabled;
    mapping(address => bool) public activeAuctions;
    mapping(address => uint256) public kickedAt;
    mapping(address => uint256) public initialAvailable;

    constructor(address _want, address _receiver) {
        want = _want;
        receiver = _receiver;
        startingPrice = 1_000_000;
        stepDecayRate = 50;
        stepDuration = 60;
    }

    // -------- views --------

    function isActive(address _from) public view returns (bool) {
        return activeAuctions[_from];
    }

    function available(address _from) public view returns (uint256) {
        if (!isActive(_from)) return 0;
        uint256 bal = MockERC20(_from).balanceOf(address(this));
        uint256 init = initialAvailable[_from];
        return bal < init ? bal : init;
    }

    function kickable(address _from) external view returns (uint256) {
        if (isActive(_from)) return 0;
        return MockERC20(_from).balanceOf(address(this));
    }

    function kicked(address _from) external view returns (uint256) {
        return kickedAt[_from];
    }

    function isAnActiveAuction() external view returns (bool) {
        return false; // simplified for mock
    }

    function price(address) external pure returns (uint256) {
        return 1e18;
    }

    function price(address, uint256) external pure returns (uint256) {
        return 1e18;
    }

    function getAmountNeeded(address _from) external view returns (uint256) {
        return available(_from); // 1:1 for simplicity
    }

    function getAmountNeeded(address, uint256 _amount) external pure returns (uint256) {
        return _amount;
    }

    function getAllEnabledAuctions() external pure returns (address[] memory) {
        return new address[](0);
    }

    // -------- mutative --------

    function kick(address _from) external returns (uint256 _available) {
        require(enabled[_from], "not enabled");
        require(!isActive(_from), "too soon");
        _available = MockERC20(_from).balanceOf(address(this));
        require(_available > 0, "nothing to kick");
        activeAuctions[_from] = true;
        kickedAt[_from] = block.timestamp;
        initialAvailable[_from] = _available;
    }

    function forceKick(address _from) external returns (uint256) {
        activeAuctions[_from] = false;
        kickedAt[_from] = 0;
        return this.kick(_from);
    }

    function settle(address _from) external {
        require(isActive(_from), "!active");
        require(MockERC20(_from).balanceOf(address(this)) == 0, "!empty");
        activeAuctions[_from] = false;
        kickedAt[_from] = 0;
    }

    function sweep(address _token) external {
        uint256 bal = MockERC20(_token).balanceOf(address(this));
        if (bal > 0) MockERC20(_token).transfer(msg.sender, bal);
    }

    // -------- governance config --------

    function enable(address _from) external {
        enabled[_from] = true;
    }

    function disable(address _from) external {
        enabled[_from] = false;
    }

    function setStartingPrice(uint256 _sp) external {
        startingPrice = _sp;
    }

    function setMinimumPrice(uint256 _mp) external {
        minimumPrice = _mp;
    }

    function setStepDecayRate(uint256 _sdr) external {
        stepDecayRate = _sdr;
    }

    function setStepDuration(uint256 _sd) external {
        stepDuration = _sd;
    }

    function setReceiver(address _r) external {
        receiver = _r;
    }

    function setGovernanceOnlyKick(bool _g) external {
        governanceOnlyKick = _g;
    }

    function initialize(address _want, address _receiver, address, uint256 _sp) external {
        want = _want;
        receiver = _receiver;
        startingPrice = _sp;
    }

    // -------- test helper: simulate a take (buyer gets from, pool gets want) --------

    function simulateTake(address _from, uint256 amount, uint256 wantAmount) external {
        // Transfer from-token to the taker (msg.sender)
        MockERC20(_from).transfer(msg.sender, amount);
        // Pull want from msg.sender to receiver
        MockERC20(want).transferFrom(msg.sender, receiver, wantAmount);
        // If fully taken, end auction
        if (MockERC20(_from).balanceOf(address(this)) == 0) {
            activeAuctions[_from] = false;
            kickedAt[_from] = 0;
        }
    }
}
