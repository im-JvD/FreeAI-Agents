<div align="tight" dir="rtl">

# 📥 راهنمای نصب گام‌به‌گام

نصاب یک اسکریپت واحد است که می‌تواند **LiteLLM**، **OmniRoute** یا **هر دو** را نصب کند؛ کلیدها و پروکسی فقط **یک‌بار** پرسیده می‌شوند و برای هر دو اعمال می‌شوند. هر دو گیت‌وی همان **مدل واحد** `claude-freeagents` را ارائه می‌دهند.

---

## ۱. پیش‌نیازها

| پیش‌نیاز | بررسی |
|---|---|
| ویندوز ۱۰/۱۱ | — |
| WSL2 با توزیع Ubuntu | `wsl -l -v` در PowerShell → ستون VERSION باید `2` باشد |
| Claude Code در ویندوز (اختیاری) | نصب در PowerShell: `irm https://claude.ai/install.ps1 | iex` — نسخهٔ **v2.1.129+** برای کشف مدل گیت‌وی |
| دسترسی sudo در اوبونتو | اجرای `sudo -v` در ترمینال اوبونتو |
| اینترنت | برای `apt`، `npm` و `ghcr.io` — Node ≥ ۲۰ در صورت نیاز خودکار نصب می‌شود |

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
            Script Version [ 0.0.6 ]   LiteLLM + OmniRoute
=================================================================

   1 - Install  ( LiteLLM / OmniRoute / Both )
   2 - Start / Restart  ( both gateways )
   3 - Stop             ( both gateways )
   4 - Update ( re-download from the repo + reinstall, keeps keys )
   5 - Show Status      ( both gateways )
   6 - Remove ( full wipe, both gateways )
   7 - Show Live Logs   ( LiteLLM / OmniRoute )
   8 - Doctor ( deep diagnosis, both gateways )
   9 - Config Manager ( proxy - tokens - Claude config - active gateway )
   0 - Exit ( CTRL + C )
```

> ⚠️ دستورهای قدیمی `litellm up/down` و `omni up/down` وجود ندارند؛ همه‌چیز از همین منو یا دستور واحد `freeagents` انجام می‌شود.

---

## ۴. انتخاب گیت‌وی و مراحل نصب

با انتخاب گزینهٔ `1` می‌پرسد کدام موتور نصب شود:

```
   1 - LiteLLM   ( Docker container, port 4000, admin UI )
   2 - OmniRoute ( official npm package, port 20128, dashboard )
   3 - Both      ( recommended )
```

| حالت | چه چیزی نصب می‌شود |
|---|---|
| `1` LiteLLM | داکر + کانتینر LiteLLM + پنل UI (پورت 4000) |
| `2` OmniRoute | Node ≥ ۲۰ + پکیج npm رسمی `omniroute` + داشبورد (پورت 20128) |
| `3` هر دو | هر دو موتور، با **یک بار** پرسیدن کلیدها؛ گیت‌وی فعال = LiteLLM |

مراحل مشترک (نمونهٔ حالت «هر دو»):

| مرحله | کار |
|---|---|
| `[1/7]` | بررسی محیط WSL2، وجود `powershell.exe` و ابزارهای لازم |
| `[2/7]` | نصب داکر از مخازن apt اوبونتو (`docker.io`) — فقط اگر لازم باشد |
| `[3/7]` | نوشتن میرورهای ایرانی در `/etc/docker/daemon.json` (با بکاپ فایل قبلی) |
| `[4/7]` | پروکسی ویندوز (اختیاری) + دریافت و تست زندهٔ کلیدهای ۹ ارائه‌دهنده |
| `[5/7]` | ساخت `~/.litellm/config.yaml` + Master Key + pull ایمیج + اجرای کانتینر |
| OmniRoute | نصب/بررسی Node، `npm install -g omniroute`، نوشتن `~/.omniroute/.env`، ساخت لانچر و سرویس |
| پایان | کانفیگ Claude Code/Desktop + اجرای خودکار در بوت + نصب CLI `freeagents` |

---

### پروکسی ویندوز (اختیاری ولی خیلی مفید)

قبل از دریافت کلیدها، نصاب می‌پرسد:

```
Route provider traffic through your Windows proxy? [y/N]:
```

اگر روی ویندوز یک برنامهٔ پراکسی دارید (**Clash / v2rayN / Hiddify / Nekoray**)، با `y` ترافیک **هر دو گیت‌وی** به سمت ارائه‌دهنده‌ها (Groq، Google، Cerebras و…) از همان پراکسی رد می‌شود — یعنی **رفع تحریم بدون VPN سیستم‌عامل**:

- آدرس پیشنهادی خودکار تشخیص داده می‌شود (IP ویندوز از دید WSL + پورت `7890`) — Enter بزنید یا IP:PORT دلخواه بدهید.
- نصاب یک تست واقعی از داخل همان پراکسی می‌زند و نتیجه را نشان می‌دهد.
- انتخاب شما در `~/.free-ai-agents/windows_proxy.txt` ذخیره می‌شود و نصب دوباره آن را نگه می‌دارد (یا با `n` عوضش کنید).
- LiteLLM: متغیرهای `HTTP_PROXY`/`HTTPS_PROXY` روی کانتینر — OmniRoute: همان متغیرها در `~/.omniroute/.env`.
- در `freeagents doctor` وضعیتش نمایش داده می‌شود و تست ارائه‌دهنده‌ها از مسیر پراکسی می‌رود.

نکته: در برنامهٔ پراکسی گزینهٔ **Allow LAN** را روشن کنید تا اتصال از WSL پذیرفته شود.

---

## ۵. دریافت و وارد کردن کلیدهای API

نصاب اول **۵ ارائه‌دهندهٔ اصلی** را می‌پرسد و بعد می‌پرسد آیا ۴ ارائه‌دهندهٔ اضافه را هم می‌خواهید:

```
Add more free providers (GitHub Models, SambaNova, NVIDIA NIM, Together AI)? [y/N]:
```

**کلیدی ندارید؟ فقط Enter بزنید** تا رد شود — اما **حداقل یک کلید الزامی است** (اگر هیچ کلیدی ندهید، دوباره سؤال می‌شود؛ حداکثر ۳ بار).

### ارائه‌دهنده‌های اصلی

| ترتیب | سرویس | لینک دریافت کلید رایگان | پیشوند نمونه |
|---|---|---|---|
| 1 | Groq | [console.groq.com/keys](https://console.groq.com/keys) | `gsk_...` |
| 2 | OpenRouter | [openrouter.ai/keys](https://openrouter.ai/keys) | `sk-or-...` |
| 3 | Google AI Studio | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) | `AIza...` |
| 4 | Cerebras | [cloud.cerebras.ai](https://cloud.cerebras.ai) | `csk-...` |
| 5 | Mistral | [console.mistral.ai/api-keys](https://console.mistral.ai/api-keys) | `...` |

### ارائه‌دهنده‌های اضافه (اختیاری)

| ترتیب | سرویس | لینک دریافت کلید | نکته |
|---|---|---|---|
| 1 | GitHub Models | [github.com/settings/tokens](https://github.com/settings/tokens) | فقط برای LiteLLM؛ OmniRoute در حالت API-key پشتیبانی نمی‌کند و در نصب رد می‌شود (در داشبورد قابل افزودن است) |
| 2 | SambaNova | [cloud.sambanova.ai/apis](https://cloud.sambanova.ai/apis) | — |
| 3 | NVIDIA NIM | [build.nvidia.com](https://build.nvidia.com) | پیشوند `nvapi-` |
| 4 | Together AI | [api.together.ai/settings/api-keys](https://api.together.ai/settings/api-keys) | — |

نکته‌ها:

- کلیدها هنگام تأیید به‌صورت ماسک‌شده نمایش داده می‌شوند (مثلاً `gsk_****abcd`).
- 🧪 بعد از دریافت کلیدها، نصاب هر کلید را **به‌صورت زنده** به سرویس‌دهنده تست می‌کند:
  - `valid (HTTP 200)` → کلید سالم است
  - `REJECTED (HTTP 401/403)` → کلید اشتباه/جابجاست و پیشنهاد واردکردن مجدد داده می‌شود
  - `could not verify` → شبکه به آن سرویس نمی‌رسد (مثلاً Google بدون VPN) — عبوری است و مانع نصب نمی‌شود
  - 💡 اگر پروکسی ویندوز را فعال کرده باشید، تست کلیدها هم از مسیر پراکسی می‌رود و Google/Cerebras هم تأیید می‌شوند
- فاصله‌های اضافی ابتدا و انتهای کلید به‌صورت خودکار حذف می‌شوند.
- فقط ارائه‌دهنده‌هایی که کلید داده‌اید در مدل واحد حاضر می‌شوند.

---

## ۶. خروجی موفق نصب

در پایان باید چیزی شبیه این ببینید:

```
=================================================================
  INSTALLATION COMPLETED SUCCESSFULLY!
=================================================================

  Engines installed : both
  Active gateway    : litellm  (FreeAgents/LiteLLM)
  Model for Claude  : claude-freeagents

  LiteLLM
    Endpoint    : http://127.0.0.1:4000/v1
    Admin panel : http://127.0.0.1:4000/ui  (user: admin)
    Master key  : /home/<user>/.litellm/master_key.txt   (also the dashboard password)
    Config      : /home/<user>/.litellm/config.yaml

  OmniRoute
    Endpoint    : http://127.0.0.1:20128/v1
    Dashboard   : http://127.0.0.1:20128
    Dashboard   : password stored in /home/<user>/.omniroute/.env (INITIAL_PASSWORD)
    Claude key  : /home/<user>/.free-ai-agents/omniroute_claude.key

  Claude Code settings : %USERPROFILE%\.claude\settings.json
  Auto-start on boot   : systemd units (freeagents boot helper / omniroute.service)
  Windows proxy        : disabled

  MANAGEMENT
    freeagents                 open this menu
    freeagents status          both gateways
    freeagents doctor          deep diagnosis (both)
    freeagents logs omniroute  live logs of the second engine

  NEXT STEPS (on WINDOWS)
    1. Install Claude Code (once):  irm https://claude.ai/install.ps1 | iex
    2. Open a NEW terminal and run: claude
    3. Pick the model with /model - it is listed as 'claude-freeagents'
       (Claude Desktop shows it as 'FreeAgents/LiteLLM').
```

---

## ۷. پنل‌های مدیریت، اجرای خودکار و دستورات

### پنل‌ها

| پنل | آدرس | ورود |
|---|---|---|
| LiteLLM UI | `http://127.0.0.1:4000/ui` | `admin` / همان Master Key |
| OmniRoute Dashboard | `http://127.0.0.1:20128` | رمز ذخیره‌شده در `~/.omniroute/.env` (`INITIAL_PASSWORD`) |

```bash
freeagents credentials     # URL/نام‌کاربری/رمز هر دو پنل + توکن‌های Claude
```

### اجرای خودکار در بوت WSL

- اگر **systemd** فعال باشد: سرویس‌های `litellm.service` و `omniroute.service` نصب و enable می‌شوند.
- در غیر این صورت: یک **boot command** در `/etc/wsl.conf` اضافه می‌شود (`command = /usr/local/bin/freeagents-boot.sh`).
- خود کانتینر LiteLLM هم `--restart unless-stopped` است.

### دستورات مدیریت سریع

```bash
freeagents              # باز کردن منو
freeagents status       # وضعیت هر دو گیت‌وی (health، پورت، فایل‌ها)
freeagents up|down|restart
freeagents logs [litellm|omniroute]
freeagents doctor [litellm|omniroute]
freeagents credentials
freeagents update       # دانلود مجدد از ریپو + نصب مجدد (کلیدها حفظ می‌شوند)
freeagents uninstall    # حذف کامل
```

### اجرای دوبارهٔ نصاب: کلیدها دوباره پرسیده می‌شوند؟

نه! اگر نصب قبلی موجود باشد، نصاب کلیدهای فعلی را (ماسک‌شده) نشان می‌دهد و می‌پرسد:

```
Existing provider keys found (from the previous install):
  Groq       : gsk_****abcd
  ...
Keep these keys? [Y/n]:
```

- **Enter یا y** → همان کلیدهای قبلی حفظ می‌شوند (بدون هیچ سؤال اضافه)
- **n** → کلیدهای جدید از شما پرسیده می‌شود و جایگزین می‌شوند

Master Key و secretهای OmniRoute هم **تغییر نمی‌کنند** (پسورد داشبوردها و کانفیگ Claude Code ثابت می‌ماند).

---

## ۸. راه‌اندازی Claude Code و Claude Desktop

1. اگر Claude Code نصب نیست، در PowerShell نصبش کنید (فقط یک بار):
   ```powershell
   irm https://claude.ai/install.ps1 | iex
   ```
   یا با npm: `npm install -g @anthropic-ai/claude-code`
2. یک **ترمینال جدید** ویندوز باز کنید و وارد پوشهٔ پروژهٔ خود شوید: `cd C:\projects\my-app`
3. اجرا کنید: `claude`
4. همه‌چیز از قبل پیکربندی شده — مدل پیش‌فرض `claude-freeagents` در `settings.json` ثبت شده و پیکر `/model` هم فهرست مدل‌ها را با برچسب «From gateway» نشان می‌دهد (نیاز به **v2.1.129+**).

> 🖥️ اپ **Claude Desktop** هم خودکار پیکربندی می‌شود: نصاب پروفایل گیت‌وی را در `%LOCALAPPDATA%\Claude-3p\configLibrary` می‌نویسد و گیت‌وی فعال را در `_meta.json` علامت می‌زند. اپ را کامل ببندید و باز کنید؛ مدل با برچسب `FreeAgents/LiteLLM` یا `FreeAgents/Omni` ظاهر می‌شود.

> 📖 ادامهٔ ماجرا (انتخاب مدل، تعویض گیت‌وی، استفادهٔ روزمره، رفع اشکال سریع): **[usage.md](usage.md)**

---

## ۹. بررسی سلامت نصب

داخل WSL:

```bash
freeagents status                    # وضعیت و health هر دو گیت‌وی
freeagents doctor                    # تشخیص عمیق + تست زندهٔ ارائه‌دهنده‌ها
```

بررسی دستی:

```bash
# LiteLLM
curl -s http://127.0.0.1:4000/health/liveliness          # خروجی: I'm alive!
curl -s http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $(cat ~/.litellm/master_key.txt)"

# OmniRoute
curl -s http://127.0.0.1:20128/healthz                   # خروجی: ok
```

با مشکل مواجه شدید؟ → [troubleshooting.md](troubleshooting.md)

</div>
