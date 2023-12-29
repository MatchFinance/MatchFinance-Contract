// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./PEUSDVault.sol";
import "../../interfaces/LybraInterfaces.sol";
import "../../interfaces/DappInterfaces.sol";

contract wstETHMintPool is PEUSDVault {
    ILido immutable lido;
    //WstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    //Lido = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    constructor(address _lido, address _asset, address _config) PEUSDVault(_asset, _config) {
        lido = ILido(_lido);
    }

    function depositEtherToMint(uint256 mintAmount) external payable override {
        require(msg.value >= 1 ether, "DNL");
        uint256 sharesAmount = lido.submit{value: msg.value}(address(configurator));
        require(sharesAmount != 0, "ZERO_DEPOSIT");
        lido.approve(address(collateralAsset), msg.value);
        uint256 wstETHAmount = IWstETH(address(collateralAsset)).wrap(msg.value);
        depositedAsset[msg.sender] += wstETHAmount;
        if (mintAmount > 0) {
            _mintPeUSD(msg.sender, msg.sender, mintAmount, getAssetPrice());
        }
        emit DepositEther(msg.sender, address(collateralAsset), msg.value,wstETHAmount, block.timestamp);
    }

    function getAssetPrice() public override returns (uint256) {
        return (_etherPrice() * IWstETH(address(collateralAsset)).stEthPerToken()) / 1e18;
    }
    function getAsset2EtherExchangeRate() external view override returns (uint256) {
        return IWstETH(address(collateralAsset)).stEthPerToken();
    }
}