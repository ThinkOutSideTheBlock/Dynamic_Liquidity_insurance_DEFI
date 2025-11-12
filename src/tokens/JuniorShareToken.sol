pragma solidity ^0.8.19;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
contract JuniorShareToken is ERC20, Ownable {
    constructor()
        Ownable(msg.sender)
        ERC20("Dynamic Liquidation Insurance Junior Share", "DLI-J")
    {}
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}
