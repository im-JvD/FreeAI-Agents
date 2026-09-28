<div align="tight" dir="rtl">

# 📥 راهنمای نصب گام‌به‌گام

---

## ۱. پیش‌نیازها

| پیش‌نیاز | بررسی |
|---|---|
| ویندوز ۱۰/۱۱ | — |
| WSL2 با توزیع Ubuntu | `wsl -l -v` در PowerShell → ستون VERSION باید `2` باشد |
| Claude Code در ویندوز | فقط برای چت لازم است — نصب در PowerShell: `irm https://claude.ai/install.ps1 | iex` (یا `npm install -g @anthropic-ai/claude-code`) — نسخهٔ **v2.1.129+** برای کشف مدل گیت‌وی |
| دسترسی sudo در اوبونتو | اجرای `sudo -v` در ترمینال اوبونتو |
| اینترنت | برای `apt` (مخازن ایران آزاد است) و `ghcr.io` |

اگر WSL2 ندارید، اول در PowerShell (با دسترسی Administrator) اجرا کنید:

```powershell
wsl --install -d Ubuntu
```

---

## ۲. روش‌های اجرای اسکریپت

### روش ۱: اجرای مستقیم از گیت‌هاب (پیشنهادی) ⭐

داخل ترمینال **WSL Ubuntu**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/im-JvD/FreeAI-Agents/main/setup.sh)
```

یا:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/im-JvD/FreeAI-Agents/main/setup.sh)
```

> ⚠️ از الگوی `bash <( curl ... )` استفاده کنید نه `curl ... | bash`.
> در حالت دوم، ورودی استاندارد (stdin) که برای منو و دریافت کلیدها لازم است، توسط خودِ لوله (pipe) اشغال می‌شود و اسکریپت درست کار نمی‌کند.

### روش ۲: دانلود و سپس اجرا

```bash
curl -fsSL https://raw.githubusercontent.com/im-JvD/FreeAI-Agents/main/setup.sh -o /tmp/setup.sh
bash /tmp/setup.sh
```

### روش ۳: کلون مخزن

```bash
git clone https://github.com/im-JvD/FreeAI-Agents.git
cd FreeAI-Agents
bash setup.sh
```

> 💡 اسکریپت را **بدون sudo** اجرا کنید؛ خودش در جای لازم ارتقای دسترسی می‌دهد. اگر با sudo اجرا کنید هم کار می‌کند ولی هشدار می‌دهد که کانفیگ‌ها زیر `/root` ساخته می‌شوند.

---

## ۳. منوی اصلی

بلافاصله این منو را می‌بینید:

```
=================================================================
     Free AI Agents  |  Local AI Gateway Manager
=================================================================

   Proxy target : ghcr.io/berriai/litellm:main-latest
   Proxy port   : 4000   (restart policy: unless-stopped)
   Linux config : /home/<user>/.litellm

   Please choose an option:

     1) Full Install    (Docker + LiteLLM proxy + Claude Code config)
     2) Full Uninstall  (remove container + all generated configs)
     q) Quit

   Enter your choice [1/2/q]:
```

برای نصب، عدد `1` را وارد کنید.

---

## ۴. مراحل نصب (گزینهٔ 1)

اسکریپت ۹ مرحله را به‌ترتیب انجام می‌دهد:

| مرحله | کار |
|---|---|
| 1/9 | بررسی محیط WSL2 و موجود بودن `powershell.exe` |
| 2/9 | نصب داکر از مخازن apt اوبونتو (`docker.io`) — اگر از قبل نباشد |
| 3/9 | نوشتن میرورهای ایرانی در `/etc/docker/daemon.json` (با بکاپ از فایل قبلی) |
| — | راه‌اندازی دیمن داکر + فعال‌سازی auto-start در صورت وجود systemd |
| 4/9 | پروکسی ویندوز (اختیاری) + دریافت ۵ کلید API |
| 5/9 | ساخت `~/.litellm/config.yaml` و Master Key |
| 6/9 | دانلود ایمیج آمادهٔ `ghcr.io/berriai/litellm:main-latest` |
| 7/9 | اجرای کانتینر روی پورت 4000 با `--restart unless-stopped` |
| 8/9 | پیکربندی اجرای خودکار در بوت WSL + نصب دستورات مدیریت `freeagents` |
| 9/9 | ساخت `settings.json` کلاد کد + پیکربندی خودکار اپ Claude Desktop (پالیسی رجیستری) |

---

### پروکسی ویندوز (اختیاری ولی خیلی مفید)

قبل از دریافت کلیدها، نصاب می‌پرسد:

```
Route provider traffic through your Windows proxy? [y/N]:
```

اگر روی ویندوز یک برنامهٔ پراکسی دارید (**Clash / v2rayN / Hiddify / Nekoray**)، با `y` همهٔ ترافیک LiteLLM به سمت ارائه‌دهنده‌ها (Groq، Google، Cerebras و…) از همان پراکسی رد می‌شود — یعنی **رفع تحریم بدون VPN سیستم‌عامل**:

- آدرس پیشنهادی خودکار تشخیص داده می‌شود (IP ویندوز از دید WSL + پورت `7890`) — Enter بزنید یا IP:PORT دلخواه بدهید.
- نصاب یک تست واقعی از داخل همان پراکسی می‌زند و نتیجه را نشان می‌دهد.
- انتخاب شما در `~/.litellm/windows_proxy.txt` ذخیره می‌شود و نصب دوباره آن را نگه می‌دارد (یا با `n` عوضش کنید).
- داخل کانتینر به‌صورت `HTTP_PROXY` / `HTTPS_PROXY` تزریق می‌شود (ترافیک لوکال با `NO_PROXY` مستقیم می‌ماند).
- در `freeagents doctor` هم وضعیتش نمایش داده می‌شود و تست ارائه‌دهنده‌ها از مسیر پراکسی می‌رود.

نکته: در برنامهٔ پراکسی گزینهٔ **Allow LAN** را روشن کنید تا اتصال از WSL پذیرفته شود.

## ۵. دریافت و وارد کردن کلیدهای API

اسکریپت ۵ کلید می‌پرسد. **کلیدی ندارید؟ فقط Enter بزنید** تا رد شود — اما **حداقل یک کلید الزامی است** (اگر هیچ کلیدی ندهید، دوباره سؤال می‌شود؛ حداکثر ۳ بار).

| ترتیب | سرویس | لینک دریافت کلید رایگان | پیشوند نمونه |
|---|---|---|---|
| 1 | Groq | [console.groq.com/keys](https://console.groq.com/keys) | `gsk_...` |
| 2 | OpenRouter | [openrouter.ai/keys](https://openrouter.ai/keys) | `sk-or-...` |
| 3 | Google AI | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) | `AIza...` |
| 4 | Cerebras | [cloud.cerebras.ai](https://cloud.cerebras.ai) | `csk-...` |
| 5 | Mistral | [console.mistral.ai/api-keys](https://console.mistral.ai/api-keys) | `...` |

نکته‌ها:

- کلیدها هنگام تأیید به‌صورت ماسک‌شده نمایش داده می‌شوند (مثلاً `gsk_****abcd`).
- 🧪 بعد از دریافت کلیدها، نصاب هر کلید را **به‌صورت زنده** به سرویس‌دهنده تست می‌کند:
  - `valid (HTTP 200)` → کلید سالم است
  - `REJECTED (HTTP 401/403)` → کلید اشتباه/جابجاست و پیشنهاد واردکردن مجدد داده می‌شود
  - `could not verify` → شبکه به آن سرویس نمی‌رسد (مثلاً Google بدون VPN) — عبوری است و مانع نصب نمی‌شود
  - 💡 اگر پروکسی ویندوز را فعال کرده باشید، تست کلیدها هم از مسیر پراکسی می‌رود و Google/Cerebras هم تأیید می‌شوند
- فاصله‌های اضافی ابتدا و انتهای کلید به‌صورت خودکار حذف می‌شوند.
- فقط مدل‌های ارائه‌دهنده‌هایی که کلید داده‌اید ساخته می‌شوند.

---

## ۶. خروجی موفق نصب

در پایان باید این پیام را ببینید:

```
=================================================================
  INSTALLATION COMPLETED SUCCESSFULLY!
=================================================================

  LiteLLM endpoint (from Windows) : http://127.0.0.1:4000/v1

  ADMIN PANEL (UI) - open in the WINDOWS browser:
    URL       : http://127.0.0.1:4000/ui
    Username  : admin
    Password  : (the Master key below)

  Master key (also saved to)      : /home/<user>/.litellm/master_key.txt
  Master key                      : sk-...
  LiteLLM config file             : /home/<user>/.litellm/config.yaml
  Claude Code settings (Windows)  : /mnt/c/Users/<Name>/.claude/settings.json
  Windows proxy routing           : http://172.30.208.1:10808   (یا disabled)
  Container name                  : litellm
  Auto-start on WSL boot          : systemd service / wsl.conf boot command
  ...
```

---

## ۷. پنل مدیریت (UI)، اجرای خودکار و دستورات مدیریت

### پنل مدیریت LiteLLM

در مرورگر **ویندوز** باز کنید: `http://127.0.0.1:4000/ui`

| فیلد | مقدار |
|---|---|
| Username | `admin` |
| Password | همان **Master Key** — پسورد جداگانه‌ای وجود ندارد! |

🔑 **پسورد پنل دقیقاً همان Master Key است.** برای دیدن آن یکی از این راه‌ها:

```bash
freeagents credentials                          # URL + username + password همه با هم
cat ~/.litellm/master_key.txt                # فقط کلید
cat ~/.litellm/dashboard_credentials.txt     # فایل مخصوص اطلاعات ورود داشبورد
```

رشته‌ای که با `sk-` شروع می‌شود را کپی کنید و در فرم لاگین پنل بچسبانید.

> ℹ️ ورود به پنل به یک دیتابیس نیاز دارد؛ نصاب خودش کانتینر `litellm-db` (Postgres) را می‌سازد و به پروکسی وصل می‌کند. اگر قبلاً با نسخه‌های اولیه نصب کرده‌اید و خطای «Not connected to DB!» می‌بینید، یک بار گزینهٔ `1` را دوباره اجرا کنید.

### اجرای خودکار در بوت WSL

اسکریپت بسته به وضعیت سیستم شما یکی از دو مکانیزم را نصب می‌کند:

- اگر **systemd** فعال باشد (`[boot] systemd=true` در `/etc/wsl.conf`): سرویس `litellm.service` ساخته و enable می‌شود که در بوت، داکر و سپس کانتینر را بالا می‌آورد.
- در غیر این صورت: یک **boot command** در `/etc/wsl.conf` اضافه می‌شود (`command = /usr/local/bin/litellm-boot.sh`) که موقع باز شدن WSL اجرا شده و داکر + کانتینر را start می‌کند.

در هر دو حالت، خود کانتینر هم `--restart unless-stopped` است؛ یعنی تا وقتی خودتان `litellm down` نزده باشید، همیشه بالا می‌ماند.

### دستورات مدیریت سریع

بعد از نصب، این دستورات در ترمینال WSL در دسترس‌اند:

```bash
freeagents status     # وضعیت کانتینر، سلامت و مسیر فایل‌ها
freeagents credentials # نمایش URL، نام کاربری و پسورد پنل مدیریت
freeagents doctor      # تشخیص عمیق + تست چت واقعی برای تک‌تک مدل‌ها
freeagents up         # روشن کردن (داکر و کانتینر)
freeagents down       # خاموش کردن
freeagents restart    # ری‌استارت + انتظار برای سلامت
freeagents logs       # مشاهدهٔ زندهٔ لاگ‌ها (Ctrl+C برای خروج)
freeagents uninstall  # حذف کامل (کانتینر، کانفیگ‌ها و خود CLI)
```

### اجرای دوبارهٔ نصاب: کلیدها دوباره پرسیده می‌شوند؟

نه! اگر نصب قبلی موجود باشد، نصاب کلیدهای فعلی را (ماسک‌شده) نشان می‌دهد و می‌پرسد:

```
Existing API keys found (from the previous install):
  Groq       : gsk_****abcd
  ...
Keep these keys? [Y/n]:
```

- **Enter یا y** → همان کلیدهای قبلی حفظ می‌شوند (بدون هیچ سؤال اضافه)
- **n** → کلیدهای جدید از شما پرسیده می‌شود و جایگزین می‌شوند

Master Key هم **تغییر نمی‌کند** (پسورد داشبورد و کانفیگ Claude Code تان ثابت می‌ماند).

---

## ۸. راه‌اندازی Claude Code در ویندوز

1. اگر هنوز نصب نیست، در PowerShell نصبش کنید (فقط یک بار):
   ```powershell
   irm https://claude.ai/install.ps1 | iex
   ```
   یا با npm: `npm install -g @anthropic-ai/claude-code`
2. یک **ترمینال جدید** ویندوز باز کنید و وارد پوشهٔ پروژهٔ خود شوید: `cd C:\projects\my-app`
3. اجرا کنید: `claude`
4. همه‌چیز از قبل پیکربندی شده — مدل پیش‌فرض در `settings.json` ثبت شده و پیکر `/model` هم فهرست کامل مدل‌های پروکسی را با برچسب «From gateway» نشان می‌دهد (نیاز به **v2.1.129+**).

> 🖥️ اپ **Claude Desktop** هم خودکار پیکربندی می‌شود (پالیسی `HKCU\SOFTWARE\Policies\Claude`) — اپ را ری‌استارت کنید؛ مدل‌های `claude-*` در Cowork آماده‌اند.

> 📖 ادامهٔ ماجرا (انتخاب مدل، استفادهٔ روزمره، رفع اشکال سریع): **[usage.md](usage.md)**

---

## ۹. بررسی سلامت نصب

داخل WSL:

```bash
sudo docker ps                       # کانتینر litellm باید Up باشد
curl -s http://127.0.0.1:4000/health/liveliness   # خروجی: I'm alive!
```

با احراز هویت و دیدن لیست مدل‌ها:

```bash
curl -s http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $(cat ~/.litellm/master_key.txt)"
```

با مشکل مواجه شدید؟ → [troubleshooting.md](troubleshooting.md)

</div>
