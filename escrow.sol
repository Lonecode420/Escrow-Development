// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Escrow
 * @author Brian Kelly Ochieng
 * @notice Trustless milestone-based escrow contract
 * @dev Production-ready, single-deal escrow
 */

contract Escrow {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error Unauthorized();
    error InvalidState();
    error InvalidAmount();
    error AlreadyPaid();
    error InvalidMilestone();
    error TransferFailed();

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event Funded(uint256 amount);
    event MilestoneApproved(uint256 indexed index);
    event MilestonePaid(uint256 indexed index, uint256 amount);
    event DisputeRaised(address indexed by);
    event DisputeResolved(uint256 clientAmount, uint256 freelancerAmount);
    event Cancelled();

    /*//////////////////////////////////////////////////////////////
                                TYPES
    //////////////////////////////////////////////////////////////*/
    enum State {
        Created,
        Funded,
        InProgress,
        Disputed,
        Resolved,
        Cancelled
    }

    struct Milestone {
        uint256 amount;
        bool approved;
        bool paid;
    }

    /*//////////////////////////////////////////////////////////////
                              STORAGE
    //////////////////////////////////////////////////////////////*/
    address public immutable client;
    address public immutable freelancer;
    address public immutable arbitrator;

    uint256 public immutable totalAmount;
    State public state;

    Milestone[] public milestones;

    uint256 private locked; // reentrancy guard

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier nonReentrant() {
        require(locked == 0, "REENTRANCY");
        locked = 1;
        _;
        locked = 0;
    }

    modifier onlyClient() {
        if (msg.sender != client) revert Unauthorized();
        _;
    }

    modifier onlyFreelancer() {
        if (msg.sender != freelancer) revert Unauthorized();
        _;
    }

    modifier onlyArbitrator() {
        if (msg.sender != arbitrator) revert Unauthorized();
        _;
    }

    modifier inState(State expected) {
        if (state != expected) revert InvalidState();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    constructor(
        address _client,
        address _freelancer,
        address _arbitrator,
        uint256[] memory milestoneAmounts
    ) {
        require(
            _client != address(0) &&
            _freelancer != address(0) &&
            _arbitrator != address(0),
            "ZERO_ADDRESS"
        );

        client = _client;
        freelancer = _freelancer;
        arbitrator = _arbitrator;

        uint256 sum;
        for (uint256 i = 0; i < milestoneAmounts.length; i++) {
            uint256 amount = milestoneAmounts[i];
            if (amount == 0) revert InvalidAmount();

            milestones.push(Milestone({
                amount: amount,
                approved: false,
                paid: false
            }));

            sum += amount;
        }

        totalAmount = sum;
        state = State.Created;
    }

    /*//////////////////////////////////////////////////////////////
                          CLIENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Fund the escrow with the exact total amount
    function fund() external payable onlyClient inState(State.Created) {
        if (msg.value != totalAmount) revert InvalidAmount();

        state = State.Funded;
        emit Funded(msg.value);
    }

    /// @notice Approve a milestone for payment
    function approveMilestone(uint256 index)
        external
        onlyClient
        inState(State.Funded)
    {
        if (index >= milestones.length) revert InvalidMilestone();

        Milestone storage m = milestones[index];
        if (m.paid) revert AlreadyPaid();

        m.approved = true;
        emit MilestoneApproved(index);
    }

    /// @notice Cancel escrow before work starts
    function cancel()
        external
        onlyClient
        inState(State.Created)
        nonReentrant
    {
        state = State.Cancelled;

        (bool ok, ) = client.call{value: address(this).balance}("");
        if (!ok) revert TransferFailed();

        emit Cancelled();
    }

    /*//////////////////////////////////////////////////////////////
                        FREELANCER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw an approved milestone payment
    function withdraw(uint256 index)
        external
        onlyFreelancer
        nonReentrant
    {
        if (state != State.Funded && state != State.Resolved)
            revert InvalidState();

        if (index >= milestones.length) revert InvalidMilestone();

        Milestone storage m = milestones[index];
        if (!m.approved) revert InvalidState();
        if (m.paid) revert AlreadyPaid();

        m.paid = true;

        (bool ok, ) = freelancer.call{value: m.amount}("");
        if (!ok) revert TransferFailed();

        emit MilestonePaid(index, m.amount);
    }

    /*//////////////////////////////////////////////////////////////
                        DISPUTE RESOLUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Raise a dispute (client or freelancer)
    function raiseDispute() external {
        if (msg.sender != client && msg.sender != freelancer)
            revert Unauthorized();

        if (state != State.Funded) revert InvalidState();

        state = State.Disputed;
        emit DisputeRaised(msg.sender);
    }

    /// @notice Arbitrator resolves dispute by splitting remaining funds
    function resolveDispute(uint256 clientAmount)
        external
        onlyArbitrator
        inState(State.Disputed)
        nonReentrant
    {
        uint256 balance = address(this).balance;
        if (clientAmount > balance) revert InvalidAmount();

        uint256 freelancerAmount = balance - clientAmount;
        state = State.Resolved;

        if (clientAmount > 0) {
            (bool ok1, ) = client.call{value: clientAmount}("");
            if (!ok1) revert TransferFailed();
        }

        if (freelancerAmount > 0) {
            (bool ok2, ) = freelancer.call{value: freelancerAmount}("");
            if (!ok2) revert TransferFailed();
        }

        emit DisputeResolved(clientAmount, freelancerAmount);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function milestoneCount() external view returns (uint256) {
        return milestones.length;
    }
}
