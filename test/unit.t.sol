//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {Main} from "../src/main.sol";

contract UnitTest is Test {
    Main public main;

    function setUp() public {
        main = new Main();
    }
}
