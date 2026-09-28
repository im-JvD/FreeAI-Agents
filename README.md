<div align="tight" dir="rtl">

# 🚀 Free AI Agents

> **setup.sh** — یک اسکریپت، دو موتور: **LiteLLM** و **OmniRoute** را داخل WSL2 نصب، کانفیگ و مدیریت می‌کند و Claude Code و اپ Claude Desktop را به‌طور خودکار به آن‌ها وصل می‌کند.

نصب‌کننده و پیکربندی‌کنندهٔ یک‌مرحله‌ای **دو گیت‌وی رایگان** داخل **WSL2 Ubuntu** و اتصال آن‌ها به ابزار کدنویسی **Claude Code** و اپ **Claude Desktop** در ویندوز. هر دو گیت‌وی با **یک کلید مدل مشترک** (`claude-freeagents`) در دسترس‌اند؛ کاربر فقط یک‌بار کلیدهای ارائه‌دهنده‌ها را وارد می‌کند و می‌تواند هر کدام از دو موتور (یا هر دو) را نصب کند.

---

## ⚡ اجرای سریع (یک دستور)

داخل ترمینال **WSL2 Ubuntu** کافی است اجرا کنید:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/im-JvD/FreeAI-Agents/main/setup.sh)
```

یا با `wget`:

```bash
bash <(wget -qO- https://raw.githubusercontent.com/im-JvD/FreeAI-Agents/main/setup.sh)
```

> ⚠️ **نکتهٔ مهم:** حتماً از حالت `bash <( curl ... )` استفاده کنید، نه `curl ... | bash`؛ چون اسکریپت تعاملی است و باید بتواند از شما سؤال بپرسد. اگر خواستید اول دانلود کنید:
>
> ```bash
> curl -fsSL https://raw.githubusercontent.com/im-JvD/FreeAI-Agents/main/setup.sh -o /tmp/setup.sh
> bash /tmp/setup.sh
> ```
>
> 📝 اگر فایل را **دستی در ویندوز ذخیره می‌کنید** و خطایی مثل `set: pipefail: invalid option name` دیدید، مشکل خط‌پایان ویندوزی (CRLF) است — راه‌حل در [عیب‌یابی](docs/troubleshooting.md). (اسکریپت در اجرای `bash setup.sh` خودش این حالت را ترمیم می‌کند.)

---

## ✨ ویژگی‌ها

| ویژگی | توضیح |
|---|---|
| 🖥️ منوی تعاملی ۰–۹ | نصب (LiteLLM / OmniRoute / هر دو)، شروع/توقف، وضعیت، لاگ، Doctor، Config Manager، آپدیت و حذف کامل |
| 🧠 یک مدل، هر دو گیت‌وی | مدل واحد `claude-freeagents` (با برچسب `FreeAgents/LiteLLM` و `FreeAgents/Omni`) — دو گیت‌وی، یک نام مدل |
| 🐳 نصب داکر بدون تحریم | از مخازن `apt` اوبونتو (`docker.io`) — بدون `get.docker.com` |
| 🇮🇷 میرورهای ایرانی | ArvanCloud، Liara و IranServer در `/etc/docker/daemon.json` برای رفع خطای 403 |
| 📦 بدون build | ایمیج آمادهٔ `ghcr.io/berriai/litellm:main-latest` (با retry خودکار، fallback به ایمیج لوکال و میرور اختیاری ghcr) |
| 🟢 OmniRoute از npm رسمی | `npm install -g omniroute` (+ Node ≥ 20 از NodeSource و fallback به `registry.npmmirror.com`) — بدون داکر، بدون ریپوی واسط |
| 🔑 ۹ کلید API + تست زنده | Groq، OpenRouter، Google AI Studio، Cerebras، Mistral + GitHub Models، SambaNova، NVIDIA NIM، Together AI — هر کلید قبل از نصب واقعاً تست می‌شود (کشف کلیدهای جابجا) |
| 🔁 روتینگ هوشمند LiteLLM | یک model group روی همهٔ کلیدها با `simple-shuffle` + `num_retries=3` + `cooldown_time=30`؛ اگر یک ارائه‌دهنده خطا بدهد، بعدی خودکار امتحان می‌شود (لودبالانسر) |
| 🎯 Combo خودکار OmniRoute | یک combo با استراتژی `auto` که همان ارائه‌دهنده‌ها را پشت مدل واحد جمع می‌کند (لودبالانسر داخلی) |
| 🖥️ پنل‌های مدیریت | LiteLLM UI روی `http://127.0.0.1:4000/ui` و داشبورد OmniRoute روی `http://127.0.0.1:20128` |
| ⚙️ استارت خودکار در بوت WSL | سرویس systemd (یا boot command در `/etc/wsl.conf`) برای هر دو گیت‌وی |
| ⌨️ CLI مدیریت | یک دستور برای همه‌چیز: `freeagents up / down / restart / status / logs / doctor / credentials / update / uninstall` |
| 🪟 تشخیص هوشمند ویندوز | پیدا کردن مسیر پروفایل با PowerShell (حتی با فاصله در نام کاربری) |
| 🖥️ اپ Claude Desktop خودکار | ساخت پروفایل گیت‌وی در `%LOCALAPPDATA%\Claude-3p\configLibrary` + به‌روزرسانی `_meta.json` |
| 🔒 کلید امن | Master Key و secretهای OmniRoute خودکار ساخته و با دسترسی `600` ذخیره می‌شوند |
| 🧪 تست‌شده | ۲۳ سناریوی آفلاین (با mock کامل OmniRoute) + تست واقعی E2E با خودِ LiteLLM + تست زنده upstream با کلید واقعی |
| 🧪 تست زنده | `~/.free-ai-agents/live_test.sh` — سلامت و چت واقعی هر دو گیت‌وی با کلیدهای ذخیره‌شده |
| 🎛️ Config Manager | خاموش/روشن‌کردن پروکسی ویندوز، ورود دوبارهٔ توکن‌ها، اعمال دوبارهٔ کانفیگ Claude، تغییر گیت‌وی فعال دسکتاپ |
| 🔄 Update | دانلود خودکار آخرین نسخهٔ اسکریپت از همین ریپو + نصب مجدد کامل (کلیدها و پروکسی حفظ می‌شوند) |
| 🧹 Uninstall تمیز | حذف کانتینر، سرویس‌ها، پکیج npm، پروفایل‌های Claude و همهٔ فایل‌های ساخته‌شده — با یک تأیید (شامل `live_test.sh`) |

---

## 🎛️ منوی اسکریپت

```
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

توکن‌ها و پروکسی فقط **یک‌بار** پرسیده می‌شوند و برای هر دو موتور اعمال می‌شوند. پس از نصب، دستور `freeagents` در دسترس است:

```
freeagents up | down | restart | status | logs | doctor | credentials | update | uninstall
freeagents            (بازکردن دوبارهٔ همین منو)
freeagents status     (وضعیت هر دو گیت‌وی: health، پورت و فایل‌ها)
```

---

## 🧠 مدل واحد

| کلید مدل | نمایش در کلاد | توضیح |
|---|---|---|
| `claude-freeagents` | `FreeAgents/LiteLLM` | یک model group روی ۹ ارائه‌دهنده با retry/cooldown (LiteLLM) |
| `claude-freeagents` | `FreeAgents/Omni` | یک combo با استراتژی `auto` روی همان ارائه‌دهنده‌ها (OmniRoute) |

- هر دو گیت‌وی **همان یک نام مدل** را ارائه می‌دهند: `claude-freeagents` — کافی است همین را در Claude Code (`/model`) یا پروفایل Claude Desktop انتخاب کنید.
- برای سازگاری با کاتالوگ مدل اپ دسکتاپ، یک **alias مخفی** (`claude-sonnet-4-5`) هم تعریف می‌شود که به همان مدل واحد می‌رسد و در `/v1/models` نمایش داده نمی‌شود.
- فقط ارائه‌دهنده‌هایی که کلیدشان را وارد کرده‌اید در مدل نهایی حاضرند.

---

## 📋 پیش‌نیازها

- ویندوز ۱۰/۱۱ با **WSL2** و توزیع **Ubuntu** (تست‌شده روی Ubuntu 22.04+)
- **Claude Code** در سمت ویندوز (اختیاری، برای چت): نصب با `irm https://claude.ai/install.ps1 | iex`
- دسترسی `sudo` در اوبونتو
- اتصال اینترنت (برای `apt`، `npm` و `ghcr.io` — داکرهاب تحریم است ولی ghcr معمولاً باز است)

---

## 📁 ساختار مخزن

```
FreeAI-Agents/
├── setup.sh             ← اسکریپت اصلی (قابل اجرای مستقیم از GitHub)
├── freeagents/              ← ابزارهای runtime (سورس `live_test.sh` که به `~/.free-ai-agents/` کپی می‌شود)
├── .gitignore               ← لاگ‌های تست و بدل‌های تولیدشده نادیده گرفته می‌شوند
├── docs/                    ← مستندات کامل فارسی
│   ├── README.md            ← فهرست مستندات
│   ├── installation.md      ← راهنمای گام‌به‌گام نصب
│   ├── configuration.md     ← شرح کامل فایل‌های پیکربندی
│   ├── usage.md             ← استفاده در Claude Code و Claude Desktop
│   ├── uninstall.md         ← راهنمای حذف کامل
│   └── troubleshooting.md   ← عیب‌یابی خطاهای رایج
└── tests/                   ← تست‌های خودکار + نتایج اجرا
    ├── README.md            ← مستندات تست‌ها (شامل ۴ لایه: آفلاین، E2E، زنده)
    ├── run_all_tests.sh     ← سوئیت ۲۳ سناریویی آفلاین (بدون شبکه)
    ├── e2e_litellm_real.sh  ← تست واقعی E2E با خودِ LiteLLM (PyPI/venv)
    ├── e2e_real_docker.sh   ← تست واقعی E2E با Docker (روی WSL2 واقعی)
    ├── helpers/             ← mock سرور OmniRoute + بدل‌های ایزوله (stubbin)
    └── results/             ← فقط summary.txt ثبت می‌شود (لاگ‌ها ignore هستند)
```

---

## 📚 مستندات

- [راهنمای نصب گام‌به‌گام](docs/installation.md)
- [راهنمای استفاده در Claude Code](docs/usage.md) — نصب claude در ویندوز، `/model`، استفادهٔ روزمره
- [پیکربندی و فایل‌ها](docs/configuration.md)
- [حذف کامل (Uninstall)](docs/uninstall.md)
- [عیب‌یابی خطاهای رایج](docs/troubleshooting.md)
- [مستندات تست‌ها](tests/README.md)

---

## 🔒 نکتهٔ امنیتی

کلیدهای API شما به‌صورت متغیر محیطی به LiteLLM تزریق می‌شوند و داخل `config.yaml` نوشته **نمی‌شوند**. مسیر فایل‌های حساس:

| فایل | مسیر | دسترسی |
|---|---|---|
| Master Key لایت‌ال‌ال‌ام | `~/.litellm/master_key.txt` | `600` |
| ورودهای داشبورد LiteLLM | `~/.litellm/dashboard_credentials.txt` | `600` |
| secretهای OmniRoute (JWT/API-KEY/رمز اولیه) | `~/.omniroute/.env` | `600` |
| کلیدهای ارائه‌دهنده (برای نصب‌های بعدی) | `~/.free-ai-agents/provider_keys.env` | `600` |
| پروکسی اختیاری ویندوز | `~/.free-ai-agents/windows_proxy.txt` | `600` |

هرگز این فایل‌ها را در مخازن عمومی قرار ندهید.

</div>
