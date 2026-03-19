// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./common/IPancake.sol";


interface IStakeContract {
    function updateFeeNodesDL(uint256 amount,uint256 _type) external;
    function getParentUserInfo(address user) external view returns( address my_address, uint256 is_jihuo, uint256 is_jihuo_p,uint256 group_rank2 );
}

contract DLToken is ERC20, Ownable {
    uint256 private  constant TOTAL_SUPPLY = 210000000 * 10**18;
    uint256 private constant MIN_POOL_VALUE = 2_000_000 * 10**18;
    uint256 private constant MIN_POOL_VALUE2 = 1_500_000 * 10**18;
    uint256 public MAX_POOL_VALUE;
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
    address public interactiveContract;
    address public foundationAddress;
    address public pancakePair;
    address public adminAddress;


    // PancakeSwap Router地址（BSC主网）
    address public constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address public constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address public constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    uint256 public lastOpenedBlock;
    uint256 public constant MIN_OPEN_BLOCKS = 5;
    mapping(address => uint256) public lastBuyTime;
    uint256 public coolDownTime = 60;

    // 状态变量
    bool public buyMarketOpen = false;  // 二级市场是否开放
    uint256 public  waitBlocks = 10;

    //twap
    uint256 public constant REQUIRED_OBSERVATIONS = 5;
    uint256[5] public priceObservations;
    uint256 public observationIndex;


    
    IPancakeRouter public pancakeRouter;
    // 用户数据结构
    struct UserInfo {
        uint256 okBuyValue;      // 已经购买的额度
        uint256 allBuyValue;     //允许购买的额度
        uint256 group_rank2;
    }
    // 映射存储
    mapping(address => UserInfo) public users;
    mapping(address => bool) public isExcludedFromTax;

    //uint256[8] private DL_MIN_FEE = [3_000 ether,10_000 ether,30_000 ether,100_000 ether,300_000 ether,1_000_000 ether,3_000_000 ether,10_000_000 ether];
    uint256[8] private DL_TOTAL_FEE = [50 ether,200 ether,1_000 ether,2_000 ether,3_000 ether,5_000 ether,10_000 ether,20_000 ether]; // 单位：USDT (1e18 wei)
    uint256[8] private DL_TOTAL_FEE2 = [500 ether,1_000 ether,2_000 ether,3_000 ether,5_000 ether,5_000 ether,10_000 ether,20_000 ether];
    
    uint256 public BNB_PRICE;
    uint256 public BURN_AMOUNT;//已销毁
    uint256 public AMOUNT_STOP = 2_000_000 ether;//流通阈值
    uint256 public DEL_TIME = block.timestamp;
    
    // 事件
    event InteractiveContractUpdated(address indexed oldContract, address indexed newContract);
    event FounderAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event FoundationAddressUpdated(address indexed oldAddress, address indexed newAddress);
    event AdminAddressUpdated(address indexed oldAddress, address indexed newAddress);

    event DLRecycled(uint256 amount);//OK
    event ProfitTaxDistributed(uint256 toFounder, uint256 toFoundation);//ok

    event BuyMarketStatusChanged(bool status);//ok
    event BuyRecorded(address indexed user, uint256 amount, uint256 value);

    //event Debug(address sender, address recipient, uint256 amount, string context);

    constructor() 
        ERC20("DL TOKEN", "DL")
        Ownable(msg.sender)
    {
        
        pancakePair = IPancakeFactory(IPancakeRouter(PANCAKE_ROUTER).factory()).createPair(address(this), WBNB);
        _mint(msg.sender, TOTAL_SUPPLY);
        
        pancakeRouter = IPancakeRouter(PANCAKE_ROUTER);
        _approve(address(this), PANCAKE_ROUTER, type(uint256).max); // 授权 Router
        _approve(pancakePair, PANCAKE_ROUTER, type(uint256).max);


        BNB_PRICE = getBNBPrice();
        
        isExcludedFromTax[msg.sender] = true;
        isExcludedFromTax[address(this)] = true;
        adminAddress = msg.sender;
    }
    
    function transfer(address recipient, uint256 amount) public override  returns (bool) {
        uint256 burnAmount = 0;
        if (msg.sender == pancakePair || recipient == pancakePair) {
            _updateTWAP();
            BNB_PRICE = getBNBPrice();
            (amount,burnAmount) = _calculateAndProcessTax(msg.sender, recipient, amount);
        }
        bool success = super.transfer(recipient, amount);
        if(burnAmount > 0){
            _recycleDL(burnAmount, BURN_ADDRESS);
        }

        return success;
        //return super.transfer(recipient, amount);
    }
    
    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        uint256 burnAmount = 0;
        if (sender == pancakePair || recipient == pancakePair) {
            _updateTWAP();
            BNB_PRICE = getBNBPrice();
            (amount,burnAmount) = _calculateAndProcessTax(sender, recipient, amount);
        }
        bool success = super.transferFrom(sender, recipient, amount);
        if(burnAmount > 0){
            _recycleDL(burnAmount, BURN_ADDRESS);
        }

        return success;
        //return super.transferFrom(sender, recipient, amount);
    }
    
    function _calculateAndProcessTax(address sender, address recipient, uint256 amount) internal returns (uint256, uint256) {
        
        if (sender == adminAddress || recipient == adminAddress) {
            return (amount,0);
        }
        // bool isLiquidityOperation = (msg.sender == PANCAKE_ROUTER);
        // if (isLiquidityOperation) {
        //     return (amount,0);
        // }

        bool isSell = (recipient == pancakePair && sender != interactiveContract);
        bool isBuy = (sender == pancakePair && recipient != interactiveContract);
        //emit  Debug(sender, recipient, 1, "is buy==1");

        if (isSell) {
            if(isExcludedFromTax[sender]){
                return (amount,0);
            }
            uint256 profit = amount;
            uint256 taxAmount = profit * 50 / 1000;  // 5%的总税率
            uint256 founderTax = profit * 25 / 1000;  // 2.5%转入合约，联创股东
            uint256 foundationTax = profit * 25 / 1000;  // 2.5%转入基金会
            
            if (founderTax > 0 && interactiveContract != address(0)) {
                _transfer(sender, interactiveContract, founderTax);
                try IStakeContract(interactiveContract).updateFeeNodesDL(founderTax,2) {}
                catch {}
            }

            if (foundationTax > 0 && foundationAddress != address(0)) {
                _transfer(sender, foundationAddress, foundationTax);
            }
            
            //_recycleDL(amount - taxAmount,BURN_ADDRESS);
            //emit ProfitTaxDistributed(founderTax, foundationTax);

            uint256 sell_amount = amount - taxAmount;
            return (sell_amount,sell_amount);
            
        }else if (isBuy) {
            uint256 my_buy_amount = _handleBuyTransaction(recipient, amount);
            return (my_buy_amount,0);
        }
        return (amount,0);
    }

    receive() external payable {}
    
    function _recordBuyValue(address user, uint256 buyAmount) internal {
        uint256 currentPrice = getCurrentPrice();
        uint256 buyValue = (buyAmount * currentPrice) / 10**18;
        users[user].okBuyValue += buyValue;
        emit BuyRecorded(user, buyAmount, buyValue);
    }

    function _handleBuyTransaction(address recipient, uint256 amount) internal returns (uint256) {
        if(isExcludedFromTax[recipient]){
            return amount;
        }
        BNB_PRICE =   getBNBPrice();
        //uint256 poolValue = _calculatePoolValue(BNB_PRICE); //池子价值
        uint256 poolValue = getTWAPValue();
        
        if(poolValue > MAX_POOL_VALUE){
            MAX_POOL_VALUE  =   poolValue;
        }

        bool isCurrentlyQualified = false;
        if(poolValue >= MIN_POOL_VALUE){
            isCurrentlyQualified = true;
        }else if(MAX_POOL_VALUE >= MIN_POOL_VALUE && poolValue >= MIN_POOL_VALUE2){
            isCurrentlyQualified = true;
        }
        
        bool shouldBeOpen = false;
        if (isCurrentlyQualified) {
            if(lastOpenedBlock == 0){
                lastOpenedBlock = block.number;
            }
            if((block.number >= lastOpenedBlock + waitBlocks)){
                shouldBeOpen    =   true;
            }
        } else {
            lastOpenedBlock = 0;
            shouldBeOpen = false;
        }

        if (!isExcludedFromTax[recipient] && recipient.code.length == 0) {
            require(block.timestamp >= lastBuyTime[recipient] + coolDownTime, "Please wait for cooldown");
            lastBuyTime[recipient] = block.timestamp;
        }
        
        if (buyMarketOpen != shouldBeOpen) {
            buyMarketOpen = shouldBeOpen;
            
            emit BuyMarketStatusChanged(shouldBeOpen);
            //emit Debug(sender, recipient, poolValue, "Market status changed due to pool value");
        }

        uint256 dlPrice = getCurrentPrice(); //1 dl = 0.01bnb wei
        //uint256 buyValueUSD = amount * dlPrice * BNB_PRICE / 10**36;

        uint256 bnbValue = (amount * dlPrice) / 10**18;
        uint256 buyValueUSD = (bnbValue * BNB_PRICE) / 10**18;

        if(buyMarketOpen == true){
            //最大购买量

            uint256 max_buy_val = DL_TOTAL_FEE2[2];
            require(buyValueUSD < max_buy_val, "Exceeds max buy limit");
            //users[recipient].okBuyValue += buyValueUSD;

        }else{
            //按额度

            require(buyValueUSD > 0, "Price too low"); // 防止除零或精度丢失
            (, , ,uint256 group_rank2) = IStakeContract(interactiveContract).getParentUserInfo(recipient);
            //emit  Debug(sender, recipient, group_rank2, "my user rank2 == 4");
            require(group_rank2 > 0 && group_rank2 < 9, "Insufficient quota");
            
            users[recipient].group_rank2 = group_rank2;

            uint256 index = group_rank2 - 1;

            uint256 my_amount = DL_TOTAL_FEE[index];
            if(poolValue >= MIN_POOL_VALUE2){
                my_amount = DL_TOTAL_FEE2[index];
            }
            users[recipient].allBuyValue = my_amount;
            uint256 ok_my_amount_u = my_amount > users[recipient].okBuyValue ? my_amount - users[recipient].okBuyValue : 0; //u
            require(buyValueUSD <= ok_my_amount_u,"Insufficient quota");
            
            users[recipient].okBuyValue += buyValueUSD;
            emit BuyRecorded(recipient, amount, buyValueUSD);
        }

        return amount;
    }

    function getCurrentPrice() public view returns (uint256) {
        (uint256 reserveDL, uint256 reserveBNB) = getReserves();
        if (reserveDL == 0 || reserveBNB == 0) {
            return 0;
        }
        return (reserveBNB * 10**18) / reserveDL;
    }
    
    function _calculatePoolValue(uint256 bnbPriceInUSDT) private  view returns (uint256) {
        (uint256 reserveDL, uint256 reserveBNB) = getReserves();
        if (reserveDL == 0 || reserveBNB == 0) return 0;
        
        
        uint256 bnbValue = (reserveBNB * bnbPriceInUSDT) / 10**18;
        return bnbValue;    //U wei
    }
    
    function getReserves() public view returns (uint256 reserveDL, uint256 reserveBNB) {
        try IPancakePair(pancakePair).getReserves() returns (uint112 reserve0, uint112 reserve1, uint32) {
            address token0 = IPancakePair(pancakePair).token0();
            
            if (token0 == address(this)) {
                return (uint256(reserve0), uint256(reserve1));
            } else {
                return (uint256(reserve1), uint256(reserve0));
            }
        } catch {
            return (0, 0);
        }
    }
    
    function _updateTWAP() internal {
        uint256 currentPoolValue = _calculatePoolValue(BNB_PRICE);

        uint256 index = observationIndex % 5;
        priceObservations[index] = currentPoolValue;
        observationIndex++;
    }
    
    function getTWAPValue() public view returns (uint256) {
        uint256 sum = 0;
        uint256 count = 0;

        for (uint256 i = 0; i < 5; i++) {
            if (priceObservations[i] != 0) {
                sum += priceObservations[i];
                count++;
            }
        }

        if (count == 0) return 0;
        return sum / count;
    }



    function _recycleDL(uint256 amount, address to) private    {
        //require(msg.sender == interactiveContract, "Only interactive contract allowed");
        if(amount > 0){
            address pair = pancakePair;
            require(balanceOf(pair) >= amount, "Insufficient DL in pool");
            
            super._transfer(pair, to, amount);
            IPancakePair(pair).sync();
            BURN_AMOUNT += amount;
            emit DLRecycled(amount);
        }
    }
    
    function delDl() external {
        require(msg.sender == interactiveContract || msg.sender == adminAddress,"no permission");
        (uint256 reserveDL,) = getReserves();
        if(reserveDL > AMOUNT_STOP){
            uint256 del_day = (block.timestamp - DEL_TIME)/ 1 days;
            if(del_day > 0){
                uint256 amount_off = (reserveDL * 5)/1000;
                if(amount_off > 0){
                    DEL_TIME = block.timestamp;
                    //BURN_AMOUNT += amount_off;
                    _recycleDL(amount_off, BURN_ADDRESS);
                }
            }
        }
    }
    
    function getBNBPrice() public view  returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = USDT;
        
        try IPancakeRouter(PANCAKE_ROUTER).getAmountsOut(10**18, path) returns (uint256[] memory amounts) {
            return amounts[1];
        } catch {
            return BNB_PRICE;
        }

        // uint256[] memory amounts = IPancakeRouter(PANCAKE_ROUTER).getAmountsOut(10**18, path);
        // return amounts[1];
    }
    
    //=========
    function setInteractiveContract(address _op) external  {
        require(msg.sender == adminAddress || msg.sender == owner() || msg.sender == interactiveContract,"sender is wrong");
        require(_op != address(0), "Cannot set to zero address");
        address oldContract = interactiveContract;
        interactiveContract = _op;

        isExcludedFromTax[oldContract] = false;
        isExcludedFromTax[_op] = true;
        emit InteractiveContractUpdated(oldContract, _op);
    }
    function setFoundationAddress(address _op) external  {
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        require(_op != address(0), "Cannot set to zero address");
        address oldAddress = foundationAddress;
        foundationAddress = _op;

        isExcludedFromTax[oldAddress] = false;
        isExcludedFromTax[_op] = true;

        emit FoundationAddressUpdated(oldAddress, _op);
    }
    

    function setAmountStop(uint256 _amount) external{
        require(msg.sender == owner() || msg.sender == adminAddress,"no permission");
        require(_amount > 0,"amount is wrong");
        AMOUNT_STOP = _amount;
    }

    function setAdminAddress(address _op) external  {
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        require(_op != address(0), "Cannot set to zero address");
        address oldAddress = adminAddress;
        adminAddress = _op;

        isExcludedFromTax[oldAddress] = false;
        isExcludedFromTax[_op] = true;

        emit AdminAddressUpdated(oldAddress, _op);
    }
    
    function setWaitBlocks(uint256 _waitBlocks) external  {
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        require(_waitBlocks > 0, "Wait blocks must be positive");
        waitBlocks = _waitBlocks;
    }

    function setPancakePair(address _op) external onlyOwner {
        require(_op != address(0), "Cannot set to zero address");

        pancakePair = _op;
    }

    function getUserInfo(address user) external view returns (uint256 allBuyValue, uint256 rank) {

        (, , ,uint256 group_rank2) = IStakeContract(interactiveContract).getParentUserInfo(user);
        uint256 fee = group_rank2 > 0 ? DL_TOTAL_FEE[group_rank2-1] :0;
        return (fee,group_rank2);
    }
}
