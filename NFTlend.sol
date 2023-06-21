// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

//Errors
error NotOwner();
error AlreadyListed(address nftAddress, uint256 tokenId);
error LoanMustBeAboveZero();
error NotApprovedForBorrowing();
error NotListed(address nftAddress, uint256 tokenId);
error LoanNotMet(address nftAddress, uint256 tokenId, uint256 minLoanValue);
error NoProceeds();
error NoLoan();

/**
 * @title Sistem descentralizat de împrumut de criptomonede ce folosește NFTs ca și garanție, pe blockchain-ul Ethereum
 * @author Diculescu David
 * @notice This contract can manage ETH loans backed by NFTs
 */

contract NFTlend is ReentrancyGuard {
    struct Listing {
        uint256 minLoanValue;
        uint256 interestRate;
        address owner;
    }

    struct Loan {
        address nftAddress;
        uint256 tokenId;
        address borrower;
        address lender;
        uint256 loanAmount;
        uint256 interestRate;
    }

    // State variables
    mapping(address => mapping(uint256 => Listing)) private s_listings;
    mapping(address => Loan) private s_loans;
    mapping(address => uint256) private s_proceeds;
    mapping(address => uint256) private s_loaned;

    //Events
    event ItemListed(
        address indexed borrower,
        address indexed nftAddress,
        uint256 indexed tokenId,
        uint256 minLoanValue,
        uint256 interestRate
    );

    event ItemCancelled(
        address indexed borrower,
        address indexed nftAddress,
        uint256 indexed tokenId
    );

    event ItemLoaned(
        address indexed lender,
        address indexed nftAddress,
        uint256 indexed tokenId,
        uint256 loanValue,
        uint256 interestRate
    );

    event LoanPayed(
        address indexed borrower,
        address indexed nftAddress,
        uint256 indexed tokenId,
        uint256 loanValue
    );

    //Modifiers
    modifier isOwner(
        address nftAddress,
        uint256 tokenId,
        address spender
    ) {
        IERC721 nft = IERC721(nftAddress);
        address owner = nft.ownerOf(tokenId);
        if (spender != owner) {
            revert NotOwner();
        }
        _;
    }

    modifier isListed(address nftAddress, uint256 tokenId) {
        Listing memory listing = s_listings[nftAddress][tokenId];
        if (listing.minLoanValue <= 0) {
            revert NotListed(nftAddress, tokenId);
        }
        _;
    }

    modifier notListed(address nftAddress, uint256 tokenId) {
        Listing memory listing = s_listings[nftAddress][tokenId];
        if (listing.minLoanValue > 0) {
            revert AlreadyListed(nftAddress, tokenId);
        }
        _;
    }

    // Functions
    /**
     * @notice Method for listing an NFT for a loan
     * @param nftAddress address of the NFT contract
     * @param tokenId the token ID of the NFT
     * @param minLoanValue the loan amount the borrower is looking for
     * @param interestRate the % of the interest
     */
    function listNFT(
        address nftAddress,
        uint256 tokenId,
        uint256 minLoanValue,
        uint256 interestRate
    )
        external
        notListed(nftAddress, tokenId)
        isOwner(nftAddress, tokenId, msg.sender)
    {
        if (minLoanValue <= 0) {
            revert LoanMustBeAboveZero();
        }
        IERC721 nft = IERC721(nftAddress);
        if (nft.getApproved(tokenId) != address(this)) {
            revert NotApprovedForBorrowing();
        }
        s_listings[nftAddress][tokenId] = Listing(
            minLoanValue,
            interestRate,
            msg.sender
        );
        emit ItemListed(
            msg.sender,
            nftAddress,
            tokenId,
            minLoanValue,
            interestRate
        );
    }

    /**
     * @notice Method for cancelling a listing
     * @param nftAddress address of the NFT contract
     * @param tokenId the token ID of the NFT
     */
    function cancelListing(
        address nftAddress,
        uint256 tokenId
    )
        external
        isOwner(nftAddress, tokenId, msg.sender)
        isListed(nftAddress, tokenId)
    {
        delete (s_listings[nftAddress][tokenId]);
    }

    /**
     * @notice Method for a lender to loan the requested amount to the borrower
     * @param nftAddress address of the NFT contract that that is used as collateral
     * @param tokenId the token ID of the NFT that is used as collateral
     */
    function offerLoan(
        address nftAddress,
        uint256 tokenId
    ) external payable isListed(nftAddress, tokenId) nonReentrant {
        Listing memory listedItem = s_listings[nftAddress][tokenId];
        if (msg.value < listedItem.minLoanValue) {
            revert LoanNotMet(nftAddress, tokenId, listedItem.minLoanValue);
        }
        Loan memory newLoan = Loan(
            nftAddress,
            tokenId,
            listedItem.owner,
            msg.sender,
            msg.value,
            listedItem.interestRate
        );
        s_loans[listedItem.owner] = newLoan;
        s_loaned[listedItem.owner] = msg.value;
        delete (s_listings[nftAddress][tokenId]);
        IERC721(nftAddress).transferFrom(
            listedItem.owner,
            address(this),
            tokenId
        );

        emit ItemLoaned(
            msg.sender,
            nftAddress,
            tokenId,
            listedItem.minLoanValue,
            listedItem.interestRate
        );
    }

    /**
     * @notice Method for the borrower to get his borrowed ETH
     */
    function withdrawLoanedAmount() external {
        uint256 loanSum = s_loaned[msg.sender];
        if (loanSum <= 0) {
            revert NoLoan();
        }
        s_loaned[msg.sender] = 0;
        (bool succes, ) = payable(msg.sender).call{value: loanSum}("");
        require(succes, "Transfer failed!");
    }

    /**
     * @notice Method for the borrwoer to pay back the ETH
     * @param nftAddress address of the NFT contract that has been used as collateral
     * @param tokenId the token ID of the NFT that has been used as collateral
     */
    function payBackLoan(address nftAddress, uint256 tokenId) external payable {
        Loan memory loanItem = s_loans[msg.sender];
        uint256 totalDebt = loanItem.loanAmount +
            (loanItem.interestRate / 100) *
            loanItem.loanAmount;
        if (msg.value < totalDebt) {
            revert LoanNotMet(nftAddress, tokenId, totalDebt);
        }

        s_proceeds[loanItem.lender] += msg.value;
        delete (s_loans[msg.sender]);
        IERC721(nftAddress).transferFrom(address(this), msg.sender, tokenId);

        emit LoanPayed(msg.sender, nftAddress, tokenId, msg.value);
    }

    /**
     * @notice Method for the lender to withdraw his ETH back
     */
    function withdrawProceeds() external {
        uint256 proceeds = s_proceeds[msg.sender];
        if (proceeds <= 0) {
            revert NoProceeds();
        }
        s_proceeds[msg.sender] = 0;
        (bool succes, ) = payable(msg.sender).call{value: proceeds}("");
        require(succes, "Transfer failed!");
    }

    // Getter Functions
    function getListing(
        address nftAddress,
        uint256 tokenId
    ) external view returns (Listing memory) {
        return s_listings[nftAddress][tokenId];
    }

    function getLoan(address borrower) external view returns (Loan memory) {
        return s_loans[borrower];
    }
}
