// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Ini kontrak Token Rupiah Palsu untuk Testnet
contract MockIDRX is ERC20 {
    constructor() ERC20("Rupiah Token", "IDRX") {
        // Cetak 1 Milyar IDRX ke dompet pembuat kontrak saat deploy
        _mint(msg.sender, 1000000000 * 10**18); 
    }

    // Fungsi agar kita bisa minta uang gratis (Faucet)
    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}