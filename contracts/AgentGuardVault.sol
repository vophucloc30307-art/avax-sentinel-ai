// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AgentGuardVault V2 (Enterprise Edition)
 * @notice Autonomous AI Treasury & Transaction Firewall on Avalanche
 * @dev Upgraded Features:
 *      1. Cryptographic EIP-712 Typed Data Oracle Attestation (Zero-Trust AI Oracle).
 *      2. x402 Micropayment Protocol Rail integration for AI Security-as-a-Service.
 *      3. Avalanche Interchain Messaging (ICM) / Cross-L1 Circuit Breaker Hook.
 *      4. Rolling 24-hour spending velocity limits & granular protocol whitelisting.
 * @author Team CTST (Vo Phuc Loc - Lead, Nguyen Xuan Nghi)
 * @institution HCMUS - VNUHCM (Data Science Year 2)
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract AgentGuardVault {
    // --- EIP-712 Constants ---
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public constant RISK_ASSESSMENT_TYPEHASH = keccak256(
        "RiskAssessment(address target,address token,uint256 amount,uint256 riskScore,uint256 nonce,uint256 deadline)"
    );

    // --- State Variables ---
    address public owner;
    address public aiAgentSigner;
    address public aiRiskOracle;

    bool public circuitBreakerActive;
    uint256 public constant MAX_RISK_THRESHOLD = 65; // Scores > 65 are blocked
    uint256 public constant CRITICAL_FREEZE_THRESHOLD = 90; // Scores >= 90 freeze vault

    // Velocity & Caps
    uint256 public maxSingleTxLimit;
    uint256 public dailySpendingLimit;
    uint256 public currentDaySpent;
    uint256 public lastDayResetTimestamp;

    // x402 Micropayment Rail (Fee charged per third-party audit API call in USDC)
    uint256 public auditFeeUSDC; 
    address public usdcToken;
    uint256 public totalAuditFeesCollected;

    // Nonces for EIP-712 replay protection
    mapping(address => uint256) public nonces;

    // Whitelists
    mapping(address => bool) public whitelistedProtocols;
    mapping(address => bool) public supportedTokens;

    // --- Events ---
    event DepositReceived(address indexed sender, address indexed token, uint256 amount);
    event AgentActionExecuted(
        address indexed targetProtocol, 
        address indexed token, 
        uint256 amount, 
        uint256 riskScore,
        string rationale
    );
    event ActionBlockedByPolicy(
        address indexed targetProtocol, 
        uint256 amount, 
        uint256 riskScore, 
        string reason
    );
    event CircuitBreakerTriggered(address indexed triggeredBy, string reason);
    event CircuitBreakerReset(address indexed resetBy);
    event PolicyUpdated(uint256 maxSingleTxLimit, uint256 dailySpendingLimit);
    event ProtocolWhitelisted(address indexed protocol, bool status);
    event AuditFeePaid(address indexed client, uint256 feeAmount);
    event CrossChainAlertBroadcasted(bytes32 indexed messageId, string reason);

    // --- Modifiers ---
    modifier onlyOwner() {
        require(msg.sender == owner, "AgentGuardVault: caller is not owner");
        _;
    }

    modifier onlyAuthorizedAgent() {
        require(
            msg.sender == aiAgentSigner || msg.sender == owner, 
            "AgentGuardVault: caller is not authorized agent"
        );
        _;
    }

    modifier whenNotFrozen() {
        require(!circuitBreakerActive, "AgentGuardVault: Circuit breaker active, funds frozen!");
        _;
    }

    constructor(
        address _aiAgentSigner,
        address _aiRiskOracle,
        uint256 _maxSingleTxLimit,
        uint256 _dailySpendingLimit,
        address _usdcToken,
        uint256 _auditFeeUSDC
    ) {
        owner = msg.sender;
        aiAgentSigner = _aiAgentSigner;
        aiRiskOracle = _aiRiskOracle;
        maxSingleTxLimit = _maxSingleTxLimit;
        dailySpendingLimit = _dailySpendingLimit;
        usdcToken = _usdcToken;
        auditFeeUSDC = _auditFeeUSDC;
        lastDayResetTimestamp = block.timestamp;

        // Build EIP-712 Domain Separator for Avalanche
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("AvaxSentinelVault")),
                keccak256(bytes("2.0")),
                block.chainid,
                address(this)
            )
        );
    }

    // --- Deposit ---
    function deposit(address token, uint256 amount) external whenNotFrozen {
        require(amount > 0, "Deposit: amount must be > 0");
        require(supportedTokens[token], "Deposit: token not supported");
        
        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        require(success, "Deposit: transfer failed");

        emit DepositReceived(msg.sender, token, amount);
    }

    // --- Enterprise Action Execution with EIP-712 Oracle Verification ---
    /**
     * @notice Executes an action requested by the AI Agent ONLY if cryptographically
     *         verified and signed by the off-chain AI Risk Engine (Zero-Trust).
     */
    function executeGuardedAction(
        address targetProtocol,
        address token,
        uint256 amount,
        bytes calldata targetCalldata,
        uint256 riskScore,
        uint256 deadline,
        bytes calldata oracleSignature,
        string calldata rationale
    ) external onlyAuthorizedAgent whenNotFrozen returns (bytes memory) {
        require(block.timestamp <= deadline, "Execution: Oracle signature expired");

        // 1. Verify EIP-712 Cryptographic Signature from AI Risk Oracle
        bytes32 structHash = keccak256(
            abi.encode(
                RISK_ASSESSMENT_TYPEHASH,
                targetProtocol,
                token,
                amount,
                riskScore,
                nonces[msg.sender]++,
                deadline
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address recoveredSigner = recoverSigner(digest, oracleSignature);
        require(recoveredSigner == aiRiskOracle, "Execution: Invalid AI Risk Oracle signature");

        // 2. Velocity Limit: Reset rolling 24h period
        if (block.timestamp >= lastDayResetTimestamp + 1 days) {
            currentDaySpent = 0;
            lastDayResetTimestamp = block.timestamp;
        }

        // 3. Policy: Target Whitelist Check
        if (!whitelistedProtocols[targetProtocol]) {
            emit ActionBlockedByPolicy(targetProtocol, amount, riskScore, "PROTOCOL_NOT_WHITELISTED");
            revert("Policy: target protocol not in whitelist");
        }

        // 4. Policy: Single Transaction Cap
        if (amount > maxSingleTxLimit) {
            emit ActionBlockedByPolicy(targetProtocol, amount, riskScore, "SINGLE_TX_LIMIT_EXCEEDED");
            revert("Policy: exceeds max single transaction limit");
        }

        // 5. Policy: Daily Velocity Cap
        if (currentDaySpent + amount > dailySpendingLimit) {
            emit ActionBlockedByPolicy(targetProtocol, amount, riskScore, "DAILY_SPENDING_LIMIT_EXCEEDED");
            revert("Policy: exceeds 24-hour daily spending cap");
        }

        // 6. ML Risk Score Verification & Automated Circuit Breaker
        if (riskScore > MAX_RISK_THRESHOLD) {
            if (riskScore >= CRITICAL_FREEZE_THRESHOLD) {
                circuitBreakerActive = true;
                emit CircuitBreakerTriggered(msg.sender, "CRITICAL_ANOMALOUS_RISK_DETECTED");
                broadcastCrossChainFreeze("ANOMALOUS_ATTACK_MITIGATION");
            }
            emit ActionBlockedByPolicy(targetProtocol, amount, riskScore, "AI_RISK_SCORE_TOO_HIGH");
            revert("Policy: transaction flagged as high risk by AI Sentinel Engine");
        }

        // 7. Execution Phase
        currentDaySpent += amount;

        if (amount > 0 && token != address(0)) {
            IERC20(token).transfer(targetProtocol, amount);
        }

        (bool success, bytes memory result) = targetProtocol.call(targetCalldata);
        require(success, "Execution: external call failed");

        emit AgentActionExecuted(targetProtocol, token, amount, riskScore, rationale);
        return result;
    }

    // --- x402 Micropayment Rail (HTTP 402 Pay-per-Audit Integration) ---
    /**
     * @notice Allows any external dApp/agent to pay a micro-fee in USDC to receive
     *         on-chain risk attestation or register a custom policy.
     */
    function payAuditFee(uint256 amount) external whenNotFrozen {
        require(amount >= auditFeeUSDC, "x402: Insufficient audit fee");
        require(usdcToken != address(0), "x402: USDC token not configured");

        bool success = IERC20(usdcToken).transferFrom(msg.sender, address(this), amount);
        require(success, "x402: Payment failed");

        totalAuditFeesCollected += amount;
        emit AuditFeePaid(msg.sender, amount);
    }

    // --- Avalanche Interchain Messaging (ICM) Hook ---
    /**
     * @notice Emits telemetry signal to trigger cross-L1 / cross-subnet freeze
     *         via Avalanche Teleporter / ICM when an anomaly occurs.
     */
    function broadcastCrossChainFreeze(string memory reason) internal {
        bytes32 messageId = keccak256(abi.encodePacked(block.timestamp, block.prevrandao, reason));
        emit CrossChainAlertBroadcasted(messageId, reason);
    }

    // --- Emergency & Governance ---
    function triggerEmergencyShutdown(string calldata reason) external {
        require(msg.sender == owner || msg.sender == aiRiskOracle, "Unauthorized shutdown trigger");
        circuitBreakerActive = true;
        emit CircuitBreakerTriggered(msg.sender, reason);
        broadcastCrossChainFreeze(reason);
    }

    function resetCircuitBreaker() external onlyOwner {
        circuitBreakerActive = false;
        emit CircuitBreakerReset(msg.sender);
    }

    function updatePolicies(uint256 _maxSingleTx, uint256 _dailyLimit) external onlyOwner {
        maxSingleTxLimit = _maxSingleTx;
        dailySpendingLimit = _dailyLimit;
        emit PolicyUpdated(_maxSingleTx, _dailyLimit);
    }

    function setWhitelistedProtocol(address protocol, bool status) external onlyOwner {
        whitelistedProtocols[protocol] = status;
        emit ProtocolWhitelisted(protocol, status);
    }

    function setSupportedToken(address token, bool status) external onlyOwner {
        supportedTokens[token] = status;
    }

    function setAuditFee(uint256 _newFee) external onlyOwner {
        auditFeeUSDC = _newFee;
    }

    function setAgentSigner(address _newAgent) external onlyOwner {
        aiAgentSigner = _newAgent;
    }

    function setRiskOracle(address _newOracle) external onlyOwner {
        aiRiskOracle = _newOracle;
    }

    // --- Cryptographic Helper ---
    function recoverSigner(bytes32 _digest, bytes memory _signature) internal pure returns (address) {
        require(_signature.length == 65, "Invalid signature length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := mload(add(_signature, 32))
            s := mload(add(_signature, 64))
            v := byte(0, mload(add(_signature, 96)))
        }
        if (v < 27) {
            v += 27;
        }
        return ecrecover(_digest, v, r, s);
    }

    // Fallback & Balance views
    function getRemainingDailyCap() external view returns (uint256) {
        if (block.timestamp >= lastDayResetTimestamp + 1 days) {
            return dailySpendingLimit;
        }
        if (currentDaySpent >= dailySpendingLimit) {
            return 0;
        }
        return dailySpendingLimit - currentDaySpent;
    }

    receive() external payable {}
}
