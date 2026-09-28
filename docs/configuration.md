<div align="tight" dir="rtl">

# ⚙️ پیکربندی و فایل‌ها

این سند دقیقاً توضیح می‌دهد اسکریپت چه فایل‌هایی می‌سازد، هر بخش چه کاری می‌کند و چطور شخصی‌سازی‌شان کنید.

---

## ۱. نقشهٔ فایل‌های تولیدشده

| فایل | سیستم | نقش |
|---|---|---|
| `~/.litellm/config.yaml` | لینوکس (WSL) | پیکربندی LiteLLM: لیست مدل‌ها و تنظیمات |
| `~/.litellm/master_key.txt` | لینوکس (WSL) | کلید احراز هویت پروکسی (دسترسی `600`) |
| `~/.litellm/dashboard_credentials.txt` | لینوکس (WSL) | اطلاعات ورود پنل مدیریت: URL + Username + Password |
| `~/.litellm/db_password.txt` | لینوکس (WSL) | رمز دیتابیس Postgres پنل مدیریت (دسترسی `600`) |
| `~/.litellm/pgdata/` | لینوکس (WSL) | داده‌های ماندگار دیتابیس Admin UI |
| `/etc/docker/daemon.json` | لینوکس (WSL) | میرورهای ایرانی داکرهاب |
| `/usr/local/bin/litellm` | لینوکس (WSL) | دستورات مدیریت سریع (up/down/restart/…) |
| `/usr/local/bin/litellm-boot.sh` | لینوکس (WSL) | اسکریپت استارت خودکار در بوت WSL |
| `/etc/systemd/system/litellm.service` یا `/etc/wsl.conf` | لینوکس (WSL) | مکانیزم اجرای خودکار (بسته به وجود systemd) |
| `%USERPROFILE%\.claude\settings.json` | ویندوز | اتصال Claude Code به پروکسی (بلوک `env`) |

---

## ۲. ساختار `config.yaml`

نمونهٔ خروجی وقتی هر ۵ کلید داده شده باشد:

```yaml
model_list:
  # ---------------- Groq (fast inference) ----------------
  - model_name: claude-gpt-oss-120b
    litellm_params:
      model: groq/openai/gpt-oss-120b
      api_key: os.environ/GROQ_API_KEY
      api_base: https://api.groq.com/openai/v1
  - model_name: claude-gpt-oss-20b
    litellm_params:
      model: groq/openai/gpt-oss-20b
      api_key: os.environ/GROQ_API_KEY
      api_base: https://api.groq.com/openai/v1
  # ---------------- OpenRouter (free coding models) ----------------
  - model_name: claude-deepseek-v3.1
    litellm_params:
      model: openrouter/deepseek/deepseek-chat-v3.1:free
      api_key: os.environ/OPENROUTER_API_KEY
      api_base: https://openrouter.ai/api/v1
  - model_name: claude-deepseek-v3-0324
    litellm_params:
      model: openrouter/deepseek/deepseek-chat-v3-0324:free
      api_key: os.environ/OPENROUTER_API_KEY
      api_base: https://openrouter.ai/api/v1
  # ---------------- Google AI Studio (Gemini) ----------------
  - model_name: gemini-2.0-flash
    litellm_params:
      model: gemini/gemini-2.0-flash
      api_key: os.environ/GEMINI_API_KEY
  # ---------------- Cerebras ----------------
  - model_name: claude-llama3.1-70b
    litellm_params:
      model: cerebras/llama3.1-70b
      api_key: os.environ/CEREBRAS_API_KEY
      api_base: https://api.cerebras.ai/v1
  # ---------------- Mistral ----------------
  - model_name: claude-codestral


```yaml
  # ── نام‌های استاندارد آنتروپیک (برای اعتبارسنجی اپ Desktop) ──
  # این دو نام، alias روی همان مدل‌های اصلی/سریع هستند؛ اپ دسکتاپ
  # فقط نام‌های کاتالوگ Anthropic را در کانفیگ می‌پذیرد.
  - model_name: claude-sonnet-4-5
    litellm_params:
      model: <همان مقصد مدلِ اصلی>
  - model_name: claude-haiku-4-5
    litellm_params:
      model: <همان مقصد مدلِ سریع>
```

> نام مدل‌ها در چت اپ دسکتاپ با برچسب `FreeAgents/LiteLLM …` نمایش داده می‌شوند؛
> پروفایل موتور دوم هم به `FreeAgents/Omni …` یکدست می‌شود.
    litellm_params:
      model: mistral/codestral-latest
      api_key: os.environ/MISTRAL_API_KEY
      api_base: https://api.mistral.ai/v1

litellm_settings:
  drop_params: true        # پارامترهای پشتیبانی‌نشده بی‌صدا حذف می‌شوند

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
```

### نکات کلیدی

- **`model_name`** همان نامی است که Claude Code در پیکر `/model` می‌بیند.
- ⚠️ **اسم `model_name` باید شامل `claude` باشد** — اپ Claude Desktop فقط چنین مدل‌هایی را در پیکرش نشان می‌دهد. به همین دلیل نصاب اسم‌ها را با پیشوند `claude-` می‌سازد (`claude-gpt-oss-120b` و…). مقدار `model:` همان id واقعیِ ارائه‌دهنده است و دست‌نخورده می‌ماند.
- **`model`** با پیشوند ارائه‌دهنده (`groq/`، `openrouter/` و…) به LiteLLM می‌گوید درخواست را کجا بفرستد.
- **`api_key: os.environ/...`** یعنی کلید از متغیر محیطی کانتینر خوانده می‌شود — کلید واقعی **هرگز داخل فایل نوشته نمی‌شود**.
- **`api_base`** صریح نوشته شده تا هیچ‌وقت به آدرس پیش‌فرض اشتباه نرود (مدل Gemini نیازی به آن ندارد).
- **`drop_params: true`** جلوی خطاهایی را می‌گیرد که از فرستادن پارامترهای اختصاصی یک ارائه‌دهنده به ارائه‌دهندهٔ دیگر پیش می‌آید.

---

## ۳. Master Key

- هنگام نصب یک کلید تصادفی ۶۴ کاراکتری ساخته می‌شود: `sk-` + خروجی `openssl rand -hex 32`.
- در `~/.litellm/master_key.txt` ذخیره (دسترسی `600`) و به‌عنوان `LITELLM_MASTER_KEY` به کانتینر تزریق می‌شود.
- هر درخواست به پروکسی (از جمله از سمت Claude Code) باید این کلید را در هدر `Authorization: Bearer ...` بفرستد.
- اگر master key را گم کردید: `cat ~/.litellm/master_key.txt`

---

## ۴. اجرای کانتینر

معادل دستوری که اسکریپت اجرا می‌کند:

```bash
sudo docker run -d \
  --name litellm \
  --restart unless-stopped \
  -p 4000:4000 \
  -v ~/.litellm/config.yaml:/app/config.yaml:ro \
  -e LITELLM_MASTER_KEY="sk-..." \
  -e GROQ_API_KEY="..." \
  ghcr.io/berriai/litellm:main-latest \
  --config /app/config.yaml \
  --port 4000
```

- `--restart unless-stopped`: با ری‌استارت WSL/ویندوز خودکار بالا می‌آید (مگر اینکه خودتان stop کرده باشید).
- `-v ...:ro`: کانفیگ فقط-خواندنی mount می‌شود.
- پارامترهای پایانی، آرگومان‌های CLI باینری `litellm` داخل ایمیج هستند.

---

## ۵. ساختار `settings.json` کلاد کد (سمت ویندوز)

نصاب فایل `%USERPROFILE%\.claude\settings.json` را می‌سازد. کلاد کد این فایل را به‌عنوان پیکربندی دائمی می‌خواند و بلوک `env` آن به‌صورت متغیر محیطی به هر نشست تزریق می‌شود:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "http://127.0.0.1:4000",
    "ANTHROPIC_AUTH_TOKEN": "sk-...",
    "ANTHROPIC_MODEL": "claude-gpt-oss-120b",
    "ANTHROPIC_SMALL_FAST_MODEL": "claude-gemini-2.0-flash",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "claude-gpt-oss-120b",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "claude-gpt-oss-120b",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "claude-gemini-2.0-flash",
    "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  }
}
```

| فیلد | توضیح |
|---|---|
| `ANTHROPIC_BASE_URL` | آدرس پروکسی — **بدون پسوند `/v1`** (کلاد کد خودش مسیرهای Anthropic را می‌سازد؛ `/v1/v1/messages` خطا می‌دهد). چون WSL2 پورت‌ها را با ویندوز به اشتراک می‌گذارد، `127.0.0.1` از ویندوز هم کار می‌کند |
| `ANTHROPIC_AUTH_TOKEN` | همان Master Key — کلاد کد آن را به‌عنوان توکن احراز هویت به پروکسی می‌فرستد |
| `ANTHROPIC_MODEL` | مدل پیش‌فرض — اولین مدلِ کدنویسیِ موجود بر اساس کلیدهای شما (اولویت: Groq → OpenRouter → Gemini → Cerebras → Mistral) |
| `ANTHROPIC_SMALL_FAST_MODEL` | مدل «پس‌زمینه/سریع» — اگر کلید Gemini داده باشید Gemini Flash، وگرنه همان مدل پیش‌فرض |
| `ANTHROPIC_DEFAULT_SONNET/OPUS/HAIKU_MODEL` | نگاشت سطوح Sonnet/Opus/Haiku پیکر `/model` به مدل‌های پروکسی |
| `CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY` | با مقدار `1`، کلاد کد (نسخهٔ **v2.1.129 به بعد**) فهرست مدل‌ها را مستقیم از پروکسی (`GET /v1/models`) می‌گیرد و در پیکر `/model` با برچسب «From gateway» نشان می‌دهد — یعنی هر مدلی که به `config.yaml` اضافه کنید خودکار در پیکر ظاهر می‌شود |
| `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` | جلوگیری از ترافیک غیرضروری کلاد کد به سرورهای آنتروپیک (مناسب استفادهٔ آفلاین/پروکسی محلی) |

نکتهٔ پشتیبان‌گیری: اگر از قبل `settings.json` داشته باشید، نصاب آن را به `settings.json.bak.<زمان>` کپی می‌کند و در حذف نصب، جدیدترین بکاپ به‌جای فایل برمی‌گردد.

> 🖥️ اپ Claude Desktop هم به‌طور خودکار پیکربندی می‌شود: نصاب پروفایل گیت‌وی را مستقیم در configLibrary اپ (`%LOCALAPPDATA%\Claude-3p\configLibrary`) می‌نویسد — بدون رجیستری و بدون دسترسی ادمین؛ در حذف نصب هم پاک می‌شود. غیرفعال‌سازی: `LITELLM_DESKTOP_CONFIG=0 bash setup.sh`.

---

## ۶. پروکسی ویندوز (عبور ترافیک از فیلترشکن ویندوز)

در گام ۴ نصب می‌توانید فعالش کنید (`Route provider traffic through your Windows proxy? [y/N]`). با فعال‌سازی، تمام ترافیک LiteLLM به ارائه‌دهنده‌ها از برنامهٔ پراکسی ویندوز (Clash / v2rayN / Hiddify / Nekoray) رد می‌شود و تحریم منطقه‌ای Google/Cerebras و… بدون VPN سیستم‌عامل حل می‌شود.

| مورد | مقدار |
|---|---|
| فایل تنظیمات | `~/.litellm/windows_proxy.txt` (یک خط: `http://IP:PORT`) |
| متغیرهای کانتینر | `HTTP_PROXY` و `HTTPS_PROXY` = آدرس پراکسی، `NO_PROXY` = `localhost,127.0.0.1,litellm-db` |
| آدرس پیش‌فرض | IP ویندوز از دید WSL (گیت‌وی مسیر پیش‌فرض) + پورت `7890` |
| تست نصب | یک درخواست واقعی از داخل پراکسی به Groq زده می‌شود؛ ناموفق؟ با تأیید شما ذخیره می‌شود |
| نصب دوباره | پرسیده می‌شود «Keep the Windows proxy setting?» — Enter = نگه‌داشتن، `n` = تعویض |
| `freeagents doctor` | وضعیت در بخش `[STACK]` نمایش داده می‌شود و تست ارائه‌دهنده‌ها از مسیر پراکسی می‌رود |

پیش‌نیازها: برنامهٔ پراکسی روی ویندوز در حال اجرا باشد و **Allow LAN** داشته باشد؛ پورت HTTP پراکسی را بدهید (Clash: `7890`، v2rayN: `10809`، Hiddify: `12334`).

---

## ۶. پنل مدیریت (UI)

LiteLLM یک رابط وب مدیریت دارد که با نصب، روی این آدرس فعال می‌شود:

```
http://127.0.0.1:4000/ui
```

- در مرورگر **ویندوز** باز کنید (WSL2 پورت را به ویندوز منتقل می‌کند).
- نام کاربری: `admin` — رمز عبور: همان **Master Key** (پسورد جداگانه وجود ندارد).
- ⚠️ ورود به UI به دیتابیس نیاز دارد؛ نصاب به‌طور خودکار کانتینر `litellm-db` (Postgres) را می‌سازد و `DATABASE_URL` را به پروکسی می‌دهد. داده‌های DB در `~/.litellm/pgdata` ماندگارند و رمز DB در `~/.litellm/db_password.txt` (دسترسی 600) ذخیره می‌شود.
- این اطلاعات با متغیرهای `UI_USERNAME` و `UI_PASSWORD` روی کانتینر تنظیم شده‌اند.
- دیدن سریع اطلاعات ورود: `freeagents credentials`
- یک کپی هم در `~/.litellm/dashboard_credentials.txt` ذخیره می‌شود (دسترسی 600).
- از این پنل می‌توانید مدل‌ها را تست کنید، لاگ ببینید و مصرف را ببینید.

---

## ۷. اجرای خودکار در بوت WSL (Persistence)

خاموش/روشن شدن ویندوز باعث می‌شود WSL هم ری‌استارت شود. اسکریپت برای «همیشه روشن ماندن» دو لایه می‌سازد:

1. سیاست `--restart unless-stopped` روی خود کانتینر (داخل داکر).
2. استارت خودکار دیمن داکر + کانتینر در بوت WSL، با یکی از این دو مکانیزم:
   - **systemd** (اگر فعال باشد): سرویس `litellm.service` — مدیریت با `systemctl status litellm`
   - **boot command**: خط `command = /usr/local/bin/litellm-boot.sh` در `/etc/wsl.conf` (بدون systemd)

> 💡 برای فعال‌سازی systemd (پیشنهادی) در `/etc/wsl.conf` این را بگذارید و بعد `wsl --shutdown` کنید:
> ```ini
> [boot]
> systemd=true
> ```

می‌توانید حالت را هم اجبار کنید — قبل از اجرای نصاب:

```bash
LITELLM_BOOT_MODE=systemd bash setup.sh   # فقط سرویس systemd
LITELLM_BOOT_MODE=wslconf bash setup.sh   # فقط boot command در /etc/wsl.conf
# پیش‌فرض: تشخیص خودکار (auto)
```

---

## ۸. دستورات مدیریت سریع (`litellm` CLI)

نصب، یک CLI به نام `litellm` در `/usr/local/bin` می‌سازد:

| دستور | کار |
|---|---|
| `freeagents up` | استارت دیمن داکر (اگر خاموش باشد) + کانتینر + انتظار برای سلامت |
| `litellm down` | توقف کانتینر |
| `freeagents restart` | ری‌استارت + انتظار برای سلامت |
| `freeagents status` | وضعیت کانتینر، policy، سلامت، آدرس پنل و مسیر فایل‌ها |
| `freeagents credentials` | نمایش URL/نام‌کاربری/پسورد پنل مدیریت (پسورد = Master Key) |
| `freeagents doctor` | تشخیص عمیق: اتصال هر ارائه‌دهنده + تست چت واقعی برای تک‌تک مدل‌ها |
| `freeagents logs` | دنبال‌کردن زندهٔ لاگ‌ها |
| `freeagents uninstall` | حذف کامل همه‌چیز (با تأیید) — معادل گزینهٔ ۲ نصاب |

> ⚠️ اگر روزی LiteLLM را با `pip install litellm` در خود WSL نصب کنید، باینری pip جای این CLI را در PATH می‌گیرد. برای پروکسی داکری نیازی به pip نیست.

---

## ۹. متغیرهای محیطی نصاب

قبل از اجرای نصاب می‌توانید رفتار آن را با متغیرهای محیطی تنظیم کنید:

| متغیر | پیش‌فرض | کاربرد |
|---|---|---|
| `LITELLM_BOOT_MODE` | `auto` | حالت استارت خودکار: `auto` / `systemd` / `wslconf` |
| `LITELLM_IMAGE` | `ghcr.io/berriai/litellm:main-latest` | ایمیج سفارشی (رجیستری دلخواه) |
| `LITELLM_GHCR_MIRROR` | خالی | میرور جایگزین ghcr (مثلاً `ghcr.nju.edu.cn`) — فقط وقتی pull مستقیم شکست خورد استفاده می‌شود |
| `LITELLM_PULL_RETRIES` | `3` | تعداد تلاش مجدد pull قبل از fallback |
| `LITELLM_KEY_CHECK` | `1` | تست زندهٔ هر کلید API به سرویس‌دهنده‌اش قبل از ساخت کانتینر (`0` = غیرفعال) |
| `LITELLM_KEY_CHECK_TIMEOUT` | `10` | مهلت ثانیه‌ای هر تست کلید |
| `LITELLM_DOCTOR_TIMEOUT` | `45` | مهلت ثانیه‌ای تست زندهٔ هر مدل در `freeagents doctor` |
| `LITELLM_UI_DB` | `1` | `1` = کانتینر Postgres برای ورود به Admin UI ساخته می‌شود؛ `0` = بدون DB (UI لاگین ندارد، چت سالم است) |
| `LITELLM_DB_IMAGE` | `postgres:16-alpine` | ایمیج دیتابیس Admin UI (از داکرهاب و از مسیر میرورها) |

نمونه:

```bash
LITELLM_GHCR_MIRROR=ghcr.nju.edu.cn LITELLM_PULL_RETRIES=5 bash setup.sh
```

---

## ۱۰. شخصی‌سازی‌های رایج

### آیا باید برای Claude Code جداگانه «کلید مجازی» بسازیم؟

نه. کلیدی که Claude Code به آن وصل می‌شود همان **Master Key** است و نصاب از قبل آن را داخل `settings.json` (فیلد `ANTHROPIC_AUTH_TOKEN`) نوشته است. برای اطمینان:

```bash
litellm credentials     # پسورد داشبورد (همان Master Key)
grep ANTHROPIC_AUTH_TOKEN /mnt/c/Users/*/'.claude/settings.json'
```

هر دو مقدار یکی هستند. دکمهٔ «Create Key» داخل داشبورد (Virtual Keys) فقط برای حالت‌های پیشرفته است: کلید جدا برای هر کلاینت، سقف مصرف و گزارش‌گیری تفکیکی — برای استفادهٔ تک‌کاربره ضرورتی ندارد.

### افزودن مدل جدید

بخش زیر را به `model_list` در `config.yaml` اضافه کنید (نمونه برای یک مدل Groq دیگر):

```yaml
  - model_name: llama-3.1-8b-instant
    litellm_params:
      model: groq/llama-3.1-8b-instant
      api_key: os.environ/GROQ_API_KEY
      api_base: https://api.groq.com/openai/v1
```

سپس کانتینر را ری‌استارت کنید — کشف مدل گیت‌وی (discovery) فعال است، پس مدل جدید خودکار در پیکر `/model` کلاد کد **و پیکر اپ Desktop** ظاهر می‌شود (فقط `model_name` را حتماً با پیشوند `claude-` بدهید؛ `model:` همان id واقعی ارائه‌دهنده):

```bash
sudo docker restart litellm
```

### تغییر پورت

1. متغیر `LITELLM_PORT` در ابتدای اسکریپت `setup.sh` را تغییر دهید (مثلاً `4010`).
2. دوباره گزینهٔ `1` (نصب) را اجرا کنید — کانتینر قبلی حذف و با پورت جدید ساخته می‌شود و `settings.json` کلاد کد هم به‌روز می‌شود.

### تغییر نام کانتینر یا مسیر کانفیگ

هر دو در ابتدای اسکریپت به‌صورت متغیر تعریف شده‌اند: `CONTAINER_NAME` و `LITELLM_DIR`.

### به‌روزرسانی ایمیج LiteLLM

```bash
sudo docker pull ghcr.io/berriai/litellm:main-latest
sudo docker rm -f litellm
# سپس دوباره گزینهٔ 1 اسکریپت را اجرا کنید
```

</div>
