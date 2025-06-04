//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract InvoiceToken is ERC20, ReentrancyGuard {
    error InvoiceToken__MoreThanZero(uint256 amount);
    error InvoiceToken__AddressIsZero(address addr);
    error InvoiceToken__OwnerIsMainContract();
    error InvoiceToken__ExceedsMaxSupply();
    error InvoiceToken__TokensExceedsMaxSupply();
    error InvoiceToken__InsufficientBalance(uint256 balance, uint256 required);
    error InvoiceToken__TransferFailed();
    error InvoiceToken__RefundFailed();

    uint256 public constant DISCOUNT_RATE = 5;
    uint256 public immutable maxSupply;
    address public immutable supplier;
    address public immutable mainContract;
    uint256 public totalPaidToSupplier;
    AggregatorV3Interface internal immutable priceFeed;

    modifier moreThanZero(uint256 _amount) {
        if (_amount <= 0) revert InvoiceToken__MoreThanZero(_amount);
        _;
    }

    modifier ValidAddress(address _addr) {
        if (_addr == address(0)) revert InvoiceToken__AddressIsZero(_addr);
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _invoiceAmountUSD,
        address _supplierAddress,
        address _mainContractAddress
    ) ERC20(_name, _symbol) ValidAddress(_supplierAddress) ValidAddress(_mainContractAddress) {
        priceFeed = AggregatorV3Interface(0x694AA1769357215DE4FAC081bf1f309aDC325306);
        supplier = _supplierAddress;
        mainContract = _mainContractAddress;

        maxSupply = _invoiceAmountUSD - (_invoiceAmountUSD * DISCOUNT_RATE / 100);
    }

    modifier onlyMainContract() {
        if (msg.sender != mainContract) revert InvoiceToken__OwnerIsMainContract();
        _;
    }

    function getETHPrice() public view returns (uint256) {
        (, int256 price,,,) = priceFeed.latestRoundData();
        if (price <= 0) revert InvoiceToken__MoreThanZero(uint256(price));
        return uint256(price) * 1e10;
    }

    function getExactCost(uint256 _amount) public view moreThanZero(_amount) returns (uint256) {
        return (_amount * 1e18) / getETHPrice();
    }

    function buyTokens(uint256 _amount, address _investor)
        external
        payable
        nonReentrant
        moreThanZero(_amount)
        ValidAddress(_investor)
        onlyMainContract
        returns (bool)
    {
        if (totalSupply() + _amount > maxSupply) revert InvoiceToken__TokensExceedsMaxSupply();

        uint256 cost = getExactCost(_amount);
        if (msg.value < cost) revert InvoiceToken__InsufficientBalance(msg.value, cost);

        _mint(_investor, _amount);

        (bool success,) = payable(supplier).call{value: cost}("");
        if (!success) revert InvoiceToken__TransferFailed();

        totalPaidToSupplier += cost;

        if (msg.value > cost) {
            (bool refundSuccess,) = payable(_investor).call{value: msg.value - cost}("");
            if (!refundSuccess) revert InvoiceToken__RefundFailed();
        }
        return true;
    }

    function burnAllTokens(address[] calldata _holders) external onlyMainContract returns (uint256) {
        uint256 holdersLength = _holders.length;
        uint256 totalBurned = 0;

        for (uint256 i = 0; i < holdersLength;) {
            address holder = _holders[i];
            uint256 balance = balanceOf(holder);

            if (balance > 0) {
                _burn(holder, balance);
                totalBurned += balance;
            }

            unchecked {
                i++;
            }
        }
        return totalBurned;
    }

    function remainingCapacity() external view returns (uint256) {
        return maxSupply - totalSupply();
    }

    function getOriginalInvoiceAmount() external view returns (uint256) {
        return (maxSupply * 100) / (100 - DISCOUNT_RATE);
    }

    function getSupplier() external view returns (address) {
        return supplier;
    }
}
