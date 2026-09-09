// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Token, Wrapped, MockDex} from "./Route.t.sol";
import {Route} from "../Route.sol";
import {V2Adapter} from "../adapters/V2Adapter.sol";

/// @notice Synthetic liquidity fixture, restricted to Robinhood testnet.
/// Never use its unrestricted mock tokens or venues with real funds.
contract TestnetFixture {
    Wrapped public immutable wrapped;
    Token public immutable dollar;
    Route public immutable route;
    constructor() payable {
        require(block.chainid == 46630 && msg.value == 0.0002 ether, "testnet only");
        wrapped = new Wrapped(); dollar = new Token("TEST-USD");
        MockDex a = new MockDex(); MockDex b = new MockDex();
        a.setRate(address(wrapped), address(dollar), 1900e18);
        b.setRate(address(wrapped), address(dollar), 2000e18);
        a.setRate(address(dollar), address(wrapped), 5e14);
        b.setRate(address(dollar), address(wrapped), 49e13);
        dollar.mint(address(a), 1000 ether); dollar.mint(address(b), 1000 ether);
        wrapped.deposit{value: msg.value}();
        wrapped.transfer(address(a), msg.value / 2); wrapped.transfer(address(b), msg.value / 2);
        address[] memory adapters = new address[](2);
        adapters[0] = address(new V2Adapter("synthetic A", address(a)));
        adapters[1] = address(new V2Adapter("synthetic B", address(b)));
        route = new Route(address(wrapped), adapters, new address[](0));
    }
}
