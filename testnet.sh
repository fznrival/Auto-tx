#!/bin/bash

# Warna untuk output
BLUE='\033[0;34m'
WHITE='\033[0;97m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
RESET='\033[0m'

# Direktori skrip saat ini
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit

# Fungsi untuk menampilkan timestamp
log_timestamp() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${RESET} $1"
}

# Pastikan jq dan Node.js terinstal
if ! command -v jq &> /dev/null; then
    log_timestamp "${YELLOW}Menginstal jq...${RESET}"
    sudo apt-get install -y jq
fi

if ! command -v node &> /dev/null; then
    log_timestamp "${YELLOW}Node.js belum terinstal. Menginstal Node.js...${RESET}"
    curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
    sudo apt-get install -y nodejs
fi

# Buat direktori sementara untuk proyek
TEMP_DIR="$SCRIPT_DIR/temp_project"
if [ ! -d "$TEMP_DIR" ]; then
    mkdir "$TEMP_DIR"
    cd "$TEMP_DIR" || exit
    log_timestamp "${YELLOW}Menginisialisasi proyek sementara dan menginstal ethers v5...${RESET}"
    npm init -y > /dev/null 2>&1
    npm install ethers@5 > /dev/null 2>&1
else
    cd "$TEMP_DIR" || exit
fi

# Fungsi untuk memeriksa konektivitas jaringan
check_network_connectivity() {
    local rpc_url=$1
    local domain=$(echo "$rpc_url" | sed -E 's#https?://([^/]+).*#\1#')
    
    log_timestamp "${YELLOW}Memeriksa konektivitas jaringan ke $domain...${RESET}"
    
    if ping -c 1 -W 5 "$domain" &> /dev/null; then
        log_timestamp "${GREEN}Konektivitas jaringan OK${RESET}"
        return 0
    fi
    
    if curl --connect-timeout 10 -sI "$rpc_url" &> /dev/null; then
        log_timestamp "${GREEN}RPC endpoint dapat dijangkau${RESET}"
        return 0
    fi
    
    log_timestamp "${RED}Tidak dapat terhubung ke RPC endpoint $rpc_url.${RESET}"
    return 1
}

# Fungsi untuk mengirim transaksi
send_transaction() {
    local rpc_url=$1
    local chain_id=$2
    local private_key=$3
    local recipient_address=$4
    local min_amount=$5
    local max_amount=$6
    local explorer_url=$7
    local use_random_recipient=$8
    local save_to_file=$9

    log_timestamp "${YELLOW}Menyiapkan pengiriman transaksi di jaringan dengan RPC: $rpc_url${RESET}"

    # Membuat script Node.js sementara untuk mengirim TX
    cat <<EOL > "$TEMP_DIR/send_tx.js"
const ethers = require("ethers");
const fs = require("fs");

async function sendTx() {
    try {
        console.log("Versi ethers yang digunakan:", ethers.version);
        const provider = new ethers.providers.JsonRpcProvider("$rpc_url");
        const wallet = new ethers.Wallet("$private_key", provider);

        let recipient = "$recipient_address";
        const min = ethers.utils.parseEther("$min_amount");
        const max = ethers.utils.parseEther("$max_amount");
        const range = max.sub(min);
        const randomValue = ethers.BigNumber.from(ethers.utils.randomBytes(32)).mod(range.add(1));
        const amount = min.add(randomValue);
        console.log("Jumlah acak yang dikirim (ETH):", ethers.utils.formatEther(amount));

        // Jika menggunakan penerima acak dari penerima.txt
        if ("$use_random_recipient" === "y") {
            const recipients = fs.readFileSync("$SCRIPT_DIR/penerima.txt", "utf8")
                .split("\n")
                .filter(line => line.trim() !== "" && line.match(/^0x[a-fA-F0-9]{40}/));
            if (recipients.length > 0) {
                recipient = recipients[Math.floor(Math.random() * recipients.length)].split(",")[0].trim();
                console.log("Penerima acak dari penerima.txt:", recipient);
            } else {
                console.error("File penerima.txt kosong atau tidak ada alamat valid!");
                process.exit(1);
            }
        }
        // Jika menggunakan penerima acak dan menyimpan ke file
        else if ("$save_to_file" === "y") {
            const randomWallet = ethers.Wallet.createRandom();
            recipient = randomWallet.address;
            const randomPrivateKey = randomWallet.privateKey;
            console.log("Penerima acak yang dihasilkan:", recipient);
            console.log("Private key untuk penerima:", randomPrivateKey);

            const tx = {
                to: recipient,
                value: amount,
                chainId: $chain_id
            };

            const txResponse = await wallet.sendTransaction(tx);
            console.log("Transaksi dikirim. Hash: " + txResponse.hash);
            await txResponse.wait();
            console.log("Transaksi dikonfirmasi di: $explorer_url/tx/" + txResponse.hash);

            fs.appendFileSync("$SCRIPT_DIR/penerima.txt", recipient + "," + randomPrivateKey + "\n");
            console.log("Alamat dan private key disimpan ke penerima.txt");
            return;
        }

        const tx = {
            to: recipient,
            value: amount,
            chainId: $chain_id
        };

        const txResponse = await wallet.sendTransaction(tx);
        console.log("Transaksi dikirim. Hash: " + txResponse.hash);
        await txResponse.wait();
        console.log("Transaksi dikonfirmasi di: $explorer_url/tx/" + txResponse.hash);
    } catch (error) {
        console.error("Error saat mengirim transaksi:", error.message);
        process.exit(1);
    }
}

sendTx();
EOL

    # Jalankan script Node.js dari direktori sementara
    log_timestamp "${YELLOW}Mengirim transaksi...${RESET}"
    if OUTPUT=$(node "$TEMP_DIR/send_tx.js" 2>&1); then
        log_timestamp "${GREEN}Transaksi berhasil:${RESET}"
        echo "$OUTPUT" | while IFS= read -r line; do
            if [[ "$line" =~ "Versi ethers yang digunakan:" ]]; then
                VERSION=$(echo "$line" | grep -oP 'Versi ethers yang digunakan: \K(.+)$')
                log_timestamp "${WHITE}Versi ethers: ${BLUE}$VERSION${RESET}"
            elif [[ "$line" =~ "Penerima acak dari penerima.txt:" ]]; then
                RECIPIENT=$(echo "$line" | grep -oP 'Penerima acak dari penerima.txt: \K(0x[a-fA-F0-9]+)')
                log_timestamp "${WHITE}Penerima: ${BLUE}$RECIPIENT${RESET}"
            elif [[ "$line" =~ "Penerima acak yang dihasilkan:" ]]; then
                RECIPIENT=$(echo "$line" | grep -oP 'Penerima acak yang dihasilkan: \K(0x[a-fA-F0-9]+)')
                log_timestamp "${WHITE}Penerima acak: ${BLUE}$RECIPIENT${RESET}"
            elif [[ "$line" =~ "Private key untuk penerima:" ]]; then
                PRIVATE_KEY=$(echo "$line" | grep -oP 'Private key untuk penerima: \K(0x[a-fA-F0-9]+)')
                log_timestamp "${WHITE}Private key: ${BLUE}$PRIVATE_KEY${RESET}"
            elif [[ "$line" =~ "Jumlah acak yang dikirim (ETH):" ]]; then
                AMOUNT_SENT=$(echo "$line" | grep -oP 'Jumlah acak yang dikirim \(ETH\): \K(.+)$')
                log_timestamp "${WHITE}Jumlah dikirim: ${BLUE}$AMOUNT_SENT ETH${RESET}"
            elif [[ "$line" =~ "Transaksi dikirim. Hash:" ]]; then
                TX_HASH=$(echo "$line" | grep -oP 'Hash: \K(0x[a-fA-F0-9]+)')
                log_timestamp "${WHITE}Hash TX: ${BLUE}$TX_HASH${RESET}"
            elif [[ "$line" =~ "Transaksi dikonfirmasi di:" ]]; then
                TX_URL=$(echo "$line" | grep -oP 'Transaksi dikonfirmasi di: \K(.+)$')
                log_timestamp "${WHITE}Lihat di explorer: ${BLUE}$TX_URL${RESET}"
            elif [[ "$line" =~ "Alamat dan private key disimpan ke penerima.txt" ]]; then
                log_timestamp "${WHITE}Data disimpan ke penerima.txt${RESET}"
            fi
        done
    else
        log_timestamp "${RED}Gagal mengirim transaksi:${RESET}"
        echo "$OUTPUT"
        return 1
    fi

    # Hapus script sementara
    rm -f "$TEMP_DIR/send_tx.js"
    return 0
}

# Fungsi utama
main() {
    if [ ! -f "$SCRIPT_DIR/testnet.json" ]; then
        log_timestamp "${RED}File testnet.json tidak ditemukan di $SCRIPT_DIR!${RESET}"
        exit 1
    fi

    NETWORK_COUNT=$(jq -r '. | length' "$SCRIPT_DIR/testnet.json")
    log_timestamp "${YELLOW}Menemukan $NETWORK_COUNT jaringan di testnet.json${RESET}"

    read -p "Masukkan Private Key pengirim: " PRIVATE_KEY
    if [ -z "$PRIVATE_KEY" ]; then
        log_timestamp "${RED}Private Key wajib diisi!${RESET}"
        exit 1
    fi

    # Prompt untuk memilih opsi
    log_timestamp "${YELLOW}Pilih opsi pengiriman:${RESET}"
    echo "1. Gunakan jumlah token acak (min dan max) dengan alamat tetap"
    echo "2. Gunakan penerima acak dari penerima.txt dengan jumlah acak"
    echo "3. Kirim ke alamat acak dan simpan ke penerima.txt dengan jumlah acak"
    read -p "Masukkan pilihan (1, 2, atau 3): " SEND_OPTION
    if [[ "$SEND_OPTION" != "1" && "$SEND_OPTION" != "2" && "$SEND_OPTION" != "3" ]]; then
        log_timestamp "${RED}Pilihan harus 1, 2, atau 3!${RESET}"
        exit 1
    fi

    read -p "Masukkan jumlah minimal ETH yang ingin dikirim (contoh: 0.1): " MIN_AMOUNT
    if ! [[ "$MIN_AMOUNT" =~ ^[0-9]*\.?[0-9]+$ ]] || (( $(echo "$MIN_AMOUNT <= 0" | bc -l) )); then
        log_timestamp "${RED}Jumlah minimal harus berupa angka positif!${RESET}"
        exit 1
    fi
    read -p "Masukkan jumlah maksimal ETH yang ingin dikirim (contoh: 0.5): " MAX_AMOUNT
    if ! [[ "$MAX_AMOUNT" =~ ^[0-9]*\.?[0-9]+$ ]] || (( $(echo "$MAX_AMOUNT <= $MIN_AMOUNT" | bc -l) )); then
        log_timestamp "${RED}Jumlah maksimal harus lebih besar dari jumlah minimal!${RESET}"
        exit 1
    fi

    if [ "$SEND_OPTION" = "1" ]; then
        read -p "Masukkan alamat penerima: " RECIPIENT_ADDRESS
        if ! [[ "$RECIPIENT_ADDRESS" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
            log_timestamp "${RED}Alamat penerima tidak valid!${RESET}"
            exit 1
        fi
        USE_RANDOM_RECIPIENT="n"
        SAVE_TO_FILE="n"
    elif [ "$SEND_OPTION" = "2" ]; then
        if [ ! -f "$SCRIPT_DIR/penerima.txt" ]; then
            log_timestamp "${RED}File penerima.txt tidak ditemukan di $SCRIPT_DIR!${RESET}"
            exit 1
        fi
        RECIPIENT_ADDRESS="0x0"  # Placeholder, akan diganti secara acak
        USE_RANDOM_RECIPIENT="y"
        SAVE_TO_FILE="n"
    else  # Opsi 3
        RECIPIENT_ADDRESS="0x0"  # Placeholder, akan diganti secara acak
        USE_RANDOM_RECIPIENT="n"
        SAVE_TO_FILE="y"
    fi

    read -p "Berapa kali pengiriman TX per jaringan? " TX_COUNT
    if ! [[ "$TX_COUNT" =~ ^[0-9]+$ ]] || [ "$TX_COUNT" -lt 1 ]; then
        log_timestamp "${RED}Jumlah pengiriman harus berupa angka positif!${RESET}"
        exit 1
    fi

    for ((network_index=0; network_index<NETWORK_COUNT; network_index++)); do
        RPC_URL=$(jq -r ".[$network_index].rpcUrl" "$SCRIPT_DIR/testnet.json")
        CHAIN_ID=$(jq -r ".[$network_index].chainId" "$SCRIPT_DIR/testnet.json")
        EXPLORER_URL=$(jq -r ".[$network_index].explorer" "$SCRIPT_DIR/testnet.json")
        NETWORK_NAME=$(jq -r ".[$network_index].name" "$SCRIPT_DIR/testnet.json")

        if [ "$RPC_URL" == "null" ] || [ "$CHAIN_ID" == "null" ] || [ "$EXPLORER_URL" == "null" ]; then
            log_timestamp "${RED}Data tidak lengkap untuk jaringan #$((network_index + 1)) di testnet.json. Melewati...${RESET}"
            continue
        fi

        log_timestamp "${YELLOW}Memproses jaringan: $NETWORK_NAME${RESET}"

        if check_network_connectivity "$RPC_URL"; then
            tx_iteration=0
            while [ $tx_iteration -lt $TX_COUNT ]; do
                ((tx_iteration++))
                log_timestamp "${YELLOW}Pengiriman TX ke-$tx_iteration dari $TX_COUNT untuk $NETWORK_NAME${RESET}"
                send_transaction "$RPC_URL" "$CHAIN_ID" "$PRIVATE_KEY" "$RECIPIENT_ADDRESS" "$MIN_AMOUNT" "$MAX_AMOUNT" "$EXPLORER_URL" "$USE_RANDOM_RECIPIENT" "$SAVE_TO_FILE" || {
                    log_timestamp "${RED}Pengiriman TX gagal untuk $NETWORK_NAME. Melanjutkan ke jaringan berikutnya...${RESET}"
                    break
                }
                if [ $tx_iteration -lt $TX_COUNT ]; then
                    log_timestamp "${YELLOW}Menunggu 10 detik sebelum pengiriman berikutnya...${RESET}"
                    sleep 10
                fi
            done
            log_timestamp "${GREEN}Selesai pengiriman TX untuk $NETWORK_NAME (${TX_COUNT} kali)${RESET}"
        else
            log_timestamp "${RED}Koneksi gagal untuk $NETWORK_NAME. Melewati jaringan ini.${RESET}"
        fi

        if [ $network_index -lt $((NETWORK_COUNT - 1)) ]; then
            log_timestamp "${YELLOW}Menunggu 10 detik sebelum memproses jaringan berikutnya...${RESET}"
            sleep 10
        fi
    done

    log_timestamp "${GREEN}Semua jaringan selesai diproses!${RESET}"
}

# Menangani sinyal interrupt (Ctrl+C)
trap 'echo -e "\n${RED}Script dihentikan oleh user${RESET}"; rm -rf "$TEMP_DIR"; exit 0' INT

# Eksekusi program
main

# Bersihkan direktori sementara setelah selesai
rm -rf "$TEMP_DIR"
