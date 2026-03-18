// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./common/IPancake.sol";


interface IInteractiveContract {
    function recycleDF(uint256 amount) external ;
    function delDl() external ;
    function setInteractiveContract(address _op) external;
}

contract DfStake is Ownable {
    // ===== 地址配置 =====
    address public DFAddress;
    address public DLAddress;
    address public nodeAddress;
    address public operatorAddress;
    address public communityAddress;
    //address public ecologicalAddress;
    address public adminAddress;
    
    address private  constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address private constant PANCAKE_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address private constant WBNB_TOKEN = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant USDT_TOKEN = 0x55d398326f99059fF775485246999027B3197955;
    address private constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;
    
    uint256 public BNB_PRICE;

    uint256[8] private   GROUP_RANK_PER = [7, 13, 18,22,25,28,30,32];
    uint256[8] private  GROUP_RANK_ARR = [10_000 ether, 50_000 ether, 100_000 ether,500_000 ether,1_000_000 ether,5_000_000 ether,10_000_000 ether,30_000_000 ether];
    uint256[8] private  GROUP_RANK_MYFEE = [0.1 ether, 0.1 ether, 0.5 ether,0.5 ether,1 ether,1 ether,1 ether,1 ether];
    
    uint256[8] private DL_MIN_FEE = [3_000 ether,10_000 ether,30_000 ether,100_000 ether,300_000 ether,1_000_000 ether,3_000_000 ether,10_000_000 ether];
    uint256[8] private DL_TOTAL_FEE = [50 ether,200 ether,1_000 ether,2_000 ether,3_000 ether,5_000 ether,10_000 ether,20_000 ether];
    uint256[8] private DL_TOTAL_FEE2 = [500 ether,1_000 ether,2_000 ether,3_000 ether,5_000 ether,5_000 ether,10_000 ether,20_000 ether];

    
    uint256 public feeNodesBnb;
    uint256 public feeNodesDL;
    uint256 public feeNodesDF;
    address[] public nodeUserAddresses;
    //address[] public chiAddress;
    



    uint256 public  max_pool;//最大市值
    uint256 public  max_day_stake_base = 20_000 ether; //每天入场的最大价值$的bnb量
    uint256 public  max_day_stake_in = 50_000 ether;

    

    uint256 public max_stake = 0.5 ether;//最大质押数 BNB
    uint256 public min_stake = 0.1 ether;
    
    uint256 public off_fee_all = 0;
    
    uint256 public online_time;
    uint256 public deepDayIndex;//索引日
    uint256 public currentDayTotalStaked;//今日质押量

    uint256 public is_locked = 0;
    uint256 public locked_time;

    uint256 public constant END_TIME = 1798732800;
    
    // 设置  质押周期
    uint256 public stake_day = 30 days;
    
    
    //IPancakeRouter public pancakeRouter;


    // ===== 用户信息 =====
    struct UserInfo {
        address parent_address;
        uint256 is_jihuo;
        uint256 my_amount;
        uint256 group_rank;
        uint256 group_rank2;
        uint256 nums_zhitui;
        uint256 nums_zhitui_jihuo;
        uint256 nums_group;
        uint256 nums_group_jihuo;
        uint256 total_fee_zhitui;
        uint256 total_fee_group;

        uint256 nums_group_jiedian;
        uint256 add_time;
    }

    // ===== 质押信息 =====
    struct StakeInfo {
        uint256 amount;
        uint256 amountA;
        uint256 startTime;
        uint256 expiryTime;
        uint256 old_amount;

        uint256 lixiAmount;
        uint256 lixiAmountA;
        bool is_end;
        bool isActive;//状态
        uint256 weiyuejin;
    }

    //======节点信息
    struct NodeInfo{
        uint256 nodeAmount;
        uint256 nodeStartTime; 
        uint256 nodeFee; //动态奖金

        uint256 feeBnb;
        uint256 feeDF;
        uint256 feeDL;
    }
    struct NodeFeeArr{
        uint256 feeOk;
        uint256 feeTime;
    }
    uint256 private stakeIn;
    uint256 private stakeOut;
    uint256 private lixiOut;
    uint256 private weiyuejin;
    uint256 private userNums;
    uint256 private userNumsOk;
    

    mapping(address => UserInfo) public users;
    mapping(address => StakeInfo) public stakes;
    mapping(address => NodeInfo) public nodeUsers;
    mapping(address => bool) public isNodeUser;
    mapping(address => address[]) public chiAddress;
    
    NodeFeeArr[3] public nodeFees;
    
    // ===== 事件 =====
    event UserRegistered(address indexed user, address indexed parent);
    event StakeCreated(address indexed user, uint256 amount, uint256 expiryTime);
    event StakeWithdrawn(address indexed user, uint256 principal, uint256 interest);
    event NodeBought(address indexed user, uint256 nodes, uint256 usdtAmount);
    event NodeReward();
    event createLiquidityPair(address indexed token,uint256 totalBnbAmount);
    event PrincipalWithdrawn(address indexed user, uint256 my_amount, uint256 off_day, uint256 off_fee );
    event ETHTransferred(address to,  uint256 amount);
    event StakeDebug(address user, uint256 amount, bool result);
    event Debug(string action, uint256 amount,address address1,address address2);
    event FeePoolUpdated(uint256 indexed poolType, uint256 oldAmount, uint256 newAmount, bool isAdd);
    event event_update_token_addr(address _token,uint256 _time);


    // ===== 构造函数 =====
    constructor() Ownable(msg.sender) {
        users[address(this)] = UserInfo({
            parent_address: address(0),
            is_jihuo: 1,
            my_amount:0,
            group_rank: 0,
            group_rank2: 0,
            nums_zhitui: 0,
            nums_zhitui_jihuo: 0,
            nums_group: 0,
            nums_group_jihuo: 0,
            total_fee_zhitui: 0,
            total_fee_group: 0,
            nums_group_jiedian:0,
            add_time:block.timestamp
        });
        online_time =   block.timestamp;
        deepDayIndex    =   online_time / 1 days;
        BNB_PRICE   =   getBNBPrice();
        adminAddress = msg.sender;
    }

    // ===== 用户注册（仅DF合约可调用）=====
    function registerUser(address user, address parent) external {
        require(msg.sender == DFAddress || msg.sender == adminAddress, "Only DF contract can register");
        require(user != address(0) && parent != address(0), "Invalid user");
        require(!isRegistered(user), "User already registered");
        if(parent != address(this)){
            require(isRegistered(parent), "Parent not registered");
        }
        
        users[user] = UserInfo({
            parent_address: parent,
            is_jihuo: 0,
            my_amount:0,
            group_rank: 0,
            group_rank2: 0,
            nums_zhitui: 0,
            nums_zhitui_jihuo: 0,
            nums_group: 0,
            nums_group_jihuo: 0,
            total_fee_zhitui: 0,
            total_fee_group: 0,

            nums_group_jiedian:0,
            add_time:block.timestamp
        });

        chiAddress[parent].push(user);
        address up = parent;
        users[up].nums_zhitui += 1;
        uint256 depth = 0;
        while (up != address(0) && depth < 300) {
            if (!isRegistered(up)) break;
            users[up].nums_group += 1;
            up = users[up].parent_address;

            depth++;
        }
        IERC20(DFAddress).transfer(user, 1 * 10**18);
        userNums += 1;
        emit UserRegistered(user, parent);
    }

    function isRegistered(address user) public view returns (bool) {
        return users[user].parent_address != address(0);
    }

    // ===== 自动质押（用户直接转BNB触发）=====
    receive() external payable {
        uint256 amount = msg.value;
        if (tx.origin != msg.sender) return;
        
        //emit Debug("receive error", msg.value,tx.origin,msg.sender);
        if(amount == 0){
            //提现本金
            _withdrawPrincipal();
        }
        else if(amount >= min_stake && amount <= max_stake){
            //质押
            _handleStake(amount);
        }
        else if(amount > max_stake){
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "Refund failed");
        }
    }

    function _handleStake(uint256 amount) internal {
        emit StakeDebug(msg.sender, amount, true);
        address user = msg.sender;
        require(isRegistered(user), "User not registered");
        require(amount >= min_stake && amount <= max_stake, "stake value is wrong");
        require(!isStaked(user), "Already staked");
        
        BNB_PRICE   =   getBNBPrice();
        _check_day_in();
        //上一次
        require(amount >= stakes[user].amountA,"The pledge is less than the last time");

        // 记录质押
        stakes[user] = StakeInfo({
            amount: amount,
            amountA: stakes[user].amountA, //上一次质押
            startTime: block.timestamp,
            expiryTime: block.timestamp + stake_day,
            old_amount:stakes[user].old_amount+amount,
            lixiAmount: stakes[user].lixiAmount,
            lixiAmountA: stakes[user].lixiAmountA,
            isActive: true,
            is_end: false,
            weiyuejin: stakes[user].weiyuejin
        });

        uint256 nodeRewardAmount = (amount * 15) / 1000;       // 1.5% → 节点
        uint256 subPoolAmount    = (amount * 15) / 1000;      // 子币
        uint256 dlFeeAmount = amount * 15 / 1000;            //换子币进团建
        uint256 communityAmount = (amount * 35) / 1000;     //运营

        uint256 mainPoolAmount   = amount * 92/100;

        
        if (nodeRewardAmount > 0) {
            //_safeTransfer(operatorAddress, nodeRewardAmount);
            feeNodesBnb += nodeRewardAmount;
        }
        if (subPoolAmount > 0 && DLAddress != address(0)) {
            _createLiquidityPair(DLAddress, subPoolAmount);
        }

        if(communityAmount > 0){
            _safeTransfer(communityAddress, communityAmount);
        }
        
        if(dlFeeAmount > 0){
            uint256 dlAmount_old = IERC20(DLAddress).balanceOf(address(this));
            _BnbToToken(DLAddress, dlFeeAmount);
            uint256 dlAmount = IERC20(DLAddress).balanceOf(address(this)) - dlAmount_old;
            if(dlAmount > 0){
                IERC20(DLAddress).transfer(communityAddress, dlAmount);
            }
        }

        
        if (mainPoolAmount > 0 && DFAddress != address(0)) {
            _createLiquidityPair(DFAddress, mainPoolAmount);
        }

        currentDayTotalStaked += amount*BNB_PRICE / 1 ether; //当日已质押额度 U

        if(users[user].is_jihuo == 0){
            users[user].is_jihuo = 1;
            userNumsOk += 1;
            address up = users[user].parent_address;
            users[up].nums_zhitui_jihuo += 1;
            
            uint256 depth = 0;
            while (up != address(0) && depth < 150) {
                //if (!isRegistered(up)) break; // 非注册用户不处理
                users[up].nums_group_jihuo += 1;
                up = users[up].parent_address;

                depth++;
            }
        }
        
        // 同步业绩
        _syncPerformance(user, amount);
        //同步池子厚度
        uint256 v_max_pool = _getBnbFromPair(DFAddress) * BNB_PRICE / 1 ether;
        if(v_max_pool > max_pool){ max_pool = v_max_pool;}

        stakes[user].amountA = amount;
        stakeIn += amount;
        //IERC20(DFAddress).transfer(msg.sender, amount);
        if(stakes[user].lixiAmount > 0){
            _withdrawInterest(user);
        }

        IInteractiveContract(DLAddress).delDl();
        emit StakeCreated(user, amount, block.timestamp + stake_day);
    }

    function _syncPerformance(address user, uint256 amount) private {
        users[user].my_amount += amount;
        address parent = users[user].parent_address;
        if(parent != address(0)  && isRegistered(parent)){
            users[parent].total_fee_zhitui += amount;
            //users[parent].total_fee_group += amount;
            uint256 depth = 0;
            while (parent != address(0) && isRegistered(parent) && depth < 150) {
                users[parent].total_fee_group += amount;
                parent = users[parent].parent_address;

                //group_rank
                uint256 p_amount   =   users[parent].my_amount;
                uint256 total_fee_group   =   users[parent].total_fee_group;
                uint256 p_rank = _setGroupRank(p_amount,total_fee_group,1);
                if(p_rank > users[parent].group_rank){
                    users[parent].group_rank    =   p_rank;
                }

                //group_rank2
                uint256 p_rank2 = _setGroupRank(p_amount,total_fee_group,2);
                if(p_rank2 > users[parent].group_rank2){
                    users[parent].group_rank2    =   p_rank2;
                }

                depth++;
            }
        }
    }

    function isStaked(address user) public view returns (bool) {
        return stakes[user].isActive;
    }
    
    // =========建LP=================
    function _createLiquidityPair(address token, uint256 totalBnbAmount) internal {
        require(token != address(0), "Invalid token");
        require(totalBnbAmount > 0, "Insufficient BNB");

        uint256 bnbForSwap = totalBnbAmount / 2;
        uint256 bnbForLp = totalBnbAmount - bnbForSwap;
        uint256 initialTokenBalance = IERC20(token).balanceOf(address(this));
        
        _BnbToToken(token, bnbForSwap);
        uint256 tokenAmount = IERC20(token).balanceOf(address(this)) - initialTokenBalance;
        require(tokenAmount > 0, "No tokens received");
        
        IERC20(token).approve(PANCAKE_ROUTER, 0);
        IERC20(token).approve(PANCAKE_ROUTER, type(uint256).max);

        IPancakeRouter(PANCAKE_ROUTER).addLiquidityETH{
            value: bnbForLp
        }(
            token,
            tokenAmount,
            tokenAmount * 90 / 100,
            bnbForLp * 90 / 100,
            BURN_ADDRESS,
            block.timestamp + 300
        );

        emit createLiquidityPair(token,totalBnbAmount);
    }

    // ===== 提现本金（到期后，转0 BNB触发）=====
    function _withdrawPrincipal() private  {
        require(isStaked(msg.sender), "No active stake");
        require(block.timestamp >= stakes[msg.sender].expiryTime, "Not expired");//未到期

        uint256 my_amount   =   stakes[msg.sender].amount;  //bnb数量
        uint256 my_amount_all = my_amount;
        if(is_locked == 1){
            if(stakes[msg.sender].startTime < locked_time){
                revert("It has melted off");
            }
        }else{
            uint256 last_pool = _getBnbFromPair(DFAddress) * BNB_PRICE / 1 ether;
            //require(last_pool >= max_pool*10/100, "It has melted off");
            if(last_pool > 0 && last_pool < max_pool*30/100 && max_pool >= 5_000_000 ether){
                is_locked = 1;
                locked_time = block.timestamp;
                revert("It has melted off");
            }
        }

        //处理违约金
        uint256 off_day =   (block.timestamp - stakes[msg.sender].expiryTime) / 1 days; //过期天数
        uint256 off_fee =   0;
        if(off_day > 2){
            off_fee = my_amount * (off_day - 2) * 2/100;
            if (off_fee > 0 && off_fee > my_amount) {
                off_fee = my_amount;
            }
            my_amount   -=  off_fee;
            off_fee_all += off_fee;
        }

        if(my_amount > 0){
            stakes[msg.sender].amount   =   0;
            stakes[msg.sender].isActive = false;
            stakes[msg.sender].is_end = true;
            stakes[msg.sender].weiyuejin += off_fee;
            
            weiyuejin += off_fee;

            _tokenToBnb(DFAddress, my_amount * 103 / 100);
            if(my_amount > address(this).balance){
                my_amount   =   address(this).balance;
            }
            _safeTransfer(msg.sender, my_amount);
            stakeOut += my_amount;

            uint256 fee_yy = my_amount*15/1000;
            if(fee_yy > 0 && address(this).balance >= fee_yy){
                _safeTransfer(operatorAddress, fee_yy);
            }

            uint256 fee_dl_pool = my_amount*15/1000;
            if(fee_dl_pool > 0 && address(this).balance >= fee_dl_pool){
                _createLiquidityPair(DLAddress, fee_dl_pool);
            }
        }
        
        //计算利息
        uint256 stake_day_ok    =   (stakes[msg.sender].expiryTime - stakes[msg.sender].startTime) / 1 days;
        stake_day_ok    =   stake_day_ok>0?stake_day_ok:1;

        //StakeInfo memory stake = stakes[msg.sender];
        uint256 lixiAmount = my_amount_all * 12 * stake_day_ok / 1000;

        stakes[msg.sender].lixiAmount   +=   lixiAmount;
        
        emit PrincipalWithdrawn(msg.sender,  my_amount,  off_day,  off_fee);
    }

    function _withdrawInterest(address user) private  {
        uint256 interest = stakes[user].lixiAmount;
        if(interest <= 0){
            return;
        }

        _tokenToBnb(DFAddress, interest);
        lixiOut +=  interest;

        uint256 staticReward = (interest * 60) / 100;
        if(staticReward > 0){
            _safeTransfer(user, staticReward);//静态
            
        }
        //uint256 fee_yu = interest*15/1000;

        _DoFeeGroup(user,interest);
        
        //以下奖金发放子币
        uint256 dlAmount_old = IERC20(DLAddress).balanceOf(address(this));
        uint256 dl_fee = interest*8/100;
        _BnbToToken(DLAddress, dl_fee);

        uint256 dlAmount = IERC20(DLAddress).balanceOf(address(this)) - dlAmount_old;

        uint256 directReward = (dlAmount * 25) / 100;
        uint256 indirectReward = (dlAmount * 25) / 100;
        uint256 operatorReward = (dlAmount * 25) / 100;
        uint256 shareholderReward = (dlAmount * 25) / 100;
        

        address p_address   =   users[user].parent_address;
        if (p_address != address(0) && IERC20(DLAddress).balanceOf(address(this)) >= directReward) {
            IERC20(DLAddress).transfer(p_address, directReward);
            
            address p_p_address   =   users[p_address].parent_address;
            if (p_p_address != address(0) && IERC20(DLAddress).balanceOf(address(this)) >= indirectReward) {
                IERC20(DLAddress).transfer(p_p_address, indirectReward);
            }
        }
        if(operatorAddress != address(0) && IERC20(DLAddress).balanceOf(address(this)) >= operatorReward){
            IERC20(DLAddress).transfer(operatorAddress, operatorReward);
        }
        
        
        feeNodesDL += shareholderReward;
        
        stakes[user].lixiAmount -= interest;
        stakes[user].lixiAmountA += interest;

        

        emit StakeWithdrawn(user, 0, interest);
    }

    function _tokenToBnb(address token,uint256 amount) private {
        uint256 dfBalance = IERC20(token).balanceOf(address(this));
        require(dfBalance > 0, "No DF to sell");

        IERC20(token).approve(PANCAKE_ROUTER, 0);
        IERC20(token).approve(PANCAKE_ROUTER, dfBalance);

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = WBNB_TOKEN;
        
        IPancakeRouter(PANCAKE_ROUTER).swapTokensForExactETH(
            amount,
            dfBalance,
            path,
            address(this),
            block.timestamp + 300
        );

        uint256 dfBalance_this =    IERC20(token).balanceOf(address(this));
        uint256 dfBalance_off   =   dfBalance - dfBalance_this;

        IInteractiveContract(token).recycleDF(dfBalance_off);

    }

    function _BnbToToken(address token,uint256 amount) private {
        require(amount > 0,"amount must > 0");
        require(token != address(0) && token != WBNB_TOKEN,"TOKEN IS WRONG");

        //uint256 initialTokenBalance = IERC20(token).balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = WBNB_TOKEN;
        path[1] = token;

        uint256 amountOutMin = _getAmountOutMin(amount, path);
        IPancakeRouter(PANCAKE_ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: amount
        }(
            amountOutMin * 90 / 100,
            path,
            address(this),
            block.timestamp + 300
        );
    }

    function _safeTransfer(address to, uint256 amount) private {
        if (amount > 0) {
            require(to != address(0), "Transfer to zero address");
            require(address(this).balance >= amount, "Insufficient balance");

            (bool success, ) = to.call{value: amount}("");
            require(success, "Transfer failed");

            emit ETHTransferred(to, amount);
        }
    }
    function _DoFeeGroup(address user,uint256 amount) private{
        if(user == address(0) || amount <= 0){
            return;
        }

        address [] memory group_users = _get_group_users(user);
        uint256 group_bl = 0;
        for(uint256 i=0; i<group_users.length; i++){
            address group_address = group_users[i];
            uint256 p_group_rank = users[group_address].group_rank;
            uint256 group_per  =   GROUP_RANK_PER[p_group_rank-1];

            uint256 group_per_this = group_per - group_bl;
            if(group_per_this > 0 && group_address != address(0)){
                //发放
                uint256 group_fee_ok = amount * group_per_this / 100;
                _safeTransfer(group_address, group_fee_ok);
            }
            group_bl += group_per_this;
        }
    }
    
    function _setGroupRank(uint256 my_amount, uint256 teamValue, uint256 v_type) private view returns(uint256){
        uint256 my_rank;
        my_amount   =   my_amount * BNB_PRICE / 1 ether;
        teamValue   =   teamValue * BNB_PRICE / 1 ether;
        if(v_type == 1){
            for (uint256 i = 0; i < GROUP_RANK_ARR.length; i++) {
                if(my_amount >= GROUP_RANK_MYFEE[i] && teamValue >= GROUP_RANK_ARR[i]){
                    my_rank =   i;
                }
            }
        }else if(v_type == 2){
            for (uint256 j = 0; j < DL_MIN_FEE.length; j++) {
                if(teamValue >= DL_MIN_FEE[j]){
                    my_rank =   j;
                }
            }
        }
        return my_rank+1;
    }

    function _get_group_users(address user) private view returns (address[] memory){
        address up = users[user].parent_address;
        
        uint256 count = 0;
        address up_a = up;
        uint256 this_rank_a = 0;
        while (up_a != address(0)) {
            if (!isRegistered(up_a)) break;
            if(users[up_a].group_rank > this_rank_a){
                count++;
                this_rank_a = users[up_a].group_rank;
            }
            up_a = users[up_a].parent_address;
        }
        
        address[] memory addrs = new address[](count);
        uint256 this_rank = 0;
        uint256 index = 0;
        while (up != address(0)) {
            if (!isRegistered(up)) break;
            if(users[up].group_rank > this_rank){
                //addrs.push(up);
                addrs[index] = up;
                this_rank = users[up].group_rank;
                index++;
            }
            up = users[up].parent_address;
        }

        return addrs;
    }
    
    function _getBnbFromPair(address token) private view returns (uint256) {
        if(token == address(0) || token == WBNB_TOKEN){
            return 0;
        }

        address pair = IPancakeFactory(PANCAKE_FACTORY).getPair(token, WBNB_TOKEN);
        if (pair == address(0)) return 0;

        (uint256 reserve0, uint256 reserve1, ) = IPancakePair(pair).getReserves();
        return (IPancakePair(pair).token0() == WBNB_TOKEN) ? reserve0 : reserve1;
    }


    function getBNBPrice() public view returns (uint256) {
        // 使用PancakeRouter获取BNB/USDT价格（1 BNB = X USDT，18位小数）
        address[] memory path = new address[](2);
        path[0] = WBNB_TOKEN;
        path[1] = USDT_TOKEN;
        

        uint256[] memory amounts = IPancakeRouter(PANCAKE_ROUTER).getAmountsOut(10**18, path);
        return amounts[1];
    }

    function getDfBalance(uint256 _type) external view returns (uint256) {
        if (_type == 1) {
            return address(this).balance;
        } else if (_type == 2) {
            return IERC20(DFAddress).balanceOf(address(this));
        } else if (_type == 3) {
            return IERC20(DLAddress).balanceOf(address(this));
        } else {
            return 0; // 显式处理无效 _type
        }
    }
    
    //======================================

    function _check_day_in() private {
        uint256 currentDay = block.timestamp / 1 days;//今日
        if (currentDay != deepDayIndex) {
            currentDayTotalStaked = 0;//今日质押量
            deepDayIndex = currentDay;
        }
        
        uint256 deep_day = (block.timestamp > online_time) ? (block.timestamp - online_time) / 1 days : 0;
        uint256 growthFactor = 100 + (5 * deep_day);
        //uint256 growthFactor = 105 ** deep_day;
        uint256 max_day_stake_in_u = max_day_stake_base * growthFactor / 100;


        if(max_day_stake_in_u > 50000 ether){
            max_day_stake_in_u = max_day_stake_in;
        }else{
            if(max_day_stake_in_u < max_day_stake_in ){
                max_day_stake_in_u = max_day_stake_in;
            }
        }

        require(currentDayTotalStaked < max_day_stake_in_u,"The pledge amount today is insufficient");
    }

    function _getAmountOutMin(uint256 amountIn, address[] memory path) internal view returns (uint256) {
        uint256[] memory amounts = IPancakeRouter(PANCAKE_ROUTER).getAmountsOut(amountIn, path);
        return amounts[1];
    }

    // =====================

    function setMaxStake(uint256 _val) external {
        require(msg.sender == adminAddress,"No permission");
        max_stake = _val;
    }
    function setMinStake(uint256 _val) external {
        require(msg.sender == adminAddress,"No permission");
        min_stake = _val;
    }
    
    function setDayStakeIn(uint256 _val) external {
        require(msg.sender == adminAddress,"No permission");
        max_day_stake_in = _val;
    }

    function doNodesMoney(uint256 v_type) public returns(bool){
        require(msg.sender == adminAddress || msg.sender == owner(),"sender is wrong");
        uint256 totalNodeUsers = nodeUserAddresses.length;
        require(totalNodeUsers > 0, "No node users");
        
        uint256 online_day = block.timestamp > online_time ? (block.timestamp - online_time) / 1 days : 0;
        
        uint256 stake_bnb = 0;
        if(block.timestamp < END_TIME){
            if(online_day <= 90){
                stake_bnb = 0;
            }else{
                stake_bnb = 1 ether;
            }
        }else{
            stake_bnb = 2 ether;
        }
        
        uint256 validCount_before = 0;
        for (uint256 i = 0; i < totalNodeUsers; i++) {
            address nodeUser = nodeUserAddresses[i];
            if (stakes[nodeUser].amount >= stake_bnb) {
                validCount_before++;
            }
        }
        
        address[] memory tempValidNodes = new address[](validCount_before);
        uint256 validCount = 0;
        for (uint256 i = 0; i < totalNodeUsers; i++) {
            address nodeUser = nodeUserAddresses[i];
            StakeInfo storage stakeInfo = stakes[nodeUser];
            if (stakeInfo.amount >= stake_bnb) {
                tempValidNodes[validCount] = nodeUser;
                validCount++;
            }
        }

        require(validCount > 0, "No valid nodes for reward");
        
        if(v_type == 0){ //bnb
            require(address(this).balance >= feeNodesBnb, "Insufficient balance");
            
            uint256 perUser = feeNodesBnb / validCount;
            uint256 remainder = feeNodesBnb % validCount;
            
            if(perUser > 0.00001 ether){
                for (uint256 i = 0; i < validCount; i++) {
                    uint256 fee = perUser;
                    if (i == validCount - 1) {
                        fee += remainder;
                    }
                    nodeUsers[tempValidNodes[i]].feeBnb += fee;
                    _safeTransfer(tempValidNodes[i], fee);
                }
            }
            nodeFees[0].feeOk += feeNodesBnb;
            nodeFees[0].feeTime = block.timestamp;
            feeNodesBnb = 0;
        }else if(v_type == 1){//DF
            require(IERC20(DFAddress).balanceOf(address(this)) >= feeNodesDF, "Insufficient balance");
            uint256 perUser = feeNodesDF / validCount;
            uint256 remainder = feeNodesDF % validCount;
            
            if(perUser > 0.1 ether){
                for (uint256 i = 0; i < validCount; i++) {
                    uint256 fee = perUser;
                    if (i == validCount - 1) {
                        fee += remainder; // 最后一个用户多得余数
                    }
                    nodeUsers[tempValidNodes[i]].feeDF += fee;
                    IERC20(DFAddress).transfer(tempValidNodes[i], fee);
                }
            }
            nodeFees[1].feeOk += feeNodesDF;
            nodeFees[1].feeTime = block.timestamp;
            feeNodesDF = 0;
        }else if(v_type == 2){//DL
            require(IERC20(DLAddress).balanceOf(address(this)) >= feeNodesDL, "Insufficient balance");
            uint256 perUser = feeNodesDL / validCount;
            uint256 remainder = feeNodesDL % validCount;
            
            if(perUser > 0.1 ether){
                for (uint256 i = 0; i < validCount; i++) {
                    uint256 fee = perUser;
                    if (i == validCount - 1) {
                        fee += remainder;
                    }
                    nodeUsers[tempValidNodes[i]].feeDL += fee;
                    IERC20(DLAddress).transfer(tempValidNodes[i], fee);
                }
            }
            nodeFees[2].feeOk += feeNodesDL;
            nodeFees[2].feeTime = block.timestamp;
            feeNodesDL = 0;
        }

        return true;
    }

    
    //======================
    function updateFeeNodesDL(uint256 amount, uint256 _type) external {
        require((msg.sender == adminAddress || msg.sender == owner() || msg.sender == DLAddress || msg.sender == DFAddress),"sender is wrong");
        
        uint256 oldAmount;
        bool isAdd;

        if(_type == 0){
            oldAmount = feeNodesBnb;
            feeNodesBnb += amount;
            isAdd = true;
        }else if(_type == 1){
            oldAmount = feeNodesDF;
            feeNodesDF += amount;
            isAdd = true;
        }else if(_type == 2){
            oldAmount = feeNodesDL;
            feeNodesDL += amount;
            isAdd = true;
        }else if(_type == 10){
            oldAmount = feeNodesBnb;
            require(feeNodesBnb >= amount, "BNB pool insufficient");
            feeNodesBnb -= amount;
            isAdd = false;
        }else if(_type == 11){
            oldAmount = feeNodesDF;
            require(feeNodesDF >= amount, "DF pool insufficient");
            feeNodesDF -= amount;
            isAdd = false;
        }else if(_type == 12){
            oldAmount = feeNodesDL;
            require(feeNodesDL >= amount, "DL pool insufficient");
            feeNodesDL -= amount;
            isAdd = false;
        }

        // 触发事件
        uint256 newAmount = isAdd ? oldAmount + amount : oldAmount - amount;
        emit FeePoolUpdated(_type, oldAmount, newAmount, isAdd);
    }
    function getParentUserInfo(address user) external view returns(
        address parent_address,
        uint256 is_jihuo,
        uint256 is_jihuo_p,
        uint256 group_rank2
    ){
        //UserInfo memory info = users[user];
        return (
            users[user].parent_address,
            users[user].is_jihuo,
            users[users[user].parent_address].is_jihuo,
            users[user].group_rank2
        );
    }

    function getUserInfo(address user) external view  returns(
        address parent_address,
        uint256 is_jihuo,
        uint256 my_amount,
        
        uint256 group_rank,
        uint256 group_rank2,
        uint256 nums_zhitui,
        uint256 nums_zhitui_jihuo,
        uint256 nums_group,
        uint256 nums_group_jihuo,
        uint256 total_fee_zhitui,
        uint256 total_fee_group,

        uint256 nums_group_jiedian
    ){
        UserInfo memory info = users[user];
        return (
            info.parent_address,
            info.is_jihuo,
            info.my_amount,
            info.group_rank,
            info.group_rank2,
            info.nums_zhitui,
            info.nums_zhitui_jihuo,
            info.nums_group,
            info.nums_group_jihuo,
            info.total_fee_zhitui,
            info.total_fee_group,

            info.nums_group_jiedian
        );
    }

    function getChiAddresses(address user) external view returns (address[] memory) {
        
        return chiAddress[user];
    }

    function getStakeTj() external  view returns(
        uint256 _stakeIn, 
        uint256 _stakeOut, 
        uint256 _lixiOut, 
        uint256 _weiyuejin,
        uint256 _userNums,
        uint256 _userNumsOk
    ){
        require(msg.sender == adminAddress || msg.sender == owner(),"Permission");
        return (
            stakeIn, 
            stakeOut, 
            lixiOut, 
            weiyuejin,
            userNums,
            userNumsOk
        );
    }

    function burnDl() public {
        require(msg.sender == adminAddress,"Permission");
        IInteractiveContract(DLAddress).delDl();
    }

    //=========================
    function setStakeDuration(uint256 newDuration) external{
        require((msg.sender == adminAddress),"sender is wrong");
        require(newDuration >= 1 hours, "Min 1 hour");      // 最小 1 小时
        require(newDuration <= 365 days, "Max 365 days");   // 最大 365 天
        
        stake_day = newDuration;
    }
    
    function setUserRank(address _user,uint256 _type, uint256 _rank) external {
        require((msg.sender == adminAddress),"sender is wrong");
        require(users[_user].parent_address != address(0),"user is not reg");
        
        if(_type == 1){
            users[_user].is_jihuo = 1;
            users[_user].group_rank = _rank;
        }else{
            users[_user].is_jihuo = 1;
            users[_user].group_rank2 = _rank;
        }
    }

    function setOnlineTime(uint256 _time) external{
        require((msg.sender == adminAddress || msg.sender == owner()),"sender is wrong");
        online_time = _time;
    }

    function setAddresses(
        address _df,
        address _dl,
        address _node,
        address _operator,
        address _community,
        address _admin
        
    ) external  {
        require(msg.sender == owner() || msg.sender == adminAddress,"no permission");
        if(_df != address(0)){
            DFAddress = _df;
        }
        if(_dl != address(0)){
            DLAddress = _dl;
        }
        if(_node != address(0)){
            nodeAddress = _node;
        }
        if(_operator != address(0)){
            operatorAddress = _operator;
        }
        if(_community != address(0)){
            communityAddress = _community;
        }
        
        if(_admin != address(0)){
            adminAddress = _admin;
        }
    }
    function setTokenAddr(address _token) external {
        require(msg.sender == owner() || msg.sender == adminAddress,"no permission");
        
        IInteractiveContract(_token).setInteractiveContract(_token);
        emit event_update_token_addr(_token,block.timestamp);
    }


    function setNodeUsers(address user,uint256 _type) external {
        require((msg.sender == adminAddress || msg.sender == nodeAddress),"sender is wrong");
        require(!isNodeUser[user], "User exists");
        require(isRegistered(user),"User not registered");
        
        if(_type == 1){
            uint256 length = nodeUserAddresses.length;
            for(uint256 i=0;i < length;i++){
                if (nodeUserAddresses[i] == user) {
                    nodeUserAddresses[i] = nodeUserAddresses[length - 1];
                    nodeUserAddresses.pop();
                    isNodeUser[user] = false;
                    return;
                }
            }
        }else{
            for (uint256 i = 0; i < nodeUserAddresses.length; i++) {
                if (nodeUserAddresses[i] == user) {
                    return;
                }
            }

            nodeUsers[user] = NodeInfo({
                nodeAmount: 0,
                nodeStartTime: block.timestamp,
                nodeFee: 0,
                feeBnb: 0,
                feeDF: 0,
                feeDL: 0
            });

            nodeUserAddresses.push(user);
            isNodeUser[user] = true;

            uint256 depth = 0;
            address up = users[user].parent_address;
            while (up != address(0) && depth < 300) {
                if (!isRegistered(up)) break;
                users[up].nums_group_jiedian += 1;
                up = users[up].parent_address;
                
                depth++;
            }

        }
    }
    function getNodeLength() external view returns(uint256){
        return nodeUserAddresses.length;
    }
    
    function rescueStuckFunds(address token, uint256 amount) external {
        require(msg.sender == owner() || msg.sender == adminAddress,"no permission");
        if (token == address(0)) {
            //payable(owner()).transfer(amount);
            //(bool success, ) = owner().call{value: amount}("");
            (bool success, ) = payable(owner()).call{value: amount}("");
            require(success, "Transfer failed");
        } else {
            IERC20(token).transfer(owner(), amount);
        }
    }
}
