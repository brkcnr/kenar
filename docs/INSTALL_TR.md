# Kenar 1.5 — Hızlı kurulum

1. Çalışan eski Kenar'ı adanın sağ tık menüsündeki **Quit Kenar / Kenar’dan çık** ile kapat.
2. **Kenar-1.5.0.dmg** dosyasını aç, Kenar'ı **Applications** klasörüne taşı ve çalıştır.
3. Sağ veya sol kenardaki adanın üzerine gelerek paneli aç. Ayarlarındaki görünüm, dil ve mevcut Claude oturumu korunur.

## Hesapları bağlama

**Settings → Providers / Ayarlar → Sağlayıcılar** bölümünde her hesap için **Connect / Reconnect / Disconnect** bulunur. Girişini Kenar'ın kendi penceresinde tamamla; şifreni başka bir yerde paylaşma. Gerekirse çalışma alanını seç. Hesap bağlantıları otomatik Keychain şifre isteği açmaz.

- **Claude:** Mevcut web bağlantısı korunur. Hesabın ortak kullanım pencereleri tek gösterilir; Code, web ve Desktop için aynı kota tekrar yazılmaz. Code aktarımı ve OAuth isteğe bağlı alternatiflerdir.
- **OpenAI:** Hesabını bağlayarak Codex / Work verisini oku. Normal ChatGPT Chat ayrı gösterilir; sağlayıcı sayısal kullanım vermiyorsa yüzde bilinmiyor olarak kalır. Mevcut Codex OAuth alternatifi yükseltmede korunur.
- **Cursor:** Cursor hesabıyla giriş yap. Yanıtta açıkça belirtilen Cursor Models ve Other Models ayrı gösterilir; eski toplam alanları başka havuzlar diye yeniden adlandırılmaz. Web bağlantısı, mevcut toplam alanları ve yeniden açılışta oturumun korunması bir gerçek hesapta doğrulandı; ücretli planın yeni iki havuzu henüz canlı sınanmadı.
- **Google:** Gemini ve Antigravity ayrı bağlantılardır. Google web okuyucusu deneysel; giriş yapmak sayısal kotaya erişildiği anlamına gelmez. Resmi kullanım kartını açıp **Read usage / Kenar’a aktar** kullan. Kart okunamıyorsa yüzde uydurulmaz. Bağımsız Antigravity sayısal hesap sorgusu henüz doğrulanmadı.

İsteğe bağlı Antigravity CLI alternatifi için açık `agy` oturumunda bir kez:

```text
/statusline ~/.gemini/antigravity-cli/kenar-statusline.sh
/usage
```

Bu alternatif aktif CLI oturumu gerektirir; bağımsız Google hesap sorgusu değildir. Beş dakikadan eski ölçüm güncel sayılmaz. Özel status line ayarı varsa üzerine yazılmaz. Kaldırmak için agy içinde `/statusline delete` kullan.

## Panel ve geçmiş

Kapalı ada yalnızca okunabilir, güncel verisi olan grupları gösterir. Açık panel tüm grupları ve bağlantı durumlarını gösterir. Ürünlerin yüzdeleri toplanmaz; ayrıntıları görmek için gruba tıkla. İğne paneli sabitler. Ayarlardan monitör, kenar, tema, genişlik, saydamlık ve dil seçilir. İngilizce için **Appearance → Language → English** kullan.

Kotalar iki dakikada bir, elle ve uyanma sonrasında yenilenir. Hata olursa son başarılı değer zamanı ile korunur ve güncel olmadığı belirtilir. Bilinmeyen değer yüzde sıfır değildir.

Saat simgesi hesap ve havuz filtreli kota geçmişini; klasör simgesi yerel proje token analizini açar. Web tüketimi proje tokenlarına eklenmez. Claude Code, Codex ve Antigravity'nin yerel kayıtları analiz için kullanılmaya devam eder. Cursor proje kırılımı sağlayıcı tarafından verilmediğinde bu açıkça gösterilir.

Bildirim iznini macOS'ta açabilirsin. Varsayılan eşikler yüzde 75, 90 ve 100'dür. Aynı hesap/havuz/dönem için tekrar bildirim gönderilmez.

Yerel veri: `~/Library/Application Support/Kenar/`. Geçmiş geçişi eski kayıtları korur; hesap bilinmeyen eski kayıtlar yeni hesaba atanmaz. Geçişten önce `analytics.pre-1.5.sqlite` biçiminde bir SQLite yedeği oluşturulur. Konuşma içerikleri kaydedilmez. Kota geçmişi 90 gün tutulur.

Uygulama ad-hoc imzalıdır; Apple notarizasyonu yapılmadı. macOS engellerse Sistem Ayarları → Gizlilik ve Güvenlik bölümündeki uygulama bilgisini kontrol et. Kaynak kod **Kenar-source.zip**, İngilizce kapsam ve doğrulama notları README ve VALIDATION içindedir.
