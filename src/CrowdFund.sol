// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
// 1. Import Ownable untuk fitur Admin
import "@openzeppelin/contracts/access/Ownable.sol";

// 2. Tambahkan 'Ownable' di sini
contract CrowdFund is ReentrancyGuard, Ownable {
    IERC20 public donationToken;

    struct Campaign {
        address owner; // Pemilik Proyek (User)
        uint256 targetAmount;
        uint256 deadline;
        uint256 amountCollected;
        bool claimed;
    }

    mapping(uint256 => Campaign) public campaigns;
    uint256 public numberOfCampaigns = 0;

    event CampaignCreated(uint256 indexed id, address indexed owner, uint256 target, uint256 deadline);
    event DonationReceived(uint256 indexed id, address indexed donor, uint256 amount);
    event FundsClaimed(uint256 indexed id, address indexed owner, uint256 amount);

    // 3. Constructor inisialisasi Admin
    constructor(address _tokenAddress) Ownable(msg.sender) {
        // Alamat IDRX di Base Mainnet
        donationToken = IERC20(_tokenAddress);
    }

    // 4. Perubahan Utama di Fungsi Create
    function createCampaign(
        address _beneficiary, // Alamat Wallet User (Pemilik Proyek)
        uint256 _targetAmount,
        uint256 _durationInDays
    )
        public
        onlyOwner
    {
        // HANYA ADMIN YANG BISA PANGGIL

        require(_targetAmount > 0, "Target 0");
        require(_durationInDays > 0, "Durasi 0");
        require(_beneficiary != address(0), "Alamat tidak valid");

        uint256 campaignId = numberOfCampaigns;
        uint256 deadlineDate = block.timestamp + (_durationInDays * 1 days);

        Campaign storage campaign = campaigns[campaignId];

        // Pemiliknya adalah Beneficiary, BUKAN msg.sender (Admin)
        campaign.owner = _beneficiary;

        campaign.targetAmount = _targetAmount;
        campaign.deadline = deadlineDate;
        campaign.amountCollected = 0;
        campaign.claimed = false;

        numberOfCampaigns++;

        emit CampaignCreated(campaignId, _beneficiary, _targetAmount, deadlineDate);
    }

    // Fungsi Donate tetap sama (Siapapun bisa donasi)
    function donateToCampaign(uint256 _id, uint256 _amount) public nonReentrant {
        Campaign storage campaign = campaigns[_id];
        require(block.timestamp < campaign.deadline, "Kampanye berakhir");
        require(_amount > 0, "Nominal 0");

        bool success = donationToken.transferFrom(msg.sender, address(this), _amount);
        require(success, "Gagal transfer token");

        campaign.amountCollected += _amount;
        emit DonationReceived(_id, msg.sender, _amount);
    }

    // Fungsi Withdraw tetap sama (Hanya Beneficiary yang bisa tarik)
    function withdraw(uint256 _id) public nonReentrant {
        Campaign storage campaign = campaigns[_id];

        // Pengecekan: Yang tarik harus User asli, bukan Admin
        require(msg.sender == campaign.owner, "Bukan pemilik asli");
        require(!campaign.claimed, "Sudah ditarik");

        uint256 collected = campaign.amountCollected;
        campaign.claimed = true;
        campaign.amountCollected = 0;

        bool success = donationToken.transfer(campaign.owner, collected);
        require(success, "Gagal transfer token");

        emit FundsClaimed(_id, msg.sender, collected);
    }

    function getCampaignInfo(uint256 _id) public view returns (Campaign memory) {
        return campaigns[_id];
    }
}
