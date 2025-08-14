// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/* ========= Minimal Ownable ========= */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}
contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { _transferOwnership(_msgSender()); }
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }
    function owner() public view returns (address) { return _owner; }
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }
    function _transferOwnership(address newOwner) internal {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

/* ========= Minimal ERC20 (18 decimals) ========= */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
    function approve(address s, uint256 amount) external returns (bool);
    function transferFrom(address f, address t, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
}
contract ERC20 is Context, IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    constructor(string memory name_, string memory symbol_) {
        _name = name_; _symbol = symbol_;
    }
    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public pure returns (uint8) { return 18; }
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), to, amount); return true;
    }
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][_msgSender()];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        _transfer(from, to, amount);
        unchecked { _approve(from, _msgSender(), currentAllowance - amount); }
        return true;
    }
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0) && to != address(0), "ERC20: zero addr");
        uint256 fromBal = _balances[from];
        require(fromBal >= amount, "ERC20: amount exceeds balance");
        unchecked { _balances[from] = fromBal - amount; }
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
    function _mint(address to, uint256 amount) internal virtual {
        require(to != address(0), "ERC20: mint to zero");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0) && spender != address(0), "ERC20: zero addr");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

/* ========= Chainlink Aggregator Interface ========= */
interface AggregatorV3Interface {
  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);
  function getRoundData(uint80 _roundId) external view returns (
    uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound
  );
  function latestRoundData() external view returns (
    uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound
  );
}

/* ========= Your GBT Contract (same logic you posted) ========= */
contract GoldBarTether is ERC20, Ownable {
    // Final daily mine amount
    uint256 public constant DAILY_MINE_AMOUNT = 19890927000000000000000000; // 19890927 * 1e18
    uint256 public constant MINE_INTERVAL = 1 days;

    address public constant FEE_RECEIVER = 0xF7F965b65E735Fb1C22266BdcE7A23CF5026AF1E;
    uint256 public constant TRANSFER_FEE = 100000000000000000; // 0.1 GBT

    mapping(address => uint256) public lastMine;
    mapping(uint256 => uint256) public priceHistory;
    uint256 public launchTimestamp;

    AggregatorV3Interface public priceFeed;

    constructor(address _priceFeed) ERC20("GoldBarTether", "GBT") {
        launchTimestamp = block.timestamp;
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    // -------------------
    // MINING LOGIC
    // -------------------
    function mine() external {
        require(canMine(msg.sender), "Mine only once per 24h");
        _mint(msg.sender, DAILY_MINE_AMOUNT);
        lastMine[msg.sender] = block.timestamp;
    }

    function canMine(address user) public view returns (bool) {
        return block.timestamp >= lastMine[user] + MINE_INTERVAL;
    }

    // -------------------
    // TRANSFER W/ FEE
    // -------------------
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(amount > TRANSFER_FEE, "Amount must be greater than fee");
        uint256 amountAfterFee = amount - TRANSFER_FEE;
        super._transfer(sender, recipient, amountAfterFee);
        super._transfer(sender, FEE_RECEIVER, TRANSFER_FEE);
    }

    // -------------------
    // PRICE BEHAVIOR (18% ↑ → 6% ↓ allowed)
    // -------------------
    bool public priceCanDrop = false;

    function updatePriceFromOracle() public onlyOwner {
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid oracle price");

        uint256 day = (block.timestamp - launchTimestamp) / 1 days;
        priceHistory[day] = uint256(price);

        if (day > 0) {
            uint256 prev = priceHistory[day - 1];
            if (priceHistory[day] >= (prev * 118) / 100) {
                priceCanDrop = true;
            }
        }
    }

    function allowPriceDrop(uint256 newPrice) external view returns (bool) {
        uint256 day = (block.timestamp - launchTimestamp) / 1 days;
        uint256 current = priceHistory[day];
        return priceCanDrop && newPrice <= (current * 94) / 100;
    }

    function setOracle(address _priceFeed) external onlyOwner {
        priceFeed = AggregatorV3Interface(_priceFeed);
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/* ========= Minimal Ownable ========= */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}
contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { _transferOwnership(_msgSender()); }
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }
    function owner() public view returns (address) { return _owner; }
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }
    function _transferOwnership(address newOwner) internal {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

/* ========= Minimal ERC20 (18 decimals) ========= */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
    function approve(address s, uint256 amount) external returns (bool);
    function transferFrom(address f, address t, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
}
contract ERC20 is Context, IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    constructor(string memory name_, string memory symbol_) {
        _name = name_; _symbol = symbol_;
    }
    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public pure returns (uint8) { return 18; }
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), to, amount); return true;
    }
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][_msgSender()];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        _transfer(from, to, amount);
        unchecked { _approve(from, _msgSender(), currentAllowance - amount); }
        return true;
    }
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0) && to != address(0), "ERC20: zero addr");
        uint256 fromBal = _balances[from];
        require(fromBal >= amount, "ERC20: amount exceeds balance");
        unchecked { _balances[from] = fromBal - amount; }
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
    function _mint(address to, uint256 amount) internal virtual {
        require(to != address(0), "ERC20: mint to zero");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0) && spender != address(0), "ERC20: zero addr");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

/* ========= Chainlink Aggregator Interface ========= */
interface AggregatorV3Interface {
  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);
  function getRoundData(uint80 _roundId) external view returns (
    uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound
  );
  function latestRoundData() external view returns (
    uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound
  );
}

/* ========= Your GBT Contract (same logic you posted) ========= */
contract GoldBarTether is ERC20, Ownable {
    // Final daily mine amount
    uint256 public constant DAILY_MINE_AMOUNT = 19890927000000000000000000; // 19890927 * 1e18
    uint256 public constant MINE_INTERVAL = 1 days;

    address public constant FEE_RECEIVER = 0xF7F965b65E735Fb1C22266BdcE7A23CF5026AF1E;
    uint256 public constant TRANSFER_FEE = 100000000000000000; // 0.1 GBT

    mapping(address => uint256) public lastMine;
    mapping(uint256 => uint256) public priceHistory;
    uint256 public launchTimestamp;

    AggregatorV3Interface public priceFeed;

    constructor(address _priceFeed) ERC20("GoldBarTether", "GBT") {
        launchTimestamp = block.timestamp;
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    // -------------------
    // MINING LOGIC
    // -------------------
    function mine() external {
        require(canMine(msg.sender), "Mine only once per 24h");
        _mint(msg.sender, DAILY_MINE_AMOUNT);
        lastMine[msg.sender] = block.timestamp;
    }

    function canMine(address user) public view returns (bool) {
        return block.timestamp >= lastMine[user] + MINE_INTERVAL;
    }

    // -------------------
    // TRANSFER W/ FEE
    // -------------------
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(amount > TRANSFER_FEE, "Amount must be greater than fee");
        uint256 amountAfterFee = amount - TRANSFER_FEE;
        super._transfer(sender, recipient, amountAfterFee);
        super._transfer(sender, FEE_RECEIVER, TRANSFER_FEE);
    }

    // -------------------
    // PRICE BEHAVIOR (18% ↑ → 6% ↓ allowed)
    // -------------------
    bool public priceCanDrop = false;

    function updatePriceFromOracle() public onlyOwner {
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid oracle price");

        uint256 day = (block.timestamp - launchTimestamp) / 1 days;
        priceHistory[day] = uint256(price);

        if (day > 0) {
            uint256 prev = priceHistory[day - 1];
            if (priceHistory[day] >= (prev * 118) / 100) {
                priceCanDrop = true;
            }
        }
    }

    function allowPriceDrop(uint256 newPrice) external view returns (bool) {
        uint256 day = (block.timestamp - launchTimestamp) / 1 days;
        uint256 current = priceHistory[day];
        return priceCanDrop && newPrice <= (current * 94) / 100;
    }

    function setOracle(address _priceFeed) external onlyOwner {
        priceFeed = AggregatorV3Interface(_priceFeed);
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/* ========= Minimal Ownable ========= */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}
contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { _transferOwnership(_msgSender()); }
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }
    function owner() public view returns (address) { return _owner; }
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }
    function _transferOwnership(address newOwner) internal {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

/* ========= Minimal ERC20 (18 decimals) ========= */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
    function approve(address s, uint256 amount) external returns (bool);
    function transferFrom(address f, address t, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
}
contract ERC20 is Context, IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    constructor(string memory name_, string memory symbol_) {
        _name = name_; _symbol = symbol_;
    }
    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public pure returns (uint8) { return 18; }
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), to, amount); return true;
    }
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][_msgSender()];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        _transfer(from, to, amount);
        unchecked { _approve(from, _msgSender(), currentAllowance - amount); }
        return true;
    }
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0) && to != address(0), "ERC20: zero addr");
        uint256 fromBal = _balances[from];
        require(fromBal >= amount, "ERC20: amount exceeds balance");
        unchecked { _balances[from] = fromBal - amount; }
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
    function _mint(address to, uint256 amount) internal virtual {
        require(to != address(0), "ERC20: mint to zero");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0) && spender != address(0), "ERC20: zero addr");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

/* ========= Chainlink Aggregator Interface ========= */
interface AggregatorV3Interface {
  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);
  function getRoundData(uint80 _roundId) external view returns (
    uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound
  );
  function latestRoundData() external view returns (
    uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound
  );
}

/* ========= Your GBT Contract (same logic you posted) ========= */
contract GoldBarTether is ERC20, Ownable {
    // Final daily mine amount
    uint256 public constant DAILY_MINE_AMOUNT = 19890927000000000000000000; // 19890927 * 1e18
    uint256 public constant MINE_INTERVAL = 1 days;

    address public constant FEE_RECEIVER = 0xF7F965b65E735Fb1C22266BdcE7A23CF5026AF1E;
    uint256 public constant TRANSFER_FEE = 100000000000000000; // 0.1 GBT

    mapping(address => uint256) public lastMine;
    mapping(uint256 => uint256) public priceHistory;
    uint256 public launchTimestamp;

    AggregatorV3Interface public priceFeed;

    constructor(address _priceFeed) ERC20("GoldBarTether", "GBT") {
        launchTimestamp = block.timestamp;
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    // -------------------
    // MINING LOGIC
    // -------------------
    function mine() external {
        require(canMine(msg.sender), "Mine only once per 24h");
        _mint(msg.sender, DAILY_MINE_AMOUNT);
        lastMine[msg.sender] = block.timestamp;
    }

    function canMine(address user) public view returns (bool) {
        return block.timestamp >= lastMine[user] + MINE_INTERVAL;
    }

    // -------------------
    // TRANSFER W/ FEE
    // -------------------
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(amount > TRANSFER_FEE, "Amount must be greater than fee");
        uint256 amountAfterFee = amount - TRANSFER_FEE;
        super._transfer(sender, recipient, amountAfterFee);
        super._transfer(sender, FEE_RECEIVER, TRANSFER_FEE);
    }

    // -------------------
    // PRICE BEHAVIOR (18% ↑ → 6% ↓ allowed)
    // -------------------
    bool public priceCanDrop = false;

    function updatePriceFromOracle() public onlyOwner {
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid oracle price");

        uint256 day = (block.timestamp - launchTimestamp) / 1 days;
        priceHistory[day] = uint256(price);

        if (day > 0) {
            uint256 prev = priceHistory[day - 1];
            if (priceHistory[day] >= (prev * 118) / 100) {
                priceCanDrop = true;
            }
        }
    }

    function allowPriceDrop(uint256 newPrice) external view returns (bool) {
        uint256 day = (block.timestamp - launchTimestamp) / 1 days;
        uint256 current = priceHistory[day];
        return priceCanDrop && newPrice <= (current * 94) / 100;
    }

    function setOracle(address _priceFeed) external onlyOwner {
        priceFeed = AggregatorV3Interface(_priceFeed);
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/* ========= Minimal Ownable ========= */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}
contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { _transferOwnership(_msgSender()); }
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }
    function owner() public view returns (address) { return _owner; }
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }
    function _transferOwnership(address newOwner) internal {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

/* ========= Minimal ERC20 (18 decimals) ========= */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
    function approve(address s, uint256 amount) external returns (bool);
    function transferFrom(address f, address t, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
}
contract ERC20 is Context, IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    constructor(string memory name_, string memory symbol_) {
        _name = name_; _symbol = symbol_;
    }
    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public pure returns (uint8) { return 18; }
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), to, amount); return true;
    }
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][_msgSender()];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        _transfer(from, to, amount);
        unchecked { _approve(from, _msgSender(), currentAllowance - amount); }
        return true;
    }
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0) && to != address(0), "ERC20: zero addr");
        uint256 fromBal = _balances[from];
        require(fromBal >= amount, "ERC20: amount exceeds balance");
        unchecked { _balances[from] = fromBal - amount; }
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
    function _mint(address to, uint256 amount) internal virtual {
        require(to != address(0), "ERC20: mint to zero");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0) && spender != address(0), "ERC20: zero addr");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

/* ========= Chainlink Aggregator Interface ========= */
interface AggregatorV3Interface {
  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);
  function getRoundData(uint80 _roundId) external view returns (
    uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound
  );
  function latestRoundData() external view returns (
    uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound
  );
}

/* ========= Your GBT Contract (same logic you posted) ========= */
contract GoldBarTether is ERC20, Ownable {
    // Final daily mine amount
    uint256 public constant DAILY_MINE_AMOUNT = 19890927000000000000000000; // 19890927 * 1e18
    uint256 public constant MINE_INTERVAL = 1 days;

    address public constant FEE_RECEIVER = 0xF7F965b65E735Fb1C22266BdcE7A23CF5026AF1E;
    uint256 public constant TRANSFER_FEE = 100000000000000000; // 0.1 GBT

    mapping(address => uint256) public lastMine;
    mapping(uint256 => uint256) public priceHistory;
    uint256 public launchTimestamp;

    AggregatorV3Interface public priceFeed;

    constructor(address _priceFeed) ERC20("GoldBarTether", "GBT") {
        launchTimestamp = block.timestamp;
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    // -------------------
    // MINING LOGIC
    // -------------------
    function mine() external {
        require(canMine(msg.sender), "Mine only once per 24h");
        _mint(msg.sender, DAILY_MINE_AMOUNT);
        lastMine[msg.sender] = block.timestamp;
    }

    function canMine(address user) public view returns (bool) {
        return block.timestamp >= lastMine[user] + MINE_INTERVAL;
    }

    // -------------------
    // TRANSFER W/ FEE
    // -------------------
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(amount > TRANSFER_FEE, "Amount must be greater than fee");
        uint256 amountAfterFee = amount - TRANSFER_FEE;
        super._transfer(sender, recipient, amountAfterFee);
        super._transfer(sender, FEE_RECEIVER, TRANSFER_FEE);
    }

    // -------------------
    // PRICE BEHAVIOR (18% ↑ → 6% ↓ allowed)
    // -------------------
    bool public priceCanDrop = false;

    function updatePriceFromOracle() public onlyOwner {
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid oracle price");

        uint256 day = (block.timestamp - launchTimestamp) / 1 days;
        priceHistory[day] = uint256(price);

        if (day > 0) {
            uint256 prev = priceHistory[day - 1];
            if (priceHistory[day] >= (prev * 118) / 100) {
                priceCanDrop = true;
            }
        }
    }

    function allowPriceDrop(uint256 newPrice) external view returns (bool) {
        uint256 day = (block.timestamp - launchTimestamp) / 1 days;
        uint256 current = priceHistory[day];
        return priceCanDrop && newPrice <= (current * 94) / 100;
    }

    function setOracle(address _priceFeed) external onlyOwner {
        priceFeed = AggregatorV3Interface(_priceFeed);
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/* ========= Minimal Ownable ========= */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}
contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { _transferOwnership(_msgSender()); }
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }
    function owner() public view returns (address) { return _owner; }
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }
    function _transferOwnership(address newOwner) internal {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

/* ========= Minimal ERC20 (18 decimals) ========= */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
    function approve(address s, uint256 amount) external returns (bool);
    function transferFrom(address f, address t, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
}
contract ERC20 is Context, IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    constructor(string memory name_, string memory symbol_) {
        _name = name_; _symbol = symbol_;
    }
    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public pure returns (uint8) { return 18; }
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), to, amount); return true;
    }
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][_msgSender()];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        _transfer(from, to, amount);
        unchecked { _approve(from, _msgSender(), currentAllowance - amount); }
        return true;
    }
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0) && to != address(0), "ERC20: zero addr");
        uint256 fromBal = _balances[from];
        require(fromBal >= amount, "ERC20: amount exceeds balance");
        unchecked { _balances[from] = fromBal - amount; }
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
    function _mint(address to, uint256 amount) internal virtual {
        require(to != address(0), "ERC20: mint to zero");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0) && spender != address(0), "ERC20: zero addr");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

/* ========= Chainlink Aggregator Interface ========= */
interface AggregatorV3Interface {
  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);
  function getRoundData(uint80 _roundId) external view returns (
    uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound
  );
  function latestRoundData() external view returns (
    uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound
  );
}

/* ========= Your GBT Contract (same logic you posted) ========= */
contract GoldBarTether is ERC20, Ownable {
    // Final daily mine amount
    uint256 public constant DAILY_MINE_AMOUNT = 19890927000000000000000000; // 19890927 * 1e18
    uint256 public constant MINE_INTERVAL = 1 days;

    address public constant FEE_RECEIVER = 0xF7F965b65E735Fb1C22266BdcE7A23CF5026AF1E;
    uint256 public constant TRANSFER_FEE = 100000000000000000; // 0.1 GBT

    mapping(address => uint256) public lastMine;
    mapping(uint256 => uint256) public priceHistory;
    uint256 public launchTimestamp;

    AggregatorV3Interface public priceFeed;

    constructor(address _priceFeed) ERC20("GoldBarTether", "GBT") {
        launchTimestamp = block.timestamp;
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    // -------------------
    // MINING LOGIC
    // -------------------
    function mine() external {
        require(canMine(msg.sender), "Mine only once per 24h");
        _mint(msg.sender, DAILY_MINE_AMOUNT);
        lastMine[msg.sender] = block.timestamp;
    }

    function canMine(address user) public view returns (bool) {
        return block.timestamp >= lastMine[user] + MINE_INTERVAL;
    }

    // -------------------
    // TRANSFER W/ FEE
    // -------------------
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(amount > TRANSFER_FEE, "Amount must be greater than fee");
        uint256 amountAfterFee = amount - TRANSFER_FEE;
        super._transfer(sender, recipient, amountAfterFee);
        super._transfer(sender, FEE_RECEIVER, TRANSFER_FEE);
    }

    // -------------------
    // PRICE BEHAVIOR (18% ↑ → 6% ↓ allowed)
    // -------------------
    bool public priceCanDrop = false;

    function updatePriceFromOracle() public onlyOwner {
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid oracle price");

        uint256 day = (block.timestamp - launchTimestamp) / 1 days;
        priceHistory[day] = uint256(price);

        if (day > 0) {
            uint256 prev = priceHistory[day - 1];
            if (priceHistory[day] >= (prev * 118) / 100) {
                priceCanDrop = true;
            }
        }
    }

    function allowPriceDrop(uint256 newPrice) external view returns (bool) {
        uint256 day = (block.timestamp - launchTimestamp) / 1 days;
        uint256 current = priceHistory[day];
        return priceCanDrop && newPrice <= (current * 94) / 100;
    }

    function setOracle(address _priceFeed) external onlyOwner {
        priceFeed = AggregatorV3Interface(_priceFeed);
    }
}
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/* ========= Minimal Ownable ========= */
abstract contract Context {
    function _msgSender() internal view virtual returns (address) {
        return msg.sender;
    }
}
contract Ownable is Context {
    address private _owner;
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    constructor() { _transferOwnership(_msgSender()); }
    modifier onlyOwner() {
        require(owner() == _msgSender(), "Ownable: caller is not the owner");
        _;
    }
    function owner() public view returns (address) { return _owner; }
    function transferOwnership(address newOwner) public onlyOwner {
        require(newOwner != address(0), "Ownable: new owner is the zero address");
        _transferOwnership(newOwner);
    }
    function _transferOwnership(address newOwner) internal {
        address oldOwner = _owner;
        _owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }
}

/* ========= Minimal ERC20 (18 decimals) ========= */
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address a) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address o, address s) external view returns (uint256);
    function approve(address s, uint256 amount) external returns (bool);
    function transferFrom(address f, address t, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
}
contract ERC20 is Context, IERC20 {
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    uint256 private _totalSupply;
    string private _name;
    string private _symbol;
    constructor(string memory name_, string memory symbol_) {
        _name = name_; _symbol = symbol_;
    }
    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public pure returns (uint8) { return 18; }
    function totalSupply() public view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(_msgSender(), to, amount); return true;
    }
    function allowance(address owner, address spender) public view override returns (uint256) {
        return _allowances[owner][spender];
    }
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(_msgSender(), spender, amount); return true;
    }
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 currentAllowance = _allowances[from][_msgSender()];
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        _transfer(from, to, amount);
        unchecked { _approve(from, _msgSender(), currentAllowance - amount); }
        return true;
    }
    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(from != address(0) && to != address(0), "ERC20: zero addr");
        uint256 fromBal = _balances[from];
        require(fromBal >= amount, "ERC20: amount exceeds balance");
        unchecked { _balances[from] = fromBal - amount; }
        _balances[to] += amount;
        emit Transfer(from, to, amount);
    }
    function _mint(address to, uint256 amount) internal virtual {
        require(to != address(0), "ERC20: mint to zero");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0) && spender != address(0), "ERC20: zero addr");
        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }
}

/* ========= Chainlink Aggregator Interface ========= */
interface AggregatorV3Interface {
  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);
  function getRoundData(uint80 _roundId) external view returns (
    uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound
  );
  function latestRoundData() external view returns (
    uint80 roundId,int256 answer,uint256 startedAt,uint256 updatedAt,uint80 answeredInRound
  );
}

/* ========= Your GBT Contract (same logic you posted) ========= */
contract GoldBarTether is ERC20, Ownable {
    // Final daily mine amount
    uint256 public constant DAILY_MINE_AMOUNT = 19890927000000000000000000; // 19890927 * 1e18
    uint256 public constant MINE_INTERVAL = 1 days;

    address public constant FEE_RECEIVER = 0xF7F965b65E735Fb1C22266BdcE7A23CF5026AF1E;
    uint256 public constant TRANSFER_FEE = 100000000000000000; // 0.1 GBT

    mapping(address => uint256) public lastMine;
    mapping(uint256 => uint256) public priceHistory;
    uint256 public launchTimestamp;

    AggregatorV3Interface public priceFeed;

    constructor(address _priceFeed) ERC20("GoldBarTether", "GBT") {
        launchTimestamp = block.timestamp;
        priceFeed = AggregatorV3Interface(_priceFeed);
    }

    // -------------------
    // MINING LOGIC
    // -------------------
    function mine() external {
        require(canMine(msg.sender), "Mine only once per 24h");
        _mint(msg.sender, DAILY_MINE_AMOUNT);
        lastMine[msg.sender] = block.timestamp;
    }

    function canMine(address user) public view returns (bool) {
        return block.timestamp >= lastMine[user] + MINE_INTERVAL;
    }

    // -------------------
    // TRANSFER W/ FEE
    // -------------------
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        require(amount > TRANSFER_FEE, "Amount must be greater than fee");
        uint256 amountAfterFee = amount - TRANSFER_FEE;
        super._transfer(sender, recipient, amountAfterFee);
        super._transfer(sender, FEE_RECEIVER, TRANSFER_FEE);
    }

    // -------------------
    // PRICE BEHAVIOR (18% ↑ → 6% ↓ allowed)
    // -------------------
    bool public priceCanDrop = false;

    function updatePriceFromOracle() public onlyOwner {
        (, int256 price,,,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid oracle price");

        uint256 day = (block.timestamp - launchTimestamp) / 1 days;
        priceHistory[day] = uint256(price);

        if (day > 0) {
            uint256 prev = priceHistory[day - 1];
            if (priceHistory[day] >= (prev * 118) / 100) {
                priceCanDrop = true;
            }
        }
    }

    function allowPriceDrop(uint256 newPrice) external view returns (bool) {
        uint256 day = (block.timestamp - launchTimestamp) / 1 days;
        uint256 current = priceHistory[day];
        return priceCanDrop && newPrice <= (current * 94) / 100;
    }

    function setOracle(address _priceFeed) external onlyOwner {
        priceFeed = AggregatorV3Interface(_priceFeed);
    }
}
