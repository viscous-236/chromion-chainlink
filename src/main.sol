//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {InvoiceToken} from "./InvoiceToken.sol";
import "./chainlink/ConfirmedOwner.sol";
import "src/chainlink/FunctionsClient.sol";



contract Main {
    error Main__MoreThanZero();
    error Main__MustBeValidAddress();
    error Main__MustBeUnique();
    error Main__CallerMustBeSupplier();
    error Main__CallerMustBeInvestor();
    error Main__DueDateMustBeInFuture();
    error Main__InvoiceTokenNotFound();
    error Main__InvoiceMustBeApproved();
    error Main__TokensBuyingFails();
    error Main__RoleAlereadyChosen();

    enum UserRole {
        Supplier,
        Buyer,
        Investor
    }

    enum InvoiceStatus {
        Pending,
        Approved,
        Rejected
    }

    struct Invoice {
        uint256 id;
        address supplier;
        address buyer;
        uint256 amount;
        address[] investors;
        InvoiceStatus status;
        uint256 dueDate;
    }

    mapping(uint256 id => mapping(address investor => uint256 amountOfTokensPurchased)) public
        amountOfTokensPurchasedByInvestor;
    mapping(uint256 id => Invoice invoice) public invoices;
    mapping(uint256 id => bool) public IdAlreadyExists;
    mapping(address user => UserRole role) public userRole;
    mapping(uint256 id => address token) public invoiceToken;
    mapping(address => bool) public hasChosenRole;

    event ContractFunded(address indexed sender, uint256 amount);
    event InvoiceCreated(
        uint256 indexed id, address indexed supplier, address indexed buyer, uint256 amount, uint256 dueDate
    );

    modifier MoreThanZero(uint256 _number) {
        if (_number <= 0) {
            revert Main__MoreThanZero();
        }
        _;
    }

    modifier ValidAddress(address _address) {
        if (_address == address(0)) {
            revert Main__MustBeValidAddress();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                       EXTERNAL_PUBLIC_FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    receive() external payable {
        emit ContractFunded(msg.sender, msg.value);
    }

    function chooseRole(UserRole _role) external {
        if (hasChosenRole[msg.sender]) revert Main__RoleAlereadyChosen();
        userRole[msg.sender] = _role;
        hasChosenRole[msg.sender] = true;
    }

    function createInvoice(uint256 _id, address _buyer, uint256 _amount, uint256 _dueDate)
        external
        MoreThanZero(_id)
        MoreThanZero(_amount)
        ValidAddress(_buyer)
    {
        if (IdAlreadyExists[_id]) {
            revert Main__MustBeUnique();
        }
        if (userRole[msg.sender] != UserRole.Supplier) {
            revert Main__CallerMustBeSupplier();
        }
        if (block.timestamp >= _dueDate) {
            revert Main__DueDateMustBeInFuture();
        }
        IdAlreadyExists[_id] = true;
        invoices[_id] = Invoice({
            id: _id,
            supplier: msg.sender,
            buyer: _buyer,
            amount: _amount,
            investors: new address[](0),
            status: InvoiceStatus.Pending,
            dueDate: _dueDate
        });
        // Use Chianlink function to verify that it is a valid invoice
        generateErc20(_id, _amount);
        emit InvoiceCreated(_id, msg.sender, _buyer, _amount, _dueDate);
    }

    function buyTokens(uint256 _id, uint256 _amount) external payable {
        if (invoiceToken[_id] == address(0)) {
            revert Main__InvoiceTokenNotFound();
        }
        if (userRole[msg.sender] != UserRole.Investor) {
            revert Main__CallerMustBeInvestor();
        }
        if (IdAlreadyExists[_id] == false) {
            revert Main__InvoiceTokenNotFound();
        }
        if (invoices[_id].status != InvoiceStatus.Approved) {
            revert Main__InvoiceMustBeApproved();
        }
        amountOfTokensPurchasedByInvestor[_id][msg.sender] += _amount;
        invoices[_id].investors.push(msg.sender);
        InvoiceToken token = InvoiceToken(invoiceToken[_id]);
        uint256 totalCost = token.getExactCost(_amount);
        bool success = token.buyTokens{value: totalCost}(_amount);
        if (!success) {
            revert Main__TokensBuyingFails();
        }
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL_PRIVATE_FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function generateErc20(uint256 _id, uint256 _amount) internal MoreThanZero(_id) MoreThanZero(_amount) {
        if (invoices[_id].status != InvoiceStatus.Approved) {
            revert Main__InvoiceMustBeApproved();
        }
        string memory name = string(abi.encodePacked("InvoiceToken_", uint2str(_id)));
        string memory symbol = string(abi.encodePacked("IT_", uint2str(_id)));

        InvoiceToken newInvoiceToken = new InvoiceToken(name, symbol, _amount, invoices[_id].supplier);
        address tokenAddress = address(newInvoiceToken);
        invoiceToken[_id] = tokenAddress;
    }

    function uint2str(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }
        uint256 j = _i;
        uint256 len;
        while (j != 0) {
            len++;
            j /= 10;
        }
        bytes memory bstr = new bytes(len);
        uint256 k = len;
        while (_i != 0) {
            k = k - 1;
            uint8 temp = (48 + uint8(_i - _i / 10 * 10));
            bytes1 b1 = bytes1(temp);
            bstr[k] = b1;
            _i /= 10;
        }
        return string(bstr);
    }
}
