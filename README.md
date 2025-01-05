# Envanter Yönetim Sistemi

Zenity tabanlı basit bir envanter yönetim sistemi.

## Özellikler

- Ürün yönetimi (ekleme, listeleme, güncelleme, silme)
- Kullanıcı yönetimi
- Stok raporları
- Disk kullanım analizi
- Yedekleme ve geri yükleme
- Detaylı log kayıtları

## Kurulum

1. Scripti indirin:
```bash
git clone [repository-url]
cd [repository-directory]
```

2. Çalıştırma izni verin:
```bash
chmod +x minimal_inventory.sh
```

3. Programı başlatın:
```bash
./minimal_inventory.sh
```

## Giriş Bilgileri

### Varsayılan Admin Hesabı
- **Kullanıcı Adı:** admin
- **Şifre:** admin123

## Kullanıcı Rolleri

### Admin
- Tüm sistem özelliklerine erişim
- Kullanıcı yönetimi
- Yedekleme ve geri yükleme
- Sistem ayarları

### Normal Kullanıcı
- Ürün listeleme
- Rapor görüntüleme

## Önemli Notlar

- İlk girişten sonra admin şifresini değiştirmeniz önerilir
- Düzenli yedekleme yapılması tavsiye edilir
- Hatalı giriş denemelerinde hesap 3 başarısız denemeden sonra kilitlenir

## Dosya Yapısı

Program aşağıdaki dosyaları otomatik olarak oluşturur:
- `inventory.csv`: Ürün veritabanı
- `users.csv`: Kullanıcı veritabanı
- `history.log`: İşlem kayıtları

## Güvenlik

- Şifreler MD5 ile hashlenerek saklanır
- Kritik işlemler için yetki kontrolü yapılır
- Tüm işlemler loglanır

## Yedekleme

Yedekler otomatik olarak aşağıdaki konumda saklanır:
```
$HOME/.config/minimal_inventory/backups/
```

## Hata Durumları

1. Hesap Kilitlenmesi:
   - 3 başarısız giriş denemesi sonrası hesap kilitlenir
   - Admin kullanıcısı kilidi kaldırabilir

2. Veri Bütünlüğü:
   - CSV dosyaları otomatik olarak kontrol edilir
   - Bozulma durumunda otomatik düzeltme yapılır

## Kısayollar

Ana Menü:
- 🛍️  Ürün İşlemleri
- 📊  Raporlar
- 👥  Kullanıcı Yönetimi
- ⚙️  Program Yönetimi
- ❌  Çıkış
