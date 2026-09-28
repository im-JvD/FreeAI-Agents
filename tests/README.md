<div align="tight" dir="rtl">

# 🧪 مستندات تست‌ها

کیفیت اسکریپت `setup.sh` با **چهار لایهٔ تست** تضمین شده است. لاگ‌های پرحجم در `.gitignore` هستند و فقط `results/summary.txt` در گیت ثبت می‌شود.

---

## 📊 نتیجهٔ آخرین اجرا در محیط ایزوله (سندباکس)

| لایهٔ تست | نتیجه |
|---|---|
| سوئیت آفلاین (۲۳ سناریو، T00–T22) | ✅ ۲۳ پاس / ۰ شکست / ۰ اسکیپ |
| E2E واقعی با خودِ LiteLLM v1.103.0 از PyPI (کلیدهای جعلی، تست روتینگ) | ✅ پاس |
| E2E واقعی با Docker + npm (روی WSL2 واقعی) | ⏭️ فقط روی WSL2 واقعی — در سندباکس SKIP |
| **تست زندهٔ upstream (کلید واقعی، هر دو گیت‌وی)** | ⏭️ فقط با کلید واقعی روی WSL2 — در سندباکس SKIP |

جزئیات: [`results/summary.txt`](results/summary.txt) (لاگ‌های تکی `T*.log` و `E2E_*.log` موقع اجرا در `results/` ساخته می‌شوند ولی ignore هستند).

---

## ۱️⃣ لایهٔ اول — سوئیت آفلاین (بدون شبکه، بدون داکر)

**فایل:** [`run_all_tests.sh`](run_all_tests.sh) — حدود ۸۰ ثانیه

منطق کامل اسکریپت را با «بدل‌های قطعی» (stub) تست می‌کند:

| بدل | کار |
|---|---|
| `docker` (+ `docker.installer`) | شبیه‌س وضعیت‌مند: ثبت فراخوانی‌ها، دفتر کانتینرها، `docker inspect`، `pull` با شکست قابل تنظیم |
| `npm` / `node` | نصب `omniroute` با کپی `omniroute.installer`، ثبت `npm-calls.log`، fallback رجیستری |
| `omniroute` (+ `omniroute.installer`) | سرور واقعی: `mock_omniroute.py` که REST رسمی OmniRoute را پیاده می‌کند (login با کوکی `auth_token`، `providers`، `keys`، `combos`) |
| `apt-get` | موقع «نصب docker.io» بدل داکر را نصب می‌کند |
| `sudo` | بدون ارتقای دسترسی؛ `/etc/docker` و `/usr/local/bin` و `/etc/systemd` را به ریشهٔ مجازی منتقل می‌کند |
| `powershell.exe` | پروفایل ویندوزی با فاصله در نام کاربری (`Test User`) |
| `curl` | کد سلامت قابل تنظیم (۲۰۰ یا قطع) |
| `service` / `systemctl` | فقط ثبت فراخوانی |

هر سناریو اسکریپت واقعی را سرتاسر اجرا می‌کند و روی خروجی‌ها assert می‌نویسد: `config.yaml` (یک model group `claude-freeagents` + `router_settings` شامل `model_group_alias` مخفی)، `~/.omniroute/.env`، `settings.json` کلاد کد، پروفایل‌های Claude Desktop، `~/.free-ai-agents/live_test.sh`، `docker run` و `npm install -g omniroute`.

### فهرست ۲۳ سناریو

| تست | سناریو |
|---|---|
| T00 | ایستا: `bash -n`، shebang، `shellcheck -S warning` پاک، پرم ۷۵۵، عدم وجود `OmniRoute-OpenCode`/`LiteLLM.sh`/`OmniRoute.sh` |
| T01 | LiteLLM با هر ۹ کلید — ۱۱+ deployment در یک گروه `claude-freeagents`، alias مخفی، `trusted_proxy_ranges: []` + نصب `live_test.sh` |
| T02 | LiteLLM فقط با Groq |
| T03 | OmniRoute فقط (npm رسمی) — اتصال `freeagents-install`، کلید `freeagents-claude`، combo `claude-freeagents`/auto |
| T04 | هر دو گیت‌وی در یک اجرا — کلیدها و پراکسی یک‌بار |
| T05 | دستورات غیرتعاملی: `freeagents up/down/restart/status/doctor/credentials/logs` |
| T06 | سطح دستورات: هر دو گیت‌وی، نبود `omni up/down` و `litellm up/down` |
| T07 | منو: ورودی نامعتبر، `0` خروج تمیز |
| T08 | تعویض پروفایل: `active_gateway` |
| T09 | پراکسی ویندوز: ON (هر دو)، ماندگاری، سپس OFF |
| T10 | ورود دوبارهٔ کلیدها پراکسی را نگه می‌دارد |
| T11 | Update: دانلود از همین ریپو، کلیدها و پراکسی حفظ |
| T12 | Self-heal: کپی خراب مدیر دوباره دانلود می‌شود |
| T13 | Uninstall همه‌چیز را پاک می‌کند: کانتینرها، سرویس‌ها، پکیج npm، `~/.free-ai-agents/` (شامل `live_test.sh`)، پروفایل‌های Claude |
| T14 | نصب/حذف اسکریپتی: `install --keys-file` + `uninstall --yes` |
| T15 | بدون ویندوز (`FREEAGENTS_SKIP_WINDOWS=1`) |
| T16 | تأیید کلید: کلید ردشده (۴۰۱) گزارش و امکان ورود مجدد |
| T17 | نصب مجدد idempotent |
| T18 | شکست login داشبورد OmniRoute |
| T19 | سلامت رجیستری ارائه‌دهنده‌ها |
| T20 | مقاومت داکر: بکاپ `daemon.json`، retry pull |
| T21 | secret کوتاه OmniRoute بازتولید می‌شود |
| T22 | هاست بدون داکر: فقط-OmniRoute نباید به داکر دست بزند |

```bash
bash tests/run_all_tests.sh
```

---

## ۲️⃣ لایهٔ دوم — E2E واقعی با خودِ LiteLLM (PyPI)

**فایل:** [`e2e_litellm_real.sh`](e2e_litellm_real.sh)

LiteLLM واقعی از PyPI بوت می‌شود و روی API زنده assert می‌شود:

- `/health/liveliness` → ۲۰۰
- `GET /v1/models` → دقیقاً `["claude-freeagents"]` (alias مخفی hidden)
- مدل ناشناس → ۴۰۰
- `claude-freeagents` و `claude-sonnet-4-5` و `/v1/messages` روت می‌شوند (با کلید جعلی upstream ۵۰۰ ولی روتینگ درست)

```bash
bash tests/e2e_litellm_real.sh
```

---

## ۳️⃣ لایهٔ سوم — E2E واقعی با Docker + npm (روی سیستم شما)

**فایل:** [`e2e_real_docker.sh`](e2e_real_docker.sh)

روی WSL2 واقعی با اینترنت:

- LiteLLM: `docker ps`، `restart-policy=unless-stopped`، `DATABASE_URL`، health، login پنل، `/v1/models == ["claude-freeagents"]`
- OmniRoute: `/healthz`، `.env` ۶۰۰، login داشبورد، combo `claude-freeagents`
- یکپارچگی: `freeagents status/credentials/doctor`، `live_test.sh` در `~/.free-ai-agents/`، پروفایل‌های Claude Desktop
- حذف کامل: `~/.litellm`، `~/.omniroute`، `~/.free-ai-agents/` (شامل `live_test.sh`)، سرویس‌ها و پکیج npm

```bash
bash tests/e2e_real_docker.sh
```

---

## ۴️⃣ لایهٔ چهارم — تست زندهٔ upstream با کلید واقعی (هر دو گیت‌وی)

**فایل‌های مرتبط:**
- سورس در ریپو: [`freeagents/live_test.sh`](../freeagents/live_test.sh) — پوشهٔ مرتبط با freeagents
- نصب‌شده در سیستم: `~/.free-ai-agents/live_test.sh` (۷۵۵) — با `freeagents uninstall` خودکار حذف می‌شود

این تست فقط وقتی اجرا می‌شود که کلید واقعی داشته باشی؛ در سندباکس و بدون کلید، خودکار **SKIP** می‌شود.

**چه چیزی را با کلید واقعی اعتبار سنجی می‌کند؟**

| گیت‌وی | لودبالانسر؟ | چه چیزی تست می‌شود |
|---|---|---|
| **LiteLLM** | ✅ بله — `router_settings`: `simple-shuffle` + `num_retries=3` + `allowed_fails=3` + `cooldown_time=30` — همهٔ deploymentهای `claude-freeagents` پشت یک گروه، اگر یکی fail بده بعدی خودکار امتحان می‌شود | health ۲۰۰، `/v1/models` دقیقاً `claude-freeagents`، تعداد deploymentها در `config.yaml`، برای هر provider که کلید دادی: تست مستقیم کلید + `POST /v1/chat/completions` واقعی از مسیر گیت‌وی (باید ۲۰۰ بده)، alias مخفی `claude-sonnet-4-5` روت می‌شود، `/v1/messages` روت می‌شود، `freeagents doctor litellm` OK |
| **OmniRoute** | ✅ بله — combo `claude-freeagents` با `strategy: auto` — OmniRoute خودش بین مدل‌های combo لودبالانس و failover می‌کند | `/healthz` ۲۰۰، `.env` secretها طول درست، login داشبورد با کوکی، `/api/providers` ≥۱، `/api/combos` شامل `claude-freeagents` و لیست مدل‌های داخل combo، برای هر provider: `POST /api/providers/{id}/test` + `POST /v1/messages` و `POST /v1/chat/completions` واقعی از مسیر OmniRoute (باید ۲۰۰)، `freeagents doctor omniroute` OK |

**چجوری باهاش کار کنم؟**

```bash
# 1) نصب با کلید واقعی (اگر قبلاً نصب کردی، لازم نیست دوباره):
bash setup.sh   # منو 1 -> 3 (Both) -> کلیدهای واقعی رو بده

# 2) بعد از نصب، فایل تست زنده خودکار اینجاست:
ls -l ~/.free-ai-agents/live_test.sh
# -rwxr-xr-x ... /home/<user>/.free-ai-agents/live_test.sh

# 3) اجرا با کلیدهای ذخیره شده (از provider_keys.env می‌خونه):
~/.free-ai-agents/live_test.sh
# یا از ریپو:
bash freeagents/live_test.sh

# فقط یک موتور:
E2E_ENGINE=litellm ~/.free-ai-agents/live_test.sh
E2E_ENGINE=omniroute ~/.free-ai-agents/live_test.sh

# با کلیدهای صریح (برای CI):
GROQ_API_KEY=gsk_... GEMINI_API_KEY=AIza... bash freeagents/live_test.sh

# لاگ:
cat ~/.free-ai-agents/logs/live_test.log
```

خروجی موفق:
```
[LIVE-E2E] ok  - GET /health/liveliness -> 200
[LIVE-E2E] ok  - GET /v1/models -> exactly ['claude-freeagents']
[LIVE-E2E] ok  - POST /v1/chat/completions claude-freeagents -> 200 (real upstream works!)
[LIVE-E2E] ok  - combo 'claude-freeagents' exists
[LIVE-E2E] ok  - POST /v1/messages claude-freeagents via OmniRoute -> 200
[LIVE-E2E] LIVE RESULT: PASS
```

- ۴۰۱/۴۰۳ = کلید اشتباه یا geo-block (پراکسی ویندوز رو روشن کن: منو ۹ → ۱ → `freeagents restart`)
- ۴۲۹ = سهمیه تموم شده (LiteLLM خودش بعدی رو امتحان می‌کنه، ولی تست مستقیم ۴۲۹ می‌ده)
- با `freeagents uninstall` یا `freeagents uninstall --yes`، کل پوشهٔ `~/.free-ai-agents/` شامل `live_test.sh` پاک می‌شود.

---

## 📁 ساختار پوشه‌ها

```
FreeAI-Agents/
├── setup.sh                     ← نصاب واحد هر دو گیت‌وی
├── freeagents/
│   └── live_test.sh             ← تست زندهٔ upstream (سورس) — موقع نصب به ~/.free-ai-agents/live_test.sh کپی می‌شود
├── tests/
│   ├── run_all_tests.sh         ← سوئیت ۲۳ سناریویی آفلاین (T00–T22)
│   ├── e2e_litellm_real.sh      ← E2E با LiteLLM واقعی (PyPI/venv)
│   ├── e2e_real_docker.sh       ← E2E با Docker+npm واقعی (WSL2 شما)
│   ├── helpers/
│   │   ├── mock_omniroute.py    ← mock کامل REST OmniRoute
│   │   └── stubbin/             ← بدل‌های ایزوله
│   └── results/
│       └── summary.txt          ← فقط همین فایل کامیت می‌شود
└── docs/                        ← مستندات فارسی
```

`.gitignore` لاگ‌های `results/*.log` و بدل‌های تولیدشدهٔ `stubbin/docker` و `stubbin/omniroute` را نادیده می‌گیرد.

</div>
