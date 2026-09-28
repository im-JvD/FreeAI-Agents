<div align="tight" dir="rtl">

# 🚀 Free AI Agents

> **setup.sh** — یک اسکریپت، دو موتور: **LiteLLM** و **OmniRoute** را داخل WSL2 نصب، کانفیگ و مدیریت می‌کند و Claude Code و اپ Claude Desktop را به‌طور خودکار به آن‌ها وصل می‌کند.

نصب‌کننده و پیکربندی‌کنندهٔ یک‌مرحله‌ای **پروکسی LiteLLM** (و مدیریت **OmniRoute**) داخل **WSL2 Ubuntu** و اتصال آن به ابزار کدنویسی هوش مصنوعی **Claude Code** در ویندوز — بدون نیاز به build، با ایمیج آماده و میرورهای ایرانی برای دور زدن تحریم‌ها.

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
| 🖥️ منوی تعاملی | گزینهٔ `1` نصب کامل، گزینهٔ `2` حذف کامل |
| 🐳 نصب داکر بدون تحریم | از مخازن `apt` اوبونتو (`docker.io`) — بدون `get.docker.com` |
| 🇮🇷 میرورهای ایرانی | ArvanCloud، Liara و IranServer در `/etc/docker/daemon.json` برای رفع خطای 403 |
| 📦 بدون build | فقط ایمیج آمادهٔ `ghcr.io/berriai/litellm:main-latest` (با retry خودکار، fallback به ایمیج لوکال و میرور اختیاری ghcr) |
| 🔑 ۵ کلید API + تست زنده | Groq، OpenRouter، Google AI، Cerebras، Mistral — هر کلید قبل از نصب واقعاً تست می‌شود (کشف کلیدهای جابجا) |
| 🧠 ۷ مدل کدنویسی | ساخت خودکار `config.yaml` فقط بر اساس کلیدهایی که داده‌اید |
| 🔁 اجرای پایدار | کانتینر با `--restart unless-stopped` روی پورت 4000 |
| 🖥️ پنل مدیریت | رابط وب LiteLLM روی `http://127.0.0.1:4000/ui` با دیتابیس اختصاصی (رفع کامل خطای «Not connected to DB») |
| ⚙️ استارت خودکار در بوت WSL | سرویس systemd یا boot command در `/etc/wsl.conf` |
| ⌨️ CLI مدیریت | `freeagents up / down / restart / status / credentials / doctor / logs / uninstall` |
| 🪟 تشخیص هوشمند ویندوز | پیدا کردن مسیر پروفایل با PowerShell (حتی با فاصله در نام کاربری) |
| 🖥️ اپ Claude Desktop خودکار | اتصال Cowork به پروکسی بدون Developer Mode — با پالیسی رجیستری `HKCU\SOFTWARE\Policies\Claude` (با `LITELLM_DESKTOP_CONFIG=0` قابل خاموش‌کردن) |
| 🔒 کلید امن | ساخت خودکار Master Key و ذخیرهٔ امن آن |
| 🧪 تست‌شده | ۳۴ سناریوی شبیه‌سازی‌شده + تست واقعی E2E با خودِ LiteLLM |
| 🎛️ Config Manager | خاموش/روشن‌کردن پروکسی ویندوز، ویرایش توکن‌ها، اعمال دوبارهٔ کانفیگ Claude، تغییر پروفایل فعال دسکتاپ |
| 🔄 Update | دانلود خودکار آخرین نسخهٔ اسکریپت از ریپو + نصب مجدد کامل (کلیدها و پروکسی حفظ می‌شوند) |

---

## 🎛️ منوی اسکریپت

```
 1 - Install  ( LiteLLM / OmniRoute / Both )      5 - Show Status
 2 - Start / Restart                              6 - Remove ( Full wipe )
 3 - Stop                                         7 - Show Live Logs
 4 - Update (re-download + reinstall, keeps keys) 8 - Config Manager
 0 - Exit
```

توکن‌ها و پروکسی فقط **یک‌بار** پرسیده می‌شوند و برای هر دو موتور اعمال می‌شوند. پس از نصب، دستور `freeagents` در دسترس است:

```
freeagents up | down | restart | status | logs | doctor | uninstall
freeagents            (بازکردن دوبارهٔ همین منو)
```

## 🧠 مدل‌های پشتیبانی‌شده

| مدل | ارائه‌دهنده | کاربرد |
|---|---|---|
| `claude-gpt-oss-120b` | Groq | کدنویسی و مدل پیش‌فرض (رایگان) |
| `claude-gpt-oss-20b` | Groq | فوق‌سریع — مدل پس‌زمینه کلاد کد (رایگان) |
| `claude-deepseek-v3.1` | OpenRouter | چت و کدنویسی (رایگان) |
| `claude-deepseek-v3-0324` | OpenRouter | کدنویسی رایگان جایگزین (رایگان) |
| `gemini-2.0-flash` | Google AI | سرعت بالا + کانتکست بزرگ (رایگان) |
| `claude-llama3.1-70b` | Cerebras | استنتاج فوق‌سریع (رایگان) |
| `claude-codestral` | Mistral | تخصصی کدنویسی |

---

## 📋 پیش‌نیازها

- ویندوز ۱۰/۱۱ با **WSL2** و توزیع **Ubuntu** (تست‌شده روی Ubuntu 22.04+)
- **Claude Code** در سمت ویندوز (فقط برای چت): نصب با `irm https://claude.ai/install.ps1 | iex`
- دسترسی `sudo` در اوبونتو
- اتصال اینترنت (برای `apt` و `ghcr.io` — داکرهاب تحریم است ولی ghcr معمولاً باز است)

---

## 📁 ساختار مخزن

```
FreeAI-Agents/
├── setup.sh             ← اسکریپت اصلی (قابل اجرای مستقیم از GitHub)
├── docs/                    ← مستندات کامل فارسی
│   ├── README.md            ← فهرست مستندات
│   ├── installation.md      ← راهنمای گام‌به‌گام نصب
│   ├── configuration.md     ← شرح کامل فایل‌های پیکربندی
│   ├── uninstall.md         ← راهنمای حذف کامل
│   └── troubleshooting.md   ← عیب‌یابی خطاهای رایج
└── tests/                   ← تست‌های خودکار + نتایج اجرا
    ├── README.md            ← مستندات تست‌ها
    ├── run_all_tests.sh     ← سوئیت ۱۷ سناریویی آفلاین
    ├── e2e_litellm_real.sh  ← تست واقعی E2E با LiteLLM
    ├── e2e_real_docker.sh   ← تست واقعی E2E با Docker (روی WSL2)
    ├── helpers/stubbin/     ← بدل‌های ایزوله برای تست
    └── results/             ← نتایج ثبت‌شدهٔ اجراها
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

کلیدهای API شما فقط به‌صورت متغیر محیطی به کانتینر LiteLLM تزریق می‌شوند و داخل `config.yaml` نوشته **نمی‌شوند**. Master Key هم در `~/.litellm/master_key.txt` با دسترسی `600` ذخیره می‌شود. هرگز این فایل‌ها را در مخازن عمومی قرار ندهید.

</div>
