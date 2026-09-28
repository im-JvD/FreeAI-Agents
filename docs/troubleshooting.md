<div align="tight" dir="rtl">

# 🛠️ عیب‌یابی خطاهای رایج

جدول زیر رایج‌ترین خطاها و راه‌حل‌های آن‌هاست. اگر مشکل شما اینجا نبود، در گیت‌هاب Issue باز کنید. برای تشخیص سریع در همهٔ موارد، اول این دو دستور را در WSL بزنید:

```bash
freeagents status      # وضعیت و health هر دو گیت‌وی
freeagents doctor      # تشخیص عمیق: اتصال ارائه‌دهنده‌ها + درخواست واقعی
```

---

## 🔴 خطای `set: pipefail: invalid option name` (رایج‌ترین!)

**نشانه‌ها:** بلافاصله بعد از اجرا چنین پیام‌هایی می‌بینید (متن به‌هم‌ریخته، گاهی `: invalid option nameset: pipefail`):

```
: invalid option nameset: pipefail
```

**علت:** فایل با **خط‌پایان ویندوزی (CRLF)** ذخیره شده است. اگر فایل را در ویندوز با Notepad یا ادیتورهای مشابه ذخیره کنید، یا آن را از حالت‌های غیر raw کپی کنید، هر انتهای خط یک کاراکتر نامرئی `\r` اضافه می‌شود و bash آن را جزء دستورات می‌خواند.

**راه‌حل فوری** (روی همان فایل، داخل WSL):

```bash
sed -i 's/\r$//' setup.sh
bash setup.sh
```

**پیشگیری:**

- بهترین راه، همان اجرای یک‌خطی با `curl` است — فایل مستقیم و با خط‌پایان درست (LF) به WSL می‌رسد و اصلاً از ویندوز رد نمی‌شود:

  ```bash
  bash <(curl -fsSL https://raw.githubusercontent.com/im-JvD/FreeAI-Agents/main/setup.sh)
  ```

- اسکریپت **محافظ self-heal** دارد: اگر نسخهٔ CRLF را با `bash setup.sh` اجرا کنید، خودش یک نسخهٔ تمیز می‌سازد و ادامهٔ نصب را با آن انجام می‌دهد (مگر در اجرای مستقیم `./setup.sh` که خطای shebang را همان اول می‌گیرید — در آن حالت از `bash setup.sh` استفاده کنید).

---

## 🟠 خطاهای گیت‌وی LiteLLM (داکر)

### `docker pull` خطای 403، `toomanyrequests` یا `TLS handshake timeout` می‌دهد

اسکریپت ایمیج را از `ghcr.io` می‌گیرد (میرورهای `daemon.json` فقط برای داکرهاب هستند، نه ghcr). خطای `TLS handshake timeout` در ایران **بسیار رایج** است چون `ghcr.io` گاهی کند یا فیلتر می‌شود. نسخهٔ جدید اسکریپت خودش این مشکل را تا حد زیادی حل می‌کند:

- **۵ بار تلاش خودکار** با backoff افزایشی (۵، ۱۰، ۱۵ ثانیه)
- اگر ایمیج از نصب قبلی روی سیستم باشد، با همان ادامه می‌دهد
- **میرورهای خودکار ghcr** بدون نیاز به env: `ghcr.nju.edu.cn`، `ghcr.m.daocloud.io` و `docker.io/berriai/litellm` به‌ترتیب امتحان می‌شوند
- اگر پراکسی ویندوز (Clash/v2rayN/Hiddify) در مرحلهٔ ۴ فعال باشد، اسکریپت داکر دیمن را هم روی پراکسی تنظیم می‌کند (`/etc/systemd/system/docker.service.d/http-proxy.conf`) و pull را با پراکسی امتحان می‌کند

راه‌های حل به ترتیب (جدید → قدیمی):

```bash
# ۱) پراکسی ویندوز را در نصب فعال کنید (بهترین راه برای ایران):
#    در مرحلهٔ "Route provider traffic through your Windows proxy?" جواب y بدهید
#    و پراکسی ویندوز را روی حالت Allow LAN بگذارید، سپس دوباره اجرا کنید
bash setup.sh

# ۲) اتصال به ghcr و میرورها را بسنجید:
curl -I https://ghcr.io/v2/
curl -I https://ghcr.nju.edu.cn/v2/
curl -I https://ghcr.m.daocloud.io/v2/
# اگر میرور جواب داد، دوباره نصاب را اجرا کنید - خودش میرور را امتحان می‌کند
bash setup.sh

# ۳) VPN سمت ویندوز بزنید و دوباره اجرا کنید

# ۴) میرور را صریحاً اجبار کنید (اگر خودکار کار نکرد):
LITELLM_GHCR_MIRROR=ghcr.nju.edu.cn bash setup.sh
# یا:
LITELLM_GHCR_MIRROR=ghcr.m.daocloud.io bash setup.sh

# ۵) pull دستی با پراکسی (اگر پراکسی ویندوز دارید):
#    IP ویندوز را از WSL بگیرید:
ip route show default | awk '{print $3}'
#    سپس:
export HTTP_PROXY=http://<WINDOWS_IP>:7890 HTTPS_PROXY=http://<WINDOWS_IP>:7890
sudo -E docker pull ghcr.io/berriai/litellm:main-latest
#    بعد دوباره نصاب را اجرا کنید - ایمیج لوکال را تشخیص می‌دهد و ادامه می‌دهد
bash setup.sh

# ۶) یا ایمیج را کامل خودتان انتخاب کنید:
LITELLM_IMAGE=ghcr.nju.edu.cn/berriai/litellm:main-latest bash setup.sh

# ۷) تعداد تلاش‌های مجدد هم قابل تغییر است (پیش‌فرض ۵):
LITELLM_PULL_RETRIES=8 bash setup.sh

# ۸) اگر tarball دارید:
docker load -i litellm.tar
bash setup.sh
```

### `Cannot connect to the Docker daemon` / `docker: command not found`

```bash
sudo service docker start          # یا: sudo systemctl start docker
sudo docker ps
# اگر داکر نصب نیست:
sudo apt-get update && sudo apt-get install -y docker.io && sudo service docker start
```

### `address already in use` روی پورت 4000

```bash
sudo ss -ltnp | grep 4000          # چه چیزی گرفته؟
LITELLM_PORT=4010 bash setup.sh    # نصب مجدد روی پورت جدید
```

---

## 🟢 خطاهای گیت‌وی OmniRoute (npm)

### `npm install` خطا می‌دهد (`ETIMEDOUT` / `403` / `EACCES` / `sudo: npm: command not found`)

اسکریپت اول از `npmjs.org` نصب می‌کند و اگر شکست بخورد، خودکار `registry.npmmirror.com` را امتحان می‌کند. نسخه جدید همچنین مشکل `sudo: npm: command not found` (وقتی Node با nvm یا NodeSource نصب شده ولی sudo مسیر npm را نمی‌بیند) را خودکار حل می‌کند — با مسیر کامل npm و `sudo env PATH`.

برای تلاش دوباره یا نصب اجباری:

```bash
OMNIROUTE_FORCE_NPM_INSTALL=1 bash setup.sh
# یا دستی (با مسیر کامل npm):
which npm
sudo $(which npm) install -g omniroute --registry=https://registry.npmmirror.com
# یا بدون sudo (اگر از nvm استفاده می‌کنید):
npm install -g omniroute
```

اگر با nvm نصب کرده‌اید و `omniroute: command not found` می‌گیرید:

```bash
npm config set prefix ~/.npm-global
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
npm install -g omniroute
sudo ln -sf ~/.npm-global/bin/omniroute /usr/local/bin/omniroute
```

### OmniRoute بالا نمی‌آید / لحظهٔ بوت کرش می‌کند

روی این سرویس، secretهای کوتاه باعث **fail-fast در استارت** می‌شوند:

```
Invalid web runtime environment: "JWT_SECRET" is too short (26 chars, minimum 32)
```

حداقل‌ها: `JWT_SECRET ≥ 32`، `API_KEY_SECRET ≥ 16`، `INITIAL_PASSWORD ≥ 8`. نصاب این مقادیر را ۶۴ کاراکتری می‌سازد و بین نصب‌ها حفظ می‌کند؛ اگر دستی‌شان عوض کرده‌اید:

```bash
freeagents doctor omniroute        # بررسی سلامت + لاگ
grep -E 'JWT_SECRET|API_KEY_SECRET|INITIAL_PASSWORD' ~/.omniroute/.env | cut -c1-40
freeagents restart                 # بعد از اصلاح، ری‌استارت
```

### پورت 20128 اشغال است

```bash
sudo ss -ltnp | grep 20128
OMNIROUTE_PORT=20129 bash setup.sh
```

### `omniroute: command not found` بعد از نصب

```bash
which omniroute || sudo npm install -g omniroute
cat ~/.free-ai-agents/logs/omniroute.log      # لاگ لانچر
```

---

## 🟡 خطاهای مرتبط با ویندوز/PowerShell

### `powershell.exe was not found`

Interop ویندوز در WSL غیرفعال است. در ویندوز فایل `%USERPROFILE%\.wslconfig` را بسازید و مطمئن شوید این خط را ندارد یا `false` نیست:

```ini
[wsl2]
# بدون خط appendWindowsPath=false
```

سپس در PowerShell: `wsl --shutdown` و باز کردن مجدد ترمینال.

### مسیر پروفایل ویندوز اشتباه تشخیص داده می‌شود

اسکریپت فقط از PowerShell استفاده می‌کند (`[Environment]::GetFolderPath('UserProfile')`)؛ این متد حتی با OneDrive-redirect و فاصله در نام کاربری درست کار می‌کند. تست دستی:

```bash
powershell.exe -NoProfile -Command "[Environment]::GetFolderPath('UserProfile')"
```

خروجی باید چیزی شبیه `C:\Users\Your Name` باشد. اگر ویندوز ندارید (تست/محیط لینوکسی): `FREEAGENTS_SKIP_WINDOWS=1 bash setup.sh`.

### Claude Code به گیت‌وی وصل نمی‌شود (مدلی در `/model` نمی‌بینم)

1. مسیر فایل را چک کنید: `%USERPROFILE%\.claude\settings.json`
2. JSON معتبر است؟ فایل را در VSCode باز کنید — نقل‌قول‌ها باید مستقیم (`"`) باشند نه هوشمند/فارسی.
3. کلاد کد را **کاملاً** ببندید و دوباره باز کنید (بلوک `env` فقط هنگام شروع خوانده می‌شود).
4. کشف مدل گیت‌وی به نسخهٔ **v2.1.129 به بعد** نیاز دارد: `claude --version` و در صورت نیاز آپدیت.
5. متغیر قدیمی `ANTHROPIC_BASE_URL` یا `ANTHROPIC_API_KEY` دیگری در ویندوز (Environment Variables سیستم) تنظیم شده؟ مقدار قدیمی روی `settings.json` **اولویت دارد** — پاکش کنید.
6. گیت‌وی فعال را چک کنید: `freeagents status` — اگر گیت‌وی فعال روی OmniRoute است ولی آن سرویس خوابیده، کلاد چیزی نمی‌بیند.

---

## 🟠 خطاهای احراز هویت و درخواست‌ها

### Claude Code خطای `401` / `Unauthorized` می‌دهد

توکن داخل `settings.json` با توکن گیت‌وی فعال نمی‌خواند. توکن درست:

| گیت‌وی فعال | توکن | مسیر |
|---|---|---|
| LiteLLM | Master Key | `~/.litellm/master_key.txt` |
| OmniRoute | کلید کلاینت | `~/.free-ai-agents/omniroute_claude.key` |

```bash
freeagents credentials      # همهٔ توکن‌ها/URLها یکجا
```

سپس مقدار `ANTHROPIC_AUTH_TOKEN` را در `settings.json` با آن یکی کنید. ساده‌ترین راه هماهنگ‌سازی: منو → `9` (Config Manager) → `4` (Re-apply the Claude configuration) یا نصب مجدد.

### اپ Claude Desktop مدل گیت‌وی را نشان نمی‌دهد

1. نصاب برای هر گیت‌وی یک پروفایل در `%LOCALAPPDATA%\Claude-3p\configLibrary\<uuid>.json` می‌سازد (LiteLLM: `…a119e` — OmniRoute: `…a110e`) و `_meta.json` را به‌روز می‌کند. مطمئن شوید اپ را بعد از نصاب **کاملاً** بسته و باز کرده‌اید (فهرست مدل‌ها هنگام باز شدن گرفته می‌شود).
2. پیکر مدل اپ فقط idهای حاوی `claude`/`anthropic` را نشان می‌دهد؛ مدل نصاب (`claude-freeagents`) همین شرط را دارد و به‌صورت یکتا از خطای `Ambiguous model` جلوگیری می‌کند (در LiteLLM 1.x مدل‌هایی مثل `claude-sonnet-4-5` در چند provider وجود دارند و مبهم هستند).
3. اگر پروفایل را دستی ست می‌کنید: **Help > Troubleshooting > Enable Developer Mode** → **Developer > Configure Third-Party Inference…** — راهنمای کامل در [usage.md](usage.md) بخش ۵. مقدار `Gateway base URL` باید **بدون `/v1`** باشد: `http://127.0.0.1:4000` یا `http://127.0.0.1:20128`.
4. اگر «Invalid: Model list» می‌بینید و Apply غیرفعال است، پروفایل را از نو بسازید: منو → `9` → `5` (Switch the ACTIVE gateway) و بعد از آن اپ‌ها را ری‌استارت کنید.
5. اگر خطای `Ambiguous model 'claude-sonnet-4-5'` می‌بینید، نسخهٔ قدیمی (قبل از 0.0.6) نصب کرده‌اید — به‌روزرسانی کنید: `freeagents update` یا `bash <(curl -fsSL https://raw.githubusercontent.com/im-JvD/FreeAI-Agents/main/setup.sh)` — نسخه جدید فقط `claude-freeagents` را تبلیغ می‌کند.

### چطور گیت‌وی فعال را عوض کنم (کلاد کد + دسکتاپ)؟

```bash
# منو → گزینهٔ 9 (Config Manager) → گزینهٔ 5 (Switch the ACTIVE gateway)
freeagents      # باز کردن منو
```

`settings.json`، پروفایل دسکتاپ (`appliedId` در `_meta.json`) و همهٔ توکن‌ها هم‌زمان به‌روز می‌شوند. بعد از تعویض، اپ‌های Claude را کامل ببندید و باز کنید.

### خطای `Add credits or update billing to continue.`

این خطا از **OpenRouter** (یا گاهی Groq) می‌آید وقتی حساب شما اعتبار ندارد. LiteLLM سعی می‌کند با `simple-shuffle` و `num_retries` به provider بعدی برود، ولی اگر همه providerها به خاطر تحریم یا بی‌اعتباری fail شوند، آخرین خطا (همین `Add credits`) نمایش داده می‌شود.

راه‌حل:

```bash
freeagents doctor          # ببین کدام providerها fail می‌شوند
# اگر OpenRouter اعتبار ندارد، کلیدش را حذف کن و دوباره نصب کن:
freeagents
# منو -> 9 -> 2 (Re-enter provider keys) -> OpenRouter را خالی بگذار

# یا مستقیم:
# ~/.free-ai-agents/provider_keys.env را ویرایش کن و OPENROUTER_API_KEY را پاک کن
# سپس:
freeagents restart
```

همچنین مطمئن شوید **پراکسی ویندوز** برای هر دو گیت‌وی فعال است (Clash/v2rayN با Allow LAN):

```bash
freeagents
# منو -> 9 -> 1 (Windows proxy ON) -> آدرس پراکسی را وارد کن
freeagents restart
freeagents doctor
```

### مدل جواب نمی‌دهد (`429` / `quota exceeded`)

سهمیهٔ رایگان آن ارائه‌دهنده تمام شده. در LiteLLM، router خودش deployment بعدی را امتحان می‌کند (retry/cooldown) و در OmniRoute هم combo با `strategy: auto` همین کار را می‌کند. برای بررسی:

```bash
freeagents doctor            # کدام ارائه‌دهنده خطا می‌دهد؟
freeagents logs litellm      # یا: freeagents logs omniroute
```

### خطای `403 Forbidden` / بلاک منطقه‌ای (Groq / Google / Cerebras)

```text
GroqException - {"error":{"message":"Forbidden"}}
Google: "User location is not supported for the API use"
```

شرکت‌های آمریکایی درخواست‌های IP ایران را در لبهٔ شبکه رد می‌کنند — حتی با کلید کاملاً معتبر. راه‌حل‌ها:

1. **بدون VPN:** نصاب را دوباره اجرا کنید و به سؤال `Route provider traffic through your Windows proxy?` جواب `y` بدهید (Clash/v2rayN/Hiddify روی ویندوز با **Allow LAN**). ترافیک هر دو گیت‌وی از همان پراکسی رد می‌شود. بعد: `freeagents restart`.
2. **VPN سمت ویندوز** با حالت system-wide (TUN) + `freeagents restart`.
3. اگر هیچ‌کدام را نمی‌خواهید، ارائه‌دهنده‌های مسدود را بدون کلید بگذارید (نصاب را دوباره اجرا کنید و آن خانه‌ها را خالی رد کنید) تا از گروه مدل حذف شوند.

> در `freeagents doctor`، وضعیت پراکسی و نتیجهٔ اتصال هر ارائه‌دهنده (`reachable / REJECTED / UNREACHABLE`) و همچنین یک درخواست واقعی از مسیر گیت‌وی نمایش داده می‌شود.

---

## 🟣 هشدار «does not look like a X key»

این هشدار یعنی کلیدی که در آن خانه وارد کرده‌اید با پیشوند شناخته‌شدهٔ آن سرویس نمی‌خواند — معمولاً یعنی کلیدها جابجا وارد شده‌اند. پیشوندهای درست:

| سرویس | پیشوند |
|---|---|
| Groq | `gsk_` |
| OpenRouter | `sk-or-` |
| Google AI Studio | `AIza` |
| Cerebras | `csk-` |
| NVIDIA NIM | `nvapi-` |
| Mistral / GitHub / SambaNova / Together | (پیشوند ثابتی ندارند، بررسی نمی‌شود) |

نصاب هر کلید را **قبل از نصب به‌صورت زنده تست می‌کند** و اگر رد شود (401/403)، همان لحظه اعلام و پیشنهاد واردکردن مجدد می‌دهد. «could not verify» یعنی شبکه به آن سرویس نمی‌رسد (مثلاً Google بدون پراکسی) — این شکست کلید نیست.

---

## 🔵 خطاهای مدیریت و پنل‌ها

### `freeagents: command not found` / `litellm: command not found`

CLI مدیریت نصب نشده (یا نسخهٔ قدیمی با `litellm`/`omni` را صدا می‌زنید). فقط یک دستور وجود دارد:

```bash
ls -l /usr/local/bin/freeagents        # باید وجود داشته باشد
freeagents help                        # راهنمای دستورات
```

اگر نبود، نصاب را دوباره اجرا کنید — نسخهٔ جدید دستورهای قدیمی `litellm`/`omni` را هم پاک می‌کند.

### خطای «Authentication Error, Not connected to DB!» هنگام Login به پنل LiteLLM

ورود به Admin UI لایت‌ال‌ال‌ام **بدون دیتابیس Postgres ممکن نیست**. نصاب خودش کانتینر `litellm-db` را می‌سازد (`LITELLM_UI_DB=1` پیش‌فرض) و `DATABASE_URL` را به پروکسی می‌دهد.

```bash
sudo docker ps                                  # هر دو کانتینر باید Up باشند
freeagents restart                              # اولین بوت بعد از ساخت DB کمی طول می‌کشد
LITELLM_UI_DB=0 bash setup.sh                   # یا: اجرا بدون DB (چت سالم، UI بدون ورود)
```

### پنل LiteLLM باز نمی‌شود یا Login نمی‌شود

- پروکسی روشن است؟ `freeagents status`
- یوزر `admin` و رمز = **Master Key** (پسورد جداگانه وجود ندارد):

  ```bash
  freeagents credentials
  cat ~/.litellm/dashboard_credentials.txt
  ```

### داشبورد OmniRoute باز نمی‌شود

```bash
curl -s http://127.0.0.1:20128/healthz        # باید ok بدهد
freeagents logs omniroute                     # لاگ زنده
grep INITIAL_PASSWORD ~/.omniroute/.env       # رمز ورود داشبورد
```

اگر رمز را عوض کردید و یادتان نیست، مقدار `INITIAL_PASSWORD` را در `~/.omniroute/.env` به یک رمز ≥ ۸ کاراکتری تغییر دهید و `freeagents restart` بزنید.

### بعد از ری‌استارت ویندوز/WSL چیزی بالا نیامد

```bash
freeagents up        # همین کافی است (هر دو گیت‌وی)
```

بررسی مکانیزم استارت خودکار:

```bash
systemctl status litellm 2>/dev/null
systemctl status omniroute 2>/dev/null
grep -A1 '\[boot\]' /etc/wsl.conf
```

اگر systemd ندارید: نصاب با حالت `wslconf` یک boot command (`/usr/local/bin/freeagents-boot.sh`) می‌گذارد.

---

## ⚪ موارد عمومی

### Master Key را گم کردم

```bash
cat ~/.litellm/master_key.txt
```

### چطور وضعیت کلی را یکجا ببینم؟

```bash
freeagents status
# بررسی دستی:
sudo docker ps --filter name=litellm
curl -s http://127.0.0.1:4000/health/liveliness
curl -s http://127.0.0.1:20128/healthz
```

### اجرای دوبارهٔ اسکریپت امن است؟

بله — نصب مجدد (گزینهٔ `1`) کانتینر/سرویس قبلی را حذف و همه‌چیز را هماهنگ بازسازی می‌کند. کلیدهای API قبلی **نگه داشته می‌شوند** («Keep these keys? [Y/n]»)، Master Key و secretهای OmniRoute هم ثابت می‌مانند. حذف (گزینهٔ `6`) هم idempotent است.

### به‌روزرسانی اسکریپت

```bash
freeagents update       # دانلود از همین ریپو + نصب مجدد با حفظ کلیدها
```

</div>
