#!/bin/bash

# =============================================================================
# Envanter Yönetim Sistemi
# Versiyon: 1.0
# Açıklama: Zenity tabanlı basit envanter yönetim sistemi
# =============================================================================

# -----------------------------------------------------------------------------
# Konfigürasyon ve Sabitler
# -----------------------------------------------------------------------------
readonly DATA_DIR="$HOME/.minimal_inventory"
readonly INVENTORY_FILE="$DATA_DIR/inventory.csv"
readonly USERS_FILE="$DATA_DIR/users.csv"
readonly HISTORY_FILE="$DATA_DIR/history.log"
readonly LOCKED_USERS_FILE="$DATA_DIR/locked_users.txt"
readonly BACKUP_DIR="$DATA_DIR/backups"
readonly MAX_LOGIN_ATTEMPTS=3
readonly FILE_PERMISSIONS=600  # Sadece sahibi okuyup yazabilir

# CSV Başlıkları
readonly INVENTORY_HEADER="id,name,category,stock,price,last_updated"
readonly USERS_HEADER="id,username,fullname,role,password,last_login,failed_attempts"

# Geçerli kullanıcı bilgileri
CURRENT_USER=""
CURRENT_ROLE=""

# -----------------------------------------------------------------------------
# Yardımcı Fonksiyonlar
# -----------------------------------------------------------------------------

# Benzersiz ID üretir
generate_id() {
    echo $(date +%s%N | cut -b1-10)
}

# Sayısal değer kontrolü yapar
validate_number() {
    local input=$1
    if [[ "$input" =~ ^[0-9]+(\.[0-9]{1,2})?$ ]] && [ "$(echo "$input > 0" | bc)" -eq 1 ]; then
        return 0
    fi
    return 1
}

# Metin değer kontrolü yapar
validate_text() {
    local input=$1
    if [[ "$input" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 0
    fi
    return 1
}

# İlerleme çubuğu gösterir
show_progress() {
    local message="$1"
    local duration="$2"
    (
    for i in $(seq 0 10 100); do
        echo "$i"
        echo "# $message ($i%)"
        sleep $(echo "scale=2; $duration/10" | bc)
    done
    ) | zenity --progress \
        --title="İşlem Durumu" \
        --text="İşlem başlatılıyor..." \
        --percentage=0 \
        --auto-close \
        --no-cancel
}

# -----------------------------------------------------------------------------
# Güvenlik Fonksiyonları
# -----------------------------------------------------------------------------

# Kullanıcı yetkisini kontrol eder
check_permission() {
    local required_role="$1"
    if [ "$CURRENT_ROLE" != "$required_role" ] && [ "$CURRENT_ROLE" != "admin" ]; then
        zenity --error \
            --title="Yetki Hatası" \
            --text="Bu işlem için yetkiniz bulunmamaktadır."
        log_action "auth" "error" "Permission denied: $CURRENT_USER tried to access $required_role function"
        return 1
    fi
    return 0
}

# Kullanıcının kilitli olup olmadığını kontrol eder
is_user_locked() {
    local username="$1"
    grep -q "^$username$" "$LOCKED_USERS_FILE"
    return $?
}

# Kullanıcıyı kilitler
lock_user() {
    local username="$1"
    echo "$username" >> "$LOCKED_USERS_FILE"
    log_action "auth" "warning" "Account locked: $username"
}

# Kullanıcı kilidini açar
unlock_user() {
    local username="$1"
    if [ "$CURRENT_ROLE" != "admin" ]; then
        zenity --error \
            --title="Hata" \
            --text="Bu işlem için yönetici yetkisi gereklidir."
        return 1
    fi
    sed -i "" "/^$username$/d" "$LOCKED_USERS_FILE"
    log_action "auth" "success" "Account unlocked: $username"
}

# -----------------------------------------------------------------------------
# Dosya Yönetimi Fonksiyonları
# -----------------------------------------------------------------------------

# Dosya izinlerini ayarlar
set_secure_permissions() {
    local file="$1"
    chmod "$FILE_PERMISSIONS" "$file"
}

# CSV dosyalarının bütünlüğünü kontrol eder
check_csv_integrity() {
    local file="$1"
    local header="$2"
    
    if [ ! -s "$file" ]; then
        log_action "system" "error" "CSV file is empty or missing: $file" 1001
        echo "$header" > "$file"
        set_secure_permissions "$file"
        return 1
    fi
    
    local first_line=$(head -n 1 "$file")
    if [ "$first_line" != "$header" ]; then
        log_action "system" "error" "Invalid CSV header in $file" 1002
        local backup_file="${file}.$(date '+%Y%m%d_%H%M%S').bak"
        cp "$file" "$backup_file"
        echo "$header" > "$file"
        tail -n +2 "$backup_file" >> "$file"
        set_secure_permissions "$file"
        return 1
    fi
    
    return 0
}

# Gerekli dosyaları oluşturur
init_files() {
    mkdir -p "$DATA_DIR" "$BACKUP_DIR"
    
    # inventory.csv oluştur
    if [ ! -f "$INVENTORY_FILE" ]; then
        echo "$INVENTORY_HEADER" > "$INVENTORY_FILE"
        log_action "system" "info" "Created inventory.csv with header"
    fi
    
    # users.csv oluştur ve varsayılan admin ekle
    if [ ! -f "$USERS_FILE" ]; then
        echo "$USERS_HEADER" > "$USERS_FILE"
        local admin_id=$(generate_id)
        local admin_pass=$(echo -n "admin123" | md5sum | cut -d' ' -f1)
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$admin_id,admin,Administrator,admin,$admin_pass,$timestamp,0" >> "$USERS_FILE"
        log_action "system" "info" "Created users.csv with default admin user"
    fi
    
    # history.log oluştur
    if [ ! -f "$HISTORY_FILE" ]; then
        echo "# Envanter Yönetim Sistemi - İşlem Kayıtları" > "$HISTORY_FILE"
        echo "# Format: [Tarih Saat] [Kullanıcı] [İşlem] [Durum] [Hata Kodu] Mesaj" >> "$HISTORY_FILE"
        echo "# Başlangıç: $(date '+%Y-%m-%d %H:%M:%S')" >> "$HISTORY_FILE"
        echo "--------------------------------------------------------------------------------" >> "$HISTORY_FILE"
    fi
    
    # locked_users.txt oluştur
    touch "$LOCKED_USERS_FILE"
    
    # Tüm dosyalara güvenli izinler ata
    set_secure_permissions "$INVENTORY_FILE"
    set_secure_permissions "$USERS_FILE"
    set_secure_permissions "$HISTORY_FILE"
    set_secure_permissions "$LOCKED_USERS_FILE"
}

# -----------------------------------------------------------------------------
# Loglama Fonksiyonları
# -----------------------------------------------------------------------------

# İşlem kaydı tutar
log_action() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local action=$1
    local status=$2
    local message=$3
    local error_code=${4:-0}
    local user=${CURRENT_USER:-"system"}
    
    local log_entry="[$timestamp] [$user] [$action] [$status] [$error_code] $message"
    echo "$log_entry" >> "$HISTORY_FILE"
    
    # Log rotasyonu
    if [ $(wc -l < "$HISTORY_FILE") -gt 1000 ]; then
        local backup_log="${HISTORY_FILE}.$(date '+%Y%m%d_%H%M%S')"
        cp "$HISTORY_FILE" "$backup_log"
        (head -n 4 "$HISTORY_FILE"; echo "# Rotated at: $(date '+%Y-%m-%d %H:%M:%S')"; \
         echo "--------------------------------------------------------------------------------"; \
         tail -n 1000 "$HISTORY_FILE") > "${HISTORY_FILE}.tmp"
        mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
        log_action "system" "info" "Log rotated, old log saved as $(basename "$backup_log")"
    fi
}

# Log kayıtlarını formatlar ve gösterir
format_logs() {
    local log_content=""
    local filter_type=${1:-"all"}
    
    log_content="<span size='large'>İşlem Kayıtları</span>\n"
    log_content+="<span size='small'>Filtre: $filter_type</span>\n\n"
    
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        
        case "$filter_type" in
            "error")
                [[ ! "$line" =~ "[error]"|"[ERROR]" ]] && continue
                ;;
            "success")
                [[ ! "$line" =~ "[success]"|"[SUCCESS]" ]] && continue
                ;;
            "warning")
                [[ ! "$line" =~ "[warning]"|"[WARNING]" ]] && continue
                ;;
        esac
        
        case "$line" in
            *"[error]"*|*"[ERROR]"*)
                log_content+="<span color='red'>$line</span>\n"
                ;;
            *"[success]"*|*"[SUCCESS]"*)
                log_content+="<span color='green'>$line</span>\n"
                ;;
            *"[warning]"*|*"[WARNING]"*)
                log_content+="<span color='orange'>$line</span>\n"
                ;;
            *)
                log_content+="$line\n"
                ;;
        esac
    done < "$HISTORY_FILE"
    
    echo -e "$log_content"
}

# -----------------------------------------------------------------------------
# Ürün Yönetimi Fonksiyonları
# -----------------------------------------------------------------------------

# Ürün ekler
add_product() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    local product_info=$(zenity --forms \
        --title="Ürün Ekle" \
        --text="Ürün bilgilerini girin" \
        --separator="|" \
        --add-entry="Ürün Adı (boşluk kullanmayın)" \
        --add-entry="Kategori (boşluk kullanmayın)" \
        --add-entry="Stok Miktarı (0 veya pozitif sayı)" \
        --add-entry="Birim Fiyat (0 veya pozitif sayı)" \
        2>/dev/null)
    
    if [ $? -eq 0 ]; then
        IFS="|" read -r name category stock price <<< "$product_info"
        
        # Show progress while validating
        show_progress "Ürün bilgileri doğrulanıyor" 1
        
        # Validate input
        if ! validate_text "$name" || ! validate_text "$category"; then
            zenity --error \
                --text="Ürün adı ve kategori sadece harf, rakam, alt çizgi ve tire içerebilir."
            log_action "add_product" "error" "Invalid product name or category: $name, $category"
            return 1
        fi
        
        if ! validate_number "$stock" || ! validate_number "$price"; then
            zenity --error \
                --text="Stok ve fiyat 0 veya pozitif sayı olmalıdır."
            log_action "add_product" "error" "Invalid stock/price values"
            return 1
        fi
        
        # Check for duplicate product name
        if grep -q "^[^,]*,$name," "$INVENTORY_FILE"; then
            zenity --error \
                --text="Bu ürün adıyla başka bir kayıt bulunmaktadır."
            log_action "add_product" "error" "Duplicate product: $name"
            return 1
        fi
        
        # Show progress while adding
        show_progress "Ürün ekleniyor" 1
        
        # Add product with unique ID and timestamp
        local id=$(generate_id)
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$id,$name,$category,$stock,$price,$timestamp" >> "$INVENTORY_FILE"
        
        zenity --info \
            --text="Ürün başarıyla eklendi."
        log_action "add_product" "success" "Added product: $name"
    fi
}

# Ürünleri listeler
list_products() {
    if [ ! -s "$INVENTORY_FILE" ]; then
        zenity --info \
            --text="Kayıtlı ürün bulunmamaktadır."
        return
    fi
    
    # Create temporary file for product data
    local tmp_file=$(mktemp)
    
    # Prepare data in table format
    (tail -n +2 "$INVENTORY_FILE" | while IFS=, read -r id name category stock price timestamp; do
        local total_value=$(echo "$stock * $price" | bc)
        echo "$name|$category|$stock|$price|$total_value|$timestamp"
    done) > "$tmp_file"
    
    # Show table with sorting capability
    zenity --list \
        --title="Ürün Listesi" \
        --width=800 \
        --height=400 \
        --text="<span size='large'>Ürün Listesi</span>" \
        --column="Ürün Adı" \
        --column="Kategori" \
        --column="Stok" \
        --column="Birim Fiyat (₺)" \
        --column="Toplam Değer (₺)" \
        --column="Son Güncelleme" \
        --print-column="ALL" \
        --separator="|" \
        $(cat "$tmp_file") \
        2>/dev/null
    
    rm -f "$tmp_file"
}

# Ürün günceller
update_product() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    local products=$(tail -n +2 "$INVENTORY_FILE" | cut -d',' -f2 | sort)
    if [ -z "$products" ]; then
        zenity --info \
            --text="Güncellenebilecek ürün bulunmamaktadır."
        return
    fi
    
    local product_name=$(zenity --list \
        --title="Ürün Güncelle" \
        --text="Güncellenecek ürünü seçin:" \
        --column="Ürün Adı" \
        $products \
        2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local current_data=$(grep "^[^,]*,$product_name," "$INVENTORY_FILE")
        IFS=, read -r id name category stock price timestamp <<< "$current_data"
        
        local update_info=$(zenity --forms \
            --title="Ürün Güncelle" \
            --text="'$product_name' ürününün bilgilerini güncelleyin" \
            --separator="|" \
            --add-entry="Kategori (mevcut: $category)" \
            --add-entry="Stok Miktarı (mevcut: $stock)" \
            --add-entry="Birim Fiyat (mevcut: $price)" \
            2>/dev/null)
        
        if [ $? -eq 0 ]; then
            IFS="|" read -r new_category new_stock new_price <<< "$update_info"
            
            # Validate input
            if [ -n "$new_category" ] && ! validate_text "$new_category"; then
                zenity --error \
                    --text="Kategori sadece harf, rakam, alt çizgi ve tire içerebilir."
                return 1
            fi
            
            if [ -n "$new_stock" ] && ! validate_number "$new_stock"; then
                zenity --error \
                    --text="Geçersiz stok miktarı."
                return 1
            fi
            
            if [ -n "$new_price" ] && ! validate_number "$new_price"; then
                zenity --error \
                    --text="Geçersiz fiyat."
                return 1
            fi
            
            # Use current values if new ones are empty
            new_category=${new_category:-$category}
            new_stock=${new_stock:-$stock}
            new_price=${new_price:-$price}
            local new_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
            
            # Create backup before update
            cp "$INVENTORY_FILE" "$INVENTORY_FILE.bak"
            
            # Update product
            sed -i "" "s/^$id,$name,$category,$stock,$price,$timestamp/$id,$name,$new_category,$new_stock,$new_price,$new_timestamp/" "$INVENTORY_FILE"
            
            zenity --info \
                --text="Ürün başarıyla güncellendi."
            log_action "update_product" "success" "Updated product: $name"
        fi
    fi
}

# Ürün siler
delete_product() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    local products=$(tail -n +2 "$INVENTORY_FILE" | cut -d',' -f2 | sort)
    if [ -z "$products" ]; then
        zenity --info \
            --text="Silinebilecek ürün bulunmamaktadır."
        return
    fi
    
    local product_name=$(zenity --list \
        --title="Ürün Sil" \
        --text="Silinecek ürünü seçin:" \
        --column="Ürün Adı" \
        $products \
        2>/dev/null)
    
    if [ $? -eq 0 ]; then
        if zenity --question \
            --text="'$product_name' ürününü silmek istediğinizden emin misiniz?"; then
            
            # Create backup before deletion
            cp "$INVENTORY_FILE" "$INVENTORY_FILE.bak"
            
            # Delete product
            grep -v "^[^,]*,$product_name," "$INVENTORY_FILE" > "$INVENTORY_FILE.tmp"
            mv "$INVENTORY_FILE.tmp" "$INVENTORY_FILE"
            
            zenity --info \
                --text="Ürün başarıyla silindi."
            log_action "delete_product" "success" "Deleted product: $product_name"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Rapor Fonksiyonları
# -----------------------------------------------------------------------------

# Düşük stoklu ürünleri gösterir
show_low_stock_report() {
    local threshold=$(zenity --scale \
        --title="Stok Eşik Değeri" \
        --text="Minimum stok miktarını seçin:" \
        --min-value=1 \
        --max-value=100 \
        --value=20 \
        --step=5 \
        2>/dev/null)
    
    if [ $? -eq 0 ]; then
        # Create temporary file for filtered data
        local tmp_file=$(mktemp)
        
        # Filter and format data
        (tail -n +2 "$INVENTORY_FILE" | while IFS=, read -r id name category stock price timestamp; do
            if [ "$stock" -lt "$threshold" ]; then
                local total_value=$(echo "$stock * $price" | bc)
                echo "$name|$category|$stock|$price|$total_value|$timestamp"
            fi
        done) > "$tmp_file"
        
        if [ ! -s "$tmp_file" ]; then
            zenity --info \
                --text="Eşik değerin ($threshold) altında ürün bulunmamaktadır."
            rm -f "$tmp_file"
            return
        fi
        
        # Show table
        zenity --list \
            --title="Düşük Stok Raporu (Eşik: $threshold)" \
            --width=800 \
            --height=400 \
            --text="<span size='large'>Düşük Stok Raporu</span>\nEşik değeri: $threshold" \
            --column="Ürün Adı" \
            --column="Kategori" \
            --column="Stok" \
            --column="Birim Fiyat (₺)" \
            --column="Toplam Değer (₺)" \
            --column="Son Güncelleme" \
            --print-column="ALL" \
            --separator="|" \
            $(cat "$tmp_file") \
            2>/dev/null
        
        rm -f "$tmp_file"
    fi
}

# Yüksek stoklu ürünleri gösterir
show_high_stock_report() {
    local threshold=$(zenity --scale \
        --title="Stok Eşik Değeri" \
        --text="Minimum stok miktarını seçin:" \
        --min-value=50 \
        --max-value=500 \
        --value=100 \
        --step=50 \
        2>/dev/null)
    
    if [ $? -eq 0 ]; then
        # Create temporary file for filtered data
        local tmp_file=$(mktemp)
        
        # Filter and format data
        (tail -n +2 "$INVENTORY_FILE" | while IFS=, read -r id name category stock price timestamp; do
            if [ "$stock" -gt "$threshold" ]; then
                local total_value=$(echo "$stock * $price" | bc)
                echo "$name|$category|$stock|$price|$total_value|$timestamp"
            fi
        done) > "$tmp_file"
        
        if [ ! -s "$tmp_file" ]; then
            zenity --info \
                --text="Eşik değerin ($threshold) üstünde ürün bulunmamaktadır."
            rm -f "$tmp_file"
            return
        fi
        
        # Show table
        zenity --list \
            --title="Yüksek Stok Raporu (Eşik: $threshold)" \
            --width=800 \
            --height=400 \
            --text="<span size='large'>Yüksek Stok Raporu</span>\nEşik değeri: $threshold" \
            --column="Ürün Adı" \
            --column="Kategori" \
            --column="Stok" \
            --column="Birim Fiyat (₺)" \
            --column="Toplam Değer (₺)" \
            --column="Son Güncelleme" \
            --print-column="ALL" \
            --separator="|" \
            $(cat "$tmp_file") \
            2>/dev/null
        
        rm -f "$tmp_file"
    fi
}

# Kategori bazlı stok raporu gösterir
show_category_report() {
    # Create temporary file for category data
    local tmp_file=$(mktemp)
    
    # Calculate category totals
    (echo "Kategori|Ürün Sayısı|Toplam Stok|Toplam Değer (₺)"
    tail -n +2 "$INVENTORY_FILE" | awk -F, '{
        categories[$3]++;
        stocks[$3]+=$4;
        values[$3]+=$4*$5
    } END {
        for (cat in categories) {
            printf "%s|%d|%d|%.2f\n", cat, categories[cat], stocks[cat], values[cat]
        }
    }') > "$tmp_file"
    
    # Show table
    zenity --list \
        --title="Kategori Bazlı Stok Raporu" \
        --width=600 \
        --height=400 \
        --text="<span size='large'>Kategori Bazlı Stok Raporu</span>" \
        --column="Kategori" \
        --column="Ürün Sayısı" \
        --column="Toplam Stok" \
        --column="Toplam Değer (₺)" \
        --separator="|" \
        $(tail -n +2 "$tmp_file") \
        2>/dev/null
    
    rm -f "$tmp_file"
}

# -----------------------------------------------------------------------------
# Menü Fonksiyonları
# -----------------------------------------------------------------------------

# Ana menüyü gösterir
show_main_menu() {
    while true; do
        local choice=$(zenity --list \
            --title="Ana Menü" \
            --width=400 \
            --height=500 \
            --text="<span size='large'>Envanter Yönetim Sistemi</span>\nKullanıcı: $CURRENT_USER (${CURRENT_ROLE})" \
            --column="İşlem" \
            "🛍️  Ürün İşlemleri" \
            "📊  Raporlar" \
            "👥  Kullanıcı Yönetimi" \
            "⚙️  Sistem Yönetimi" \
            "❌  Çıkış" \
            2>/dev/null)
        
        case "$choice" in
            *"Ürün İşlemleri"*) show_product_menu ;;
            *"Raporlar"*) show_reports_menu ;;
            *"Kullanıcı"*) show_user_menu ;;
            *"Sistem"*) show_system_menu ;;
            *"Çıkış"*)
                log_action "system" "info" "User logged out: $CURRENT_USER"
                zenity --info \
                    --text="Oturumunuz kapatılıyor. İyi günler!"
                exit 0
                ;;
            *) break ;;
        esac
    done
}

# Ürün işlemleri menüsünü gösterir
show_product_menu() {
    while true; do
        local choice=$(zenity --list \
            --title="Ürün İşlemleri" \
            --width=400 \
            --height=400 \
            --text="<span size='large'>Ürün İşlemleri</span>" \
            --column="İşlem" \
            "➕  Ürün Ekle" \
            "📝  Ürün Listele" \
            "🔄  Ürün Güncelle" \
            "❌  Ürün Sil" \
            "⬅️  Ana Menü" \
            2>/dev/null)
        
        case "$choice" in
            *"Ekle"*) add_product ;;
            *"Listele"*) list_products ;;
            *"Güncelle"*) update_product ;;
            *"Sil"*) delete_product ;;
            *"Ana Menü"*|*) break ;;
        esac
    done
}

# Raporlar menüsünü gösterir
show_reports_menu() {
    while true; do
        local choice=$(zenity --list \
            --title="Raporlar" \
            --width=400 \
            --height=400 \
            --text="<span size='large'>Raporlar</span>" \
            --column="İşlem" \
            "📉  Stokta Azalan Ürünler" \
            "📈  En Yüksek Stoklu Ürünler" \
            "📊  Kategori Bazlı Rapor" \
            "⬅️  Ana Menü" \
            2>/dev/null)
        
        case "$choice" in
            *"Azalan"*) show_low_stock_report ;;
            *"Yüksek"*) show_high_stock_report ;;
            *"Kategori"*) show_category_report ;;
            *"Ana Menü"*|*) break ;;
        esac
    done
}

# Kullanıcı yönetimi menüsünü gösterir
show_user_menu() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    while true; do
        local choice=$(zenity --list \
            --title="Kullanıcı Yönetimi" \
            --width=400 \
            --height=400 \
            --text="<span size='large'>Kullanıcı Yönetimi</span>" \
            --column="İşlem" \
            "➕  Yeni Kullanıcı Ekle" \
            "📝  Kullanıcıları Listele" \
            "🔄  Kullanıcı Güncelle" \
            "❌  Kullanıcı Sil" \
            "🔓  Kullanıcı Kilidini Aç" \
            "⬅️  Ana Menü" \
            2>/dev/null)
        
        case "$choice" in
            *"Ekle"*) add_user ;;
            *"Listele"*) list_users ;;
            *"Güncelle"*) update_user ;;
            *"Sil"*) delete_user ;;
            *"Kilidini Aç"*) show_unlock_user_dialog ;;
            *"Ana Menü"*|*) break ;;
        esac
    done
}

# Sistem yönetimi menüsünü gösterir
show_system_menu() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    while true; do
        local choice=$(zenity --list \
            --title="Sistem Yönetimi" \
            --width=400 \
            --height=400 \
            --text="<span size='large'>Sistem Yönetimi</span>" \
            --column="İşlem" \
            "💾  Disk Kullanımı" \
            "📦  Yedekleme" \
            "📋  Hata Kayıtları" \
            "📤  Kayıtları Dışa Aktar" \
            "⬅️  Ana Menü" \
            2>/dev/null)
        
        case "$choice" in
            *"Disk"*) show_disk_usage ;;
            *"Yedekleme"*) backup_data ;;
            *"Hata"*) show_logs ;;
            *"Dışa Aktar"*) export_logs ;;
            *"Ana Menü"*|*) break ;;
        esac
    done
}

# Kilitli kullanıcıları gösterir ve kilit açma işlemi yapar
show_unlock_user_dialog() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    # Get list of locked users
    local locked_users=$(cat "$LOCKED_USERS_FILE")
    if [ -z "$locked_users" ]; then
        zenity --info \
            --text="Kilitli kullanıcı bulunmamaktadır."
        return
    fi
    
    local username=$(zenity --list \
        --title="Kullanıcı Kilidi Aç" \
        --text="Kilidi açılacak kullanıcıyı seçin:" \
        --column="Kullanıcı Adı" \
        $locked_users \
        2>/dev/null)
    
    if [ $? -eq 0 ]; then
        unlock_user "$username"
        zenity --info \
            --text="Kullanıcı kilidi başarıyla açıldı."
    fi
}

# -----------------------------------------------------------------------------
# Sistem Yönetimi Fonksiyonları
# -----------------------------------------------------------------------------

# Disk kullanımını gösterir
show_disk_usage() {
    # Create temporary file for disk usage data
    local tmp_file=$(mktemp)
    
    # Get disk usage data with human-readable format
    (echo "Dosya|Boyut|Değiştirilme Tarihi"
    for file in "$INVENTORY_FILE" "$USERS_FILE" "$HISTORY_FILE"; do
        local size=$(ls -lh "$file" | awk '{print $5}')
        local modified=$(ls -l "$file" | awk '{print $6, $7, $8}')
        echo "$(basename "$file")|$size|$modified"
    done
    
    echo "-------------------|----------|--------------------"
    
    # Calculate total size
    local total_bytes=$(ls -l "$INVENTORY_FILE" "$USERS_FILE" "$HISTORY_FILE" | awk '{total += $5} END {print total}')
    local total_size
    if [ $total_bytes -gt 1048576 ]; then
        total_size="$(echo "scale=2; $total_bytes/1048576" | bc)M"
    elif [ $total_bytes -gt 1024 ]; then
        total_size="$(echo "scale=2; $total_bytes/1024" | bc)K"
    else
        total_size="${total_bytes}B"
    fi
    
    echo "TOPLAM|$total_size|") > "$tmp_file"
    
    # Show table
    zenity --list \
        --title="Disk Kullanımı" \
        --width=500 \
        --height=300 \
        --text="<span size='large'>Disk Kullanımı</span>" \
        --column="Dosya" \
        --column="Boyut" \
        --column="Son Değişiklik" \
        --separator="|" \
        $(cat "$tmp_file") \
        2>/dev/null
    
    rm -f "$tmp_file"
}

# Yedekleme yapar
backup_data() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    # Create backup directory if it doesn't exist
    mkdir -p "$BACKUP_DIR"
    
    # Generate backup filename with timestamp
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_name="backup_${timestamp}"
    local backup_dir="$BACKUP_DIR/$backup_name"
    
    # Show progress dialog
    (
    echo "10"; echo "# Yedekleme dizini oluşturuluyor..."
    mkdir -p "$backup_dir"
    
    echo "30"; echo "# inventory.csv yedekleniyor..."
    cp "$INVENTORY_FILE" "$backup_dir/"
    
    echo "50"; echo "# users.csv yedekleniyor..."
    cp "$USERS_FILE" "$backup_dir/"
    
    echo "70"; echo "# history.log yedekleniyor..."
    cp "$HISTORY_FILE" "$backup_dir/"
    
    echo "90"; echo "# Yedekleme arşivi oluşturuluyor..."
    cd "$BACKUP_DIR" && tar -czf "${backup_name}.tar.gz" "$backup_name" && rm -rf "$backup_name"
    
    echo "100"; echo "# Yedekleme tamamlandı!"
    ) | zenity --progress \
        --title="Yedekleme" \
        --text="Yedekleme başlatılıyor..." \
        --percentage=0 \
        --auto-close \
        --no-cancel
    
    if [ $? -eq 0 ]; then
        local backup_size=$(ls -lh "$BACKUP_DIR/${backup_name}.tar.gz" | awk '{print $5}')
        zenity --info \
            --title="Yedekleme Başarılı" \
            --text="Yedekleme başarıyla tamamlandı!\n\nKonum: $BACKUP_DIR/${backup_name}.tar.gz\nBoyut: $backup_size"
        log_action "backup" "success" "Backup created: ${backup_name}.tar.gz (${backup_size})"
    else
        zenity --error \
            --title="Yedekleme Hatası" \
            --text="Yedekleme sırasında bir hata oluştu!"
        log_action "backup" "error" "Backup failed"
        return 1
    fi
}

# Yedek geri yükler
restore_backup() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    # List available backups
    local backups=($(ls -1 "$BACKUP_DIR"/*.tar.gz 2>/dev/null))
    if [ ${#backups[@]} -eq 0 ]; then
        zenity --error \
            --title="Geri Yükleme Hatası" \
            --text="Kullanılabilir yedek bulunamadı!"
        return 1
    fi
    
    # Create backup list for selection
    local backup_list=""
    for backup in "${backups[@]}"; do
        local name=$(basename "$backup")
        local size=$(ls -lh "$backup" | awk '{print $5}')
        local date=$(date -r "$backup" '+%Y-%m-%d %H:%M:%S')
        backup_list+="$name|$size|$date\n"
    done
    
    # Show backup selection dialog
    local selected_backup=$(echo -e "$backup_list" | zenity --list \
        --title="Yedek Seç" \
        --text="Geri yüklenecek yedeği seçin:" \
        --column="Yedek Adı" \
        --column="Boyut" \
        --column="Tarih" \
        --width=600 \
        --height=400 \
        2>/dev/null)
    
    if [ -n "$selected_backup" ]; then
        if zenity --question \
            --title="Geri Yükleme Onayı" \
            --text="Seçilen yedek geri yüklenecek:\n$selected_backup\n\nMevcut veriler silinecektir. Devam etmek istiyor musunuz?"; then
            
            # Show progress dialog
            (
            echo "10"; echo "# Yedek dosyası açılıyor..."
            cd "$DATA_DIR"
            
            echo "30"; echo "# Mevcut dosyalar yedekleniyor..."
            local timestamp=$(date '+%Y%m%d_%H%M%S')
            mkdir -p "${DATA_DIR}_backup_${timestamp}"
            cp "$INVENTORY_FILE" "$USERS_FILE" "$HISTORY_FILE" "${DATA_DIR}_backup_${timestamp}/"
            
            echo "50"; echo "# Yedek dosyası çıkartılıyor..."
            tar -xzf "$BACKUP_DIR/$selected_backup" -C "$DATA_DIR"
            
            echo "70"; echo "# Dosyalar geri yükleniyor..."
            cp -f "$DATA_DIR"/*/*.{csv,log} "$DATA_DIR/"
            
            echo "90"; echo "# Temizlik yapılıyor..."
            rm -rf "$DATA_DIR"/*/ 2>/dev/null
            
            echo "100"; echo "# Geri yükleme tamamlandı!"
            ) | zenity --progress \
                --title="Geri Yükleme" \
                --text="Geri yükleme başlatılıyor..." \
                --percentage=0 \
                --auto-close \
                --no-cancel
            
            if [ $? -eq 0 ]; then
                zenity --info \
                    --title="Geri Yükleme Başarılı" \
                    --text="Yedek başarıyla geri yüklendi!"
                log_action "restore" "success" "Backup restored: $selected_backup"
            else
                zenity --error \
                    --title="Geri Yükleme Hatası" \
                    --text="Geri yükleme sırasında bir hata oluştu!"
                log_action "restore" "error" "Restore failed: $selected_backup"
                return 1
            fi
        fi
    fi
}

# Log kayıtlarını gösterir
show_logs() {
    if [ ! -s "$HISTORY_FILE" ]; then
        zenity --info \
            --text="Kayıt bulunmamaktadır."
        return
    fi
    
    # Create a more detailed log viewer with filtering options
    local filter_option=$(zenity --list \
        --title="Log Kayıtları" \
        --text="Filtre seçin:" \
        --column="Filtre" \
        "Tüm Kayıtlar" \
        "Sadece Hatalar" \
        "Sadece Başarılı İşlemler" \
        "Son Bir Saat" \
        "Bugün" \
        2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local filtered_content
        case "$filter_option" in
            "Sadece Hatalar")
                filtered_content=$(grep -i "error" "$HISTORY_FILE")
                ;;
            "Sadece Başarılı İşlemler")
                filtered_content=$(grep -i "success" "$HISTORY_FILE")
                ;;
            "Son Bir Saat")
                local hour_ago=$(date -v-1H '+%Y-%m-%d %H:%M:%S')
                filtered_content=$(awk -v hour_ago="$hour_ago" '$0 >= hour_ago' "$HISTORY_FILE")
                ;;
            "Bugün")
                local today=$(date '+%Y-%m-%d')
                filtered_content=$(grep "$today" "$HISTORY_FILE")
                ;;
            *)
                filtered_content=$(cat "$HISTORY_FILE")
                ;;
        esac
        
        if [ -z "$filtered_content" ]; then
            zenity --info \
                --text="Seçilen filtreye uygun kayıt bulunamadı."
            return
        fi
        
        # Format logs with colors
        echo "$filtered_content" | format_logs "$filter_option" | zenity --text-info \
            --title="Sistem Kayıtları - $filter_option" \
            --width=800 \
            --height=600 \
            --html \
            2>/dev/null
    fi
}

# Log kayıtlarını dışa aktarır
export_logs() {
    local export_dir="$HOME/Desktop"
    local export_file="$export_dir/envanter_logs_$(date '+%Y%m%d_%H%M%S').log"
    
    if [ ! -d "$export_dir" ]; then
        mkdir -p "$export_dir"
    fi
    
    if cp "$HISTORY_FILE" "$export_file"; then
        chmod 600 "$export_file"
        zenity --info \
            --title="Dışa Aktarma Başarılı" \
            --text="Kayıtlar başarıyla dışa aktarıldı:\n$export_file"
        log_action "export_logs" "success" "Logs exported to $export_file"
    else
        zenity --error \
            --title="Dışa Aktarma Hatası" \
            --text="Kayıtlar dışa aktarılırken bir hata oluştu."
        log_action "export_logs" "error" "Failed to export logs"
    fi
}

# -----------------------------------------------------------------------------
# Kullanıcı Yönetimi Fonksiyonları
# -----------------------------------------------------------------------------

# Kullanıcı girişi yapar
authenticate_user() {
    local max_attempts=3
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        local credentials=$(zenity --forms \
            --title="Kullanıcı Girişi" \
            --text="Giriş bilgilerinizi girin ($attempt/$max_attempts)" \
            --separator="|" \
            --add-entry="Kullanıcı Adı" \
            --add-password="Şifre" \
            2>/dev/null)
        
        if [ $? -ne 0 ]; then
            log_action "auth" "info" "Login cancelled by user"
            return 1
        fi
        
        IFS="|" read -r username password <<< "$credentials"
        
        if [ -z "$username" ] || [ -z "$password" ]; then
            zenity --error \
                --text="Kullanıcı adı ve şifre boş bırakılamaz."
            continue
        fi
        
        # Check if user is locked
        if is_user_locked "$username"; then
            zenity --error \
                --text="Bu hesap kilitlenmiştir.\nYönetici ile iletişime geçin."
            log_action "auth" "error" "Locked account login attempt: $username"
            return 1
        fi
        
        # Get user data
        local user_data=$(grep "^[^,]*,$username," "$USERS_FILE")
        if [ -n "$user_data" ]; then
            IFS=, read -r id user fullname role stored_pass last_login attempts <<< "$user_data"
            local hashed_pass=$(echo -n "$password" | md5sum | cut -d' ' -f1)
            
            if [ "$hashed_pass" = "$stored_pass" ]; then
                CURRENT_USER="$username"
                CURRENT_ROLE="$role"
                
                # Update last login and reset failed attempts
                local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
                sed -i "" "s/^$id,$username,$fullname,$role,$stored_pass,[^,]*,[^,]*$/$id,$username,$fullname,$role,$stored_pass,$timestamp,0/" "$USERS_FILE"
                
                log_action "auth" "success" "User logged in: $username"
                return 0
            fi
        fi
        
        # Increment failed attempts
        if [ -n "$user_data" ]; then
            local new_attempts=$((attempts + 1))
            sed -i "" "s/^$id,$username,$fullname,$role,$stored_pass,$last_login,[^,]*$/$id,$username,$fullname,$role,$stored_pass,$last_login,$new_attempts/" "$USERS_FILE"
            
            # Lock account if max attempts reached
            if [ $new_attempts -ge $MAX_LOGIN_ATTEMPTS ]; then
                lock_user "$username"
                zenity --error \
                    --text="Maksimum deneme sayısı aşıldı.\nHesabınız kilitlenmiştir."
                log_action "auth" "error" "Account locked due to max attempts: $username"
                return 1
            fi
        fi
        
        zenity --error \
            --text="Geçersiz kullanıcı adı veya şifre.\nKalan deneme: $(($max_attempts - $attempt))"
        log_action "auth" "error" "Failed login attempt for user: $username"
        
        attempt=$((attempt + 1))
    done
    
    zenity --error \
        --text="Maksimum deneme sayısı aşıldı.\nProgram kapatılıyor."
    return 1
}

# Yeni kullanıcı ekler
add_user() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    local user_info=$(zenity --forms \
        --title="Yeni Kullanıcı" \
        --text="Kullanıcı bilgilerini girin" \
        --separator="|" \
        --add-entry="Kullanıcı Adı" \
        --add-entry="Ad Soyad" \
        --add-password="Şifre" \
        --add-list="Rol" \
        --list-values="user|admin" \
        2>/dev/null)
    
    if [ $? -eq 0 ]; then
        IFS="|" read -r username fullname password role <<< "$user_info"
        
        # Validate input
        if ! validate_text "$username"; then
            zenity --error \
                --text="Kullanıcı adı sadece harf, rakam, alt çizgi ve tire içerebilir."
            return 1
        fi
        
        # Check for duplicate username
        if grep -q "^[^,]*,$username," "$USERS_FILE"; then
            zenity --error \
                --text="Bu kullanıcı adı zaten kullanılmaktadır."
            return 1
        fi
        
        # Add user
        local id=$(generate_id)
        local hashed_pass=$(echo -n "$password" | md5sum | cut -d' ' -f1)
        local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$id,$username,$fullname,$role,$hashed_pass,$timestamp,0" >> "$USERS_FILE"
        
        zenity --info \
            --text="Kullanıcı başarıyla eklendi."
        log_action "add_user" "success" "Added user: $username"
    fi
}

# Kullanıcıları listeler
list_users() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    if [ ! -s "$USERS_FILE" ]; then
        zenity --info \
            --text="Kayıtlı kullanıcı bulunmamaktadır."
        return
    fi
    
    # Create temporary file for user data
    local tmp_file=$(mktemp)
    
    # Prepare data in table format
    (echo "Kullanıcı Adı|Ad Soyad|Rol|Son Giriş|Başarısız Denemeler"
    tail -n +2 "$USERS_FILE" | while IFS=, read -r id username fullname role password last_login attempts; do
        local locked=""
        if is_user_locked "$username"; then
            locked=" (Kilitli)"
        fi
        echo "$username$locked|$fullname|$role|$last_login|$attempts"
    done) > "$tmp_file"
    
    # Show table
    zenity --list \
        --title="Kullanıcı Listesi" \
        --width=800 \
        --height=400 \
        --text="<span size='large'>Kullanıcı Listesi</span>" \
        --column="Kullanıcı Adı" \
        --column="Ad Soyad" \
        --column="Rol" \
        --column="Son Giriş" \
        --column="Başarısız Denemeler" \
        --separator="|" \
        $(cat "$tmp_file") \
        2>/dev/null
    
    rm -f "$tmp_file"
}

# Kullanıcı günceller
update_user() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    local users=$(tail -n +2 "$USERS_FILE" | cut -d',' -f2 | sort)
    if [ -z "$users" ]; then
        zenity --info \
            --text="Güncellenebilecek kullanıcı bulunmamaktadır."
        return
    fi
    
    local username=$(zenity --list \
        --title="Kullanıcı Güncelle" \
        --text="Güncellenecek kullanıcıyı seçin:" \
        --column="Kullanıcı Adı" \
        $users \
        2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local user_data=$(grep "^[^,]*,$username," "$USERS_FILE")
        IFS=, read -r id user fullname role password last_login attempts <<< "$user_data"
        
        local update_info=$(zenity --forms \
            --title="Kullanıcı Güncelle" \
            --text="'$username' kullanıcısının bilgilerini güncelleyin\nBoş bırakılan alanlar değiştirilmeyecektir" \
            --separator="|" \
            --add-entry="Ad Soyad (mevcut: $fullname)" \
            --add-password="Yeni Şifre (değiştirmek için doldurun)" \
            --add-list="Rol (mevcut: $role)" \
            --list-values="user|admin" \
            2>/dev/null)
        
        if [ $? -eq 0 ]; then
            IFS="|" read -r new_fullname new_password new_role <<< "$update_info"
            
            # Use current values if new ones are empty
            new_fullname=${new_fullname:-$fullname}
            new_role=${new_role:-$role}
            
            # Update password if provided
            if [ -n "$new_password" ]; then
                password=$(echo -n "$new_password" | md5sum | cut -d' ' -f1)
            fi
            
            # Create backup before update
            cp "$USERS_FILE" "$USERS_FILE.bak"
            
            # Update user
            sed -i "" "s/^$id,$username,$fullname,$role,$password,$last_login,$attempts$/$id,$username,$new_fullname,$new_role,$password,$last_login,0/" "$USERS_FILE"
            
            zenity --info \
                --text="Kullanıcı başarıyla güncellendi."
            log_action "update_user" "success" "Updated user: $username"
        fi
    fi
}

# Kullanıcı siler
delete_user() {
    if ! check_permission "admin"; then
        return 1
    fi
    
    local users=$(tail -n +2 "$USERS_FILE" | cut -d',' -f2 | sort)
    if [ -z "$users" ]; then
        zenity --info \
            --text="Silinebilecek kullanıcı bulunmamaktadır."
        return
    fi
    
    local username=$(zenity --list \
        --title="Kullanıcı Sil" \
        --text="Silinecek kullanıcıyı seçin:" \
        --column="Kullanıcı Adı" \
        $users \
        2>/dev/null)
    
    if [ $? -eq 0 ]; then
        # Prevent deleting the last admin
        local admin_count=$(grep -c ",admin," "$USERS_FILE")
        if [ "$admin_count" -eq 1 ] && grep -q "^[^,]*,$username,.*,admin," "$USERS_FILE"; then
            zenity --error \
                --text="Son yönetici kullanıcısı silinemez!"
            return 1
        fi
        
        if zenity --question \
            --text="'$username' kullanıcısını silmek istediğinizden emin misiniz?"; then
            
            # Create backup before deletion
            cp "$USERS_FILE" "$USERS_FILE.bak"
            
            # Delete user
            grep -v "^[^,]*,$username," "$USERS_FILE" > "$USERS_FILE.tmp"
            mv "$USERS_FILE.tmp" "$USERS_FILE"
            
            # Remove from locked users if exists
            sed -i "" "/^$username$/d" "$LOCKED_USERS_FILE" 2>/dev/null
            
            zenity --info \
                --text="Kullanıcı başarıyla silindi."
            log_action "delete_user" "success" "Deleted user: $username"
        fi
    fi
}

# -----------------------------------------------------------------------------
# Ana Program
# -----------------------------------------------------------------------------

# Program başlangıcı
main() {
    # Dosya sistemini hazırla
    init_files
    
    # CSV bütünlüğünü kontrol et
    check_csv_integrity "$INVENTORY_FILE" "$INVENTORY_HEADER"
    check_csv_integrity "$USERS_FILE" "$USERS_HEADER"
    
    # Kullanıcı girişi
    authenticate_user || exit 1
    
    # Ana menüyü göster
    show_main_menu
}

# Programı başlat
main 