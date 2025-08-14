import os, json
from fastapi import FastAPI
from fastapi.responses import HTMLResponse
from web3 import Web3
from solcx import install_solc, compile_source

# --- Config via env ---
RPC_URL = os.getenv("RPC_URL", "https://gbtnetwork-render-h1ij.onrender.com")
PRIVATE_KEY = os.getenv("PRIVATE_KEY")  # 0x...
CHAIN_ID = int(os.getenv("CHAIN_ID", "999"))
PRICE_FEED = os.getenv("PRICE_FEED", "0x0000000000000000000000000000000000000000")  # set your Chainlink feed if any
CONTRACT_PATH = os.getenv("CONTRACT_PATH", "GoldBarTether_flat.sol")

app = FastAPI()
w3 = Web3(Web3.HTTPProvider(RPC_URL))
if not w3.is_connected():
    raise RuntimeError("Cannot connect to RPC_URL")

acct = w3.eth.account.from_key(PRIVATE_KEY)
DEPLOYED_ADDRESS = None

def deploy_contract():
    global DEPLOYED_ADDRESS
    install_solc("0.8.21")
    with open(CONTRACT_PATH, "r") as f:
        source = f.read()
    compiled = compile_source(source, output_values=["abi", "bin"], solc_version="0.8.21")
    (_, iface) = next(iter(compiled.items()))
    abi, bytecode = iface["abi"], iface["bin"]

    Contract = w3.eth.contract(abi=abi, bytecode=bytecode)
    tx = Contract.constructor(PRICE_FEED).build_transaction({
        "from": acct.address,
        "nonce": w3.eth.get_transaction_count(acct.address),
        "gas": 6_000_000,
        "gasPrice": w3.to_wei("1", "gwei"),
        "chainId": CHAIN_ID,
    })
    signed = w3.eth.account.sign_transaction(tx, PRIVATE_KEY)
    tx_hash = w3.eth.send_raw_transaction(signed.rawTransaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash)
    DEPLOYED_ADDRESS = receipt.contractAddress

    with open("deployed.json", "w") as f:
        json.dump({"address": DEPLOYED_ADDRESS, "tx": tx_hash.hex()}, f, indent=2)

# Deploy once on boot (if we don't already have deployed.json)
if os.path.exists("deployed.json"):
    try:
        with open("deployed.json") as f:
            DEPLOYED_ADDRESS = json.load(f)["address"]
    except Exception:
        deploy_contract()
else:
    deploy_contract()

@app.get("/", response_class=HTMLResponse)
def home():
    addr = DEPLOYED_ADDRESS or "0x0000000000000000000000000000000000000000"
    return f"""
    <!doctype html>
    <html><head>
      <meta charset="utf-8" />
      <title>GoldBarTether – Contract Address</title>
      <style>
        body {{ background:#0b0b0b; color:#f6d26b; font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; display:flex; align-items:center; justify-content:center; height:100vh; margin:0; }}
        .card {{ border:1px solid #6b5b2e; padding:24px 28px; border-radius:14px; background:#121212; box-shadow:0 6px 30px rgba(0,0,0,.6); text-align:center; }}
        h1 {{ margin:0 0 12px; font-size:22px; font-weight:700; }}
        code {{ font-size:16px; background:#1a1a1a; padding:8px 12px; border-radius:10px; display:inline-block; }}
        button {{ margin-top:14px; padding:10px 14px; border-radius:10px; border:1px solid #6b5b2e; background:#1a1a1a; color:#f6d26b; cursor:pointer; }}
        button:active {{ transform: translateY(1px); }}
      </style>
    </head><body>
      <div class="card">
        <h1>GoldBarTether Contract Address</h1>
        <code id="addr">{addr}</code><br/>
        <button onclick="navigator.clipboard.writeText(document.getElementById('addr').innerText)">Copy</button>
      </div>
    </body></html>
    """

@app.get("/address")
def address_json():
    return {"address": DEPLOYED_ADDRESS}
