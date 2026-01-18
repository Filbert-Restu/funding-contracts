// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract CrowdFund is ReentrancyGuard, Ownable {
    IERC20 public donationToken;

    // --- KONFIGURASI ---
    // 1. Minimal Donasi 10.000 (Asumsi IDRX punya 18 desimal)
    uint256 public constant MIN_DONATION = 10_000 * 10 ** 18;

    // 2. Batas Waktu Refund (1 Bulan = 30 Hari setelah deadline)
    uint256 public constant REFUND_DELAY = 30 days;

    // 3. Batas Waktu Admin Sweep (3 Bulan setelah masa refund dimulai)
    uint256 public constant SWEEP_DELAY = 90 days;

    // 4. Threshold Voting (40%)
    uint256 public constant VOTE_THRESHOLD_PERCENT = 40;

    // 5. Fee Admin (Misal 5%)
    uint256 public platformFeePercent = 5;

    struct Campaign {
        address owner;
        uint256 targetAmount;
        uint256 deadline;
        uint256 amountCollected;
        uint totalRefunded; // Total uang yang sudah di-refund ke donatur
        uint256 totalVotesWeight; // Total uang dari donatur yang setuju withdraw
        bool claimed;
        bool refundActive;
        bool swept;
    }

    mapping(uint256 => Campaign) public campaigns;

    // Mapping: ID Campaign => Wallet Donatur => Jumlah Donasi
    mapping(uint256 => mapping(address => uint256)) public contributions;

    // Mapping: ID Campaign => Wallet Donatur => Sudah Vote?
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    uint256 public numberOfCampaigns = 0;

    // Events
    event CampaignCreated(uint256 indexed id, address indexed owner, uint256 target, uint256 deadline);
    event DonationReceived(uint256 indexed id, address indexed donor, uint256 amount);
    event VoteCast(uint256 indexed id, address indexed donor, uint256 weight);
    event FundsClaimed(uint256 indexed id, address indexed owner, uint256 amount, uint256 fee);
    event RefundClaimed(uint256 indexed id, address indexed donor, uint256 amount);
    event FundsSwept(uint256 indexed id, uint256 amount);

    constructor(address _tokenAddress) Ownable(msg.sender) {
        donationToken = IERC20(_tokenAddress);
    }

    // Fungsi Admin untuk set fee (Max 20% agar fair)
    function setPlatformFee(uint256 _percent) external onlyOwner {
        require(_percent <= 20, "Fee terlalu tinggi");
        platformFeePercent = _percent;
    }

    function createCampaign(address _beneficiary, uint256 _targetAmount, uint256 _durationInDays) public onlyOwner {
        require(_targetAmount > 0, "Target 0");
        require(_durationInDays > 0, "Durasi 0");
        require(_beneficiary != address(0), "Alamat tidak valid");

        uint256 campaignId = numberOfCampaigns;
        uint256 deadlineDate = block.timestamp + (_durationInDays * 1 days);

        Campaign storage campaign = campaigns[campaignId];
        campaign.owner = _beneficiary;
        campaign.targetAmount = _targetAmount;
        campaign.deadline = deadlineDate;
        campaign.amountCollected = 0;
        campaign.totalVotesWeight = 0;
        campaign.claimed = false;
        campaign.refundActive = false;

        numberOfCampaigns++;
        emit CampaignCreated(campaignId, _beneficiary, _targetAmount, deadlineDate);
    }

    // --- LOGIKA 1: DONASI MINIMAL 10K ---
    function donateToCampaign(uint256 _id, uint256 _amount) public nonReentrant {
        Campaign storage campaign = campaigns[_id];
        require(block.timestamp < campaign.deadline, "Kampanye berakhir");

        // Syarat Minimal
        require(_amount >= MIN_DONATION, "Minimal donasi 10.000 IDRX");

        bool success = donationToken.transferFrom(msg.sender, address(this), _amount);
        require(success, "Gagal transfer token");

        campaign.amountCollected += _amount;

        // Catat kontribusi user untuk refund & voting
        contributions[_id][msg.sender] += _amount;

        emit DonationReceived(_id, msg.sender, _amount);
    }

    // --- LOGIKA 2: REFUND OLEH DONATUR ---
    // Jika Creator tidak menarik dana 1 bulan setelah deadline
    function claimRefund(uint256 _id) external nonReentrant {
        Campaign storage campaign = campaigns[_id];

        // 1. CHECKS (Validasi)
        require(!campaign.claimed, "Dana sudah ditarik creator");
        require(block.timestamp > (campaign.deadline + REFUND_DELAY), "Belum masa refund");

        uint256 userContribution = contributions[_id][msg.sender];
        require(userContribution > 0, "Saldo 0");

        // 2. EFFECTS (Update Data Internal DULU)
        // Reset saldo user ke 0
        contributions[_id][msg.sender] = 0;

        // Update total refund untuk keperluan Admin Sweep nanti
        campaign.totalRefunded += userContribution;

        // Tandai status refund aktif
        campaign.refundActive = true;

        // 3. INTERACTIONS (Transfer Uang)
        // Lakukan transfer HANYA SATU KALI di akhir
        bool success = donationToken.transfer(msg.sender, userContribution);
        require(success, "Gagal refund");

        emit RefundClaimed(_id, msg.sender, userContribution);
    }

    // --- LOGIKA 3: ADMIN SWEEP ---
    function adminSweep(uint256 _id) external onlyOwner nonReentrant {
        Campaign storage campaign = campaigns[_id];

        // 1. CHECKS (Validasi)
        require(!campaign.claimed, "Dana sudah ditarik/disapu");

        // Hitung Waktu Sweep: Deadline + 30 Hari (Refund) + 90 Hari (Tunggu)
        uint256 sweepTime = campaign.deadline + REFUND_DELAY + SWEEP_DELAY;
        require(block.timestamp > sweepTime, "Belum masa sweep");

        // 2. MATH (Hitung Sisa Saldo Spesifik)
        uint256 remainingFunds = campaign.amountCollected - campaign.totalRefunded;

        require(remainingFunds > 0, "Tidak ada sisa dana");

        // 3. EFFECTS (Update Data Dulu)
        // Menandai claimed = true akan otomatis mematikan fitur 'claimRefund' bagi user yang telat.
        campaign.claimed = true;

        // 4. INTERACTIONS (Transfer)
        bool success = donationToken.transfer(owner(), remainingFunds);
        require(success, "Sweep gagal");

        emit FundsSwept(_id, remainingFunds);
    }

    // --- LOGIKA 4: VOTING DONATUR (Anti-Scam) ---
    // Donatur harus panggil ini jika setuju dana ditarik
    function voteForWithdrawal(uint256 _id) public {
        Campaign storage campaign = campaigns[_id];
        require(contributions[_id][msg.sender] > 0, "Bukan donatur");
        require(!hasVoted[_id][msg.sender], "Sudah vote");
        require(!campaign.claimed, "Kampanye sudah selesai");

        // Vote berbobot sesuai jumlah uang (Weighted Vote)
        uint256 weight = contributions[_id][msg.sender];
        campaign.totalVotesWeight += weight;
        hasVoted[_id][msg.sender] = true;

        emit VoteCast(_id, msg.sender, weight);
    }

    // --- LOGIKA 5 & 4: WITHDRAW DENGAN SYARAT VOTE & FEE ---
    function withdraw(uint256 _id) public nonReentrant {
        Campaign storage campaign = campaigns[_id];
        require(msg.sender == campaign.owner, "Bukan pemilik");
        require(!campaign.claimed, "Sudah ditarik");
        require(!campaign.refundActive, "Masa refund aktif");

        // Cek Syarat Vote 40%
        // (Total Vote * 100) / Total Terkumpul >= 40
        uint256 votePercentage = (campaign.totalVotesWeight * 100) / campaign.amountCollected;
        require(votePercentage >= VOTE_THRESHOLD_PERCENT, "Vote donatur belum tembus 40%");

        // Hitung Fee Admin
        uint256 totalFunds = campaign.amountCollected;
        uint256 feeAmount = (totalFunds * platformFeePercent) / 100;
        uint256 creatorAmount = totalFunds - feeAmount;

        campaign.claimed = true;
        campaign.amountCollected = 0;

        // Transfer Fee ke Admin
        if (feeAmount > 0) {
            require(donationToken.transfer(owner(), feeAmount), "Gagal fee");
        }

        // Transfer Sisa ke Creator
        require(donationToken.transfer(campaign.owner, creatorAmount), "Gagal withdraw");

        emit FundsClaimed(_id, msg.sender, creatorAmount, feeAmount);
    }
}
