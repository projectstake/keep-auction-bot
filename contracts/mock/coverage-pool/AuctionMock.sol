// ▓▓▌ ▓▓ ▐▓▓ ▓▓▓▓▓▓▓▓▓▓▌▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▄
// ▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▌▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
//   ▓▓▓▓▓▓    ▓▓▓▓▓▓▓▀    ▐▓▓▓▓▓▓    ▐▓▓▓▓▓   ▓▓▓▓▓▓     ▓▓▓▓▓   ▐▓▓▓▓▓▌   ▐▓▓▓▓▓▓
//   ▓▓▓▓▓▓▄▄▓▓▓▓▓▓▓▀      ▐▓▓▓▓▓▓▄▄▄▄         ▓▓▓▓▓▓▄▄▄▄         ▐▓▓▓▓▓▌   ▐▓▓▓▓▓▓
//   ▓▓▓▓▓▓▓▓▓▓▓▓▓▀        ▐▓▓▓▓▓▓▓▓▓▓         ▓▓▓▓▓▓▓▓▓▓         ▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
//   ▓▓▓▓▓▓▀▀▓▓▓▓▓▓▄       ▐▓▓▓▓▓▓▀▀▀▀         ▓▓▓▓▓▓▀▀▀▀         ▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▀
//   ▓▓▓▓▓▓   ▀▓▓▓▓▓▓▄     ▐▓▓▓▓▓▓     ▓▓▓▓▓   ▓▓▓▓▓▓     ▓▓▓▓▓   ▐▓▓▓▓▓▌
// ▓▓▓▓▓▓▓▓▓▓ █▓▓▓▓▓▓▓▓▓ ▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  ▓▓▓▓▓▓▓▓▓▓
// ▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓ ▐▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓  ▓▓▓▓▓▓▓▓▓▓
//
//                           Trust math, not hardware.

// SPDX-License-Identifier: MIT

pragma solidity 0.8.4;

import "../../interfaces/IAuction.sol";
import "./AuctioneerMock.sol";
import "./CoveragePoolConstants.sol";

import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Auction
/// @notice A contract to run a linear falling-price auction against a diverse
///         basket of assets held in a collateral pool. Auctions are taken using
///         a single asset. Over time, a larger and larger portion of the assets
///         are on offer, eventually hitting 100% of the backing collateral
///         pool. Auctions can be partially filled, and are meant to be amenable
///         to flash loans and other atomic constructions to take advantage of
///         arbitrage opportunities within a single block.
/// @dev  Auction contracts are not meant to be deployed directly, and are
///       instead cloned by an auction factory. Auction contracts clean up and
///       self-destruct on close. An auction that has run the entire length will
///       stay open, forever, or until priced fluctuate and it's eventually
///       profitable to close.
contract AuctionMock is IAuction {
    using SafeERC20 for IERC20;

    struct AuctionStorage {
        IERC20 tokenAccepted;
        AuctioneerMock auctioneer;
        // the auction price, denominated in tokenAccepted
        uint256 amountOutstanding;
        uint256 amountDesired;
        uint256 auctionLength;
        // How fast portions of the collateral pool become available on offer.
        // It is needed to calculate the right portion value on offer at the
        // given moment before the auction is over.
        // Auction length once set is constant and what changes is the auction's
        // "start time offset" once the takeOffer() call has been processed for
        // partial fill. The auction's "start time offset" is updated every takeOffer().
        // velocityPoolDepletingRate = auctionLength / (auctionLength - startTimeOffset)
        // velocityPoolDepletingRate always starts at 1.0 and then can go up
        // depending on partial offer calls over auction life span to maintain
        // the right ratio between the remaining auction time and the remaining
        // portion of the collateral pool.
        uint256 velocityPoolDepletingRate;
    }

    AuctionStorage public self;
    bool public isMasterContract;

    /// @notice Throws if called by any account other than the auctioneer.
    modifier onlyAuctioneer() {
        //slither-disable-next-line incorrect-equality
        require(
            msg.sender == address(self.auctioneer),
            "Caller is not the auctioneer"
        );

        _;
    }

    constructor() {
        isMasterContract = true;
    }

    /// @notice Initializes auction
    /// @dev At the beginning of an auction, velocity pool depleting rate is
    ///      always 1. It increases over time after a partial auction buy.
    /// @param _auctioneer    the auctioneer contract responsible for seizing
    ///                       funds from the backing collateral pool
    /// @param _tokenAccepted the token with which the auction can be taken
    /// @param _amountDesired the amount denominated in _tokenAccepted. After
    ///                       this amount is received, the auction can close.
    /// @param _auctionLength the amount of time it takes for the auction to get
    ///                       to 100% of all collateral on offer, in seconds.
    function initialize(
        address _auctioneer,
        IERC20 _tokenAccepted,
        uint256 _amountDesired,
        uint256 _auctionLength
    ) external {
        require(!isMasterContract, "Can not initialize master contract");
        require(_amountDesired > 0, "Amount desired must be greater than zero");
        self.auctioneer = AuctioneerMock(_auctioneer);
        self.tokenAccepted = _tokenAccepted;
        self.amountOutstanding = _amountDesired;
        self.amountDesired = _amountDesired;
        self.auctionLength = _auctionLength;
        self.velocityPoolDepletingRate =
            1 *
            CoveragePoolConstants.FLOATING_POINT_DIVISOR;
    }

    /// @notice Takes an offer from an auction buyer.
    /// @dev There are two possible ways to take an offer from a buyer. The first
    ///      one is to buy entire auction with the amount desired for this auction.
    ///      The other way is to buy a portion of an auction. In this case an
    ///      auction depleting rate is increased.
    ///      WARNING: When calling this function directly, it might happen that
    ///      the expected amount of tokens to seize from the coverage pool is
    ///      different from the actual one. There are a couple of reasons for that
    ///      such another bids taking this offer, claims or withdrawals on an
    ///      Asset Pool that are executed in the same block. The recommended way
    ///      for taking an offer is through 'AuctionBidder' contract with
    ///      'takeOfferWithMin' function, where a caller can specify the minimal
    ///      value to receive from the coverage pool in exchange for its amount
    ///      of tokenAccepted.
    /// @param amount the amount the taker is paying, denominated in tokenAccepted.
    ///               In the scenario when amount exceeds the outstanding tokens
    ///               for the auction to complete, only the amount outstanding will
    ///               be taken from a caller.
    function takeOffer(uint256 amount) external override {
        require(amount > 0, "Can't pay 0 tokens");
        uint256 amountToTransfer = Math.min(amount, self.amountOutstanding);
        uint256 amountOnOffer = _onOffer();

        //slither-disable-next-line reentrancy-no-eth
        self.tokenAccepted.safeTransferFrom(
            msg.sender,
            address(self.auctioneer),
            amountToTransfer
        );

        uint256 portionToSeize = (amountOnOffer * amountToTransfer) /
            self.amountOutstanding;

        self.amountOutstanding -= amountToTransfer;

        // inform auctioneer of proceeds and winner. the auctioneer seizes funds
        // from the collateral pool in the name of the winner, and controls all
        // proceeds
        //
        //slither-disable-next-line reentrancy-no-eth
        self.auctioneer.offerTaken(
            msg.sender,
            self.tokenAccepted,
            amountToTransfer,
            portionToSeize
        );

        //slither-disable-next-line incorrect-equality
        if (self.amountOutstanding == 0) {
            harikari();
        }
    }

    /// @notice Tears down the auction manually, before its entire amount
    ///         is bought by takers.
    /// @dev Can be called only by the auctioneer which may decide to early
    //       close the auction in case it is no longer needed.
    function earlyClose() external onlyAuctioneer {
        require(self.amountOutstanding > 0, "Auction must be open");

        harikari();
    }

    /// @notice How much of the collateral pool can currently be purchased at
    ///         auction, across all assets.
    /// @dev _onOffer() / FLOATING_POINT_DIVISOR) returns a portion of the
    ///      collateral pool. Ex. if 35% available of the collateral pool,
    ///      then _onOffer() / FLOATING_POINT_DIVISOR) returns 0.35
    /// @return the ratio of the collateral pool currently on offer
    function onOffer() external pure override returns (uint256, uint256) {
        return (_onOffer(), CoveragePoolConstants.FLOATING_POINT_DIVISOR);
    }

    function amountOutstanding() external view override returns (uint256) {
        return self.amountOutstanding;
    }

    function amountTransferred() external view override returns (uint256) {
        return self.amountDesired - self.amountOutstanding;
    }

    function isOpen() external view override returns (bool) {
        return self.amountOutstanding > 0;
    }

    /// @dev Delete all storage and destroy the contract. Should only be called
    ///      after an auction has closed.
    function harikari() internal {
        require(!isMasterContract, "Master contract can not harikari");
        address payable addr = payable(
            address(uint160(address(self.auctioneer)))
        );
        delete self;
        selfdestruct(addr);
    }

    function _onOffer() internal pure returns (uint256) {
        // Pretend the entire pool is on offer
        return CoveragePoolConstants.FLOATING_POINT_DIVISOR;
    }
}
