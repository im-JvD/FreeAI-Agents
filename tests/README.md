<div align="tight" dir="rtl">

# 🧪 مستندات تست‌ها

کیفیت اسکریپت `setup.sh` با **سه لایهٔ تست** تضمین شده است. همهٔ تست‌ها قابل اجرای مجدد هستند؛ لاگ‌های پرحجم در `.gitignore` هستند و فقط `results/summary.txt` در گیت ثبت می‌شود.

---

## 📊 نتیجهٔ آخرین اجرا در محیط ایزوله (سندباکس)

| لایهٔ تست | نتیجه |
|---|---|
| سوئیت آفلاین (۲۳ سناریو، T00–T22) | ✅ ۲۳ پاس / ۰ شکست / ۰ اسکیپ |
| E2E واقعی با خودِ LiteLLM v1.103.0 از PyPI (کلیدهای جعلی، تست روتینگ) | ✅ پاس |
| E2E واقعی با Docker + npm (روی WSL2 واقعی) | ⏭️ فقط روی WSL2 واقعی اجرا می‌شود — در سندباکس SKIP می‌شود |

جزئیات: [`results/summary.txt`](results/summary.txt) (لاگ‌های تکی `T*.log` و `E2E_*.log` موقع اجرا در `results/` ساخته می‌شوند ولی ignore هستند).

---

## ۱️⃣ لایهٔ اول — سوئیت آفلاین (بدون شبکه، بدون داکر)

**فایل:** [`run_all_tests.sh`](run_all_tests.sh) — حدود ۸۰ ثانیه

منطق کامل اسکریپت را با «بدل‌های قطعی» (stub) تست می‌کند:

| بدل | کار |
|---|---|
| `docker` (+ `docker.installer`) | شبیه‌س وضعیت‌مند: ثبت فراخوانی‌ها، دفتر کانتینرها (`containers.txt`)، `docker inspect`، `pull` با شکست قابل تنظیم |
| `npm` / `node` | نصب `omniroute` با کپی `omniroute.installer`، ثبت `npm-calls.log`، fallback رجیستری |
| `omniroute` (+ `omniroute.installer`) | سرور واقعی: `mock_omniroute.py` که REST رسمی OmniRoute را پیاده می‌کند (login با کوکی `auth_token`، `providers`، `keys`، `combos`، `settings/proxy`، کاتالوگ زنده) |
| `apt-get` | موقع «نصب docker.io» بدل داکر را نصب می‌کند |
| `sudo` | بدون ارتقای دسترسی؛ `/etc/docker` و `/usr/local/bin` و `/etc/systemd` را به ریشهٔ مجازی (`FAKE_ROOT`) منتقل می‌کند |
| `powershell.exe` | پروفایل ویندوزی با **فاصله در نام کاربری** (`Test User`) برمی‌گرداند |
| `curl` | کد سلامت قابل تنظیم (۲۰۰ یا قطع)، ثبت فراخوانی‌ها |
| `service` / `systemctl` | فقط ثبت فراخوانی |

هر سناریو اسکریپت واقعی را سرتاسر اجرا می‌کند و روی خروجی‌ها assert می‌نویسد: کد خروج، محتوای `config.yaml` (یک model group `claude-freeagents` + `router_settings` شامل `model_group_alias` مخفی)، `~/.omniroute/.env` (سه secret ≥ حداقل + `REQUIRE_API_KEY=true`)، `settings.json` کلاد کد (base URL بدون `/v1` + توکن = Master Key یا کلید OmniRoute)، پروفایل‌های Claude Desktop (`…a119e` و `…a110e` + `_meta.json`/`appliedId`)، آرگومان‌های `docker run` و `npm install -g omniroute`، میرورهای `daemon.json`، state در `~/.free-ai-agents/` و رفتار `uninstall`.

### فهرست ۲۳ سناریو

| تست | سناریو |
|---|---|
| T00 | ایستا: `bash -n`، shebang، `shellcheck -S warning` پاک، پرم ۷۵۵، عدم وجود `OmniRoute-OpenCode`/`LiteLLM.sh`/`OmniRoute.sh`، لینک آپدیت فقط از همین ریپو |
| T01 | LiteLLM با هر ۹ کلید (۵ اصلی + ۴ اختیاری) — ۱۱+ deployment در یک گروه `claude-freeagents`، alias مخفی، `trusted_proxy_ranges: []` |
| T02 | LiteLLM فقط با Groq — فقط deploymentهای Groq |
| T03 | OmniRoute فقط (npm رسمی) — اتصال `freeagents-install`، کلید `freeagents-claude`، combo `claude-freeagents`/auto |
| T04 | هر دو گیت‌وی در یک اجرا — کلیدها و پراکسی یک‌بار پرسیده می‌شوند، state هر دو ساخته می‌شود |
| T05 | دستورات غیرتعاملی: `freeagents up/down/restart/status/doctor/credentials/logs` |
| T06 | سطح دستورات: هر دو گیت‌وی، نبود دستورهای تکی `omni up/down` و `litellm up/down`، وجود `freeagents help` |
| T07 | منو: ورودی نامعتبر هندل می‌شود، `0` تمیز خارج می‌شود، `freeagents` بدون آرگومان منو را باز می‌کند |
| T08 | تعویض پروفایل: گیت‌وی فعال (`active_gateway`) تصمیم می‌گیرد Claude به کدام پورت وصل شود |
| T09 | پراکسی ویندوز: ON (هر دو موتور)، ماندگاری در نصب دوباره، سپس OFF — تزریق `HTTP_PROXY` به کانتینر و `.env` |
| T10 | ورود دوبارهٔ کلیدها پراکسی را نگه می‌دارد و برای هر دو موتور اعمال می‌کند |
| T11 | Update: دانلود مجدد از همین ریپو (`im-JvD/FreeAI-Agents`)، کلیدها و پراکسی حفظ می‌شوند |
| T12 | Self-heal: کپی خراب مدیر (`~/.free-ai-agents/setup.sh`) توسط CLI دوباره دانلود می‌شود |
| T13 | Uninstall همه‌چیز را پاک می‌کند: کانتینرها، سرویس‌ها، پکیج npm، داده‌ها، پروفایل‌های Claude، `freeagents` |
| T14 | نصب/حذف اسکریپتی: `freeagents install --keys-file` + `freeagents uninstall --yes` |
| T15 | بدون ویندوز (`FREEAGENTS_SKIP_WINDOWS=1`): نصب موفق + هشدار، بدون فایل ویندوزی |
| T16 | تأیید کلید: کلید ردشده (۴۰۱) گزارش و امکان ورود مجدد دارد |
| T17 | نصب مجدد idempotent است: secretها، کلیدها و combo ثابت می‌مانند |
| T18 | شکست login داشبورد OmniRoute (`--reject-login`): نصب ادامه می‌یابد و توضیح دستی داده می‌شود |
| T19 | سلامت رجیستری ارائه‌دهنده‌ها (خواندن مستقیم از اسکریپت): ۹ ارائه‌دهنده، `MODEL_ID=claude-freeagents` |
| T20 | مقاومت داکر: بکاپ `daemon.json`، retry pull و fallback به میرور `LITELLM_GHCR_MIRROR` |
| T21 | OmniRoute با secret کوتاه موجود: بازتولید می‌شود، fatal نیست |
| T22 | هاست بدون داکر: نصب فقط-OmniRoute نباید به داکر دست بزند |

### اجرا

```bash
bash tests/run_all_tests.sh
```

خروجی: `tests/results/summary.txt` + لاگ‌های موقت `tests/results/T*.log` (ignore هستند؛ فقط summary کامیت می‌شود). نیازها: `bash`، `python3`، `sudo -n` (برای ساخت دو پوشهٔ فیک زیر `/mnt/c/Users/Test User` و `Ali Rezaei` که موقع خروج پاک می‌شوند).

---

## ۲️⃣ لایهٔ دوم — E2E واقعی با خودِ LiteLLM (PyPI)

**فایل:** [`e2e_litellm_real.sh`](e2e_litellm_real.sh)

LiteLLM واقعی از PyPI در یک venv نصب و با دقیقاً همان `config.yaml` و Master Key که اسکریپت تولید کرده بوت می‌شود (`litellm --config ... --port ...`). سپس روی API زنده assert می‌شود:

- `/health/liveliness` → `200`
- `GET /v1/models` با Master Key → دقیقاً `["claude-freeagents"]` (alias مخفی `claude-sonnet-4-5` نمایش داده نمی‌شود)
- `GET /v1/models` بدون کلید → رد می‌شود (۵۰۰/۴۰۱)
- `POST /v1/chat/completions` با مدل ناشناس → `400`
- `POST /v1/chat/completions` با `claude-freeagents` → روت می‌شود (به‌خاطر کلیدهای جعلی، upstream ۵۰۰ می‌دهد ولی روتینگ درست است)
- `claude-sonnet-4-5` هم روت می‌شود (alias فعال است)
- `POST /v1/messages` (مسیر Anthropic که Claude Code استفاده می‌کند) هم روت می‌شود
- هیچ `router_settings` نامعتبری وجود ندارد

```bash
bash tests/e2e_litellm_real.sh
# اجرای سریع‌تر با venv آماده:
LITELLM_E2E_VENV=/tmp/litellm-e2e-venv SKIP_INSTALL=1 bash tests/e2e_litellm_real.sh
```

نیازمند دسترسی به PyPI است؛ در نبودش SKIP می‌شود. لاگ: `tests/results/E2E_litellm_real.log` (ignore).

---

## ۳️⃣ لایهٔ سوم — E2E واقعی با Docker + npm (روی سیستم شما)

**فایل:** [`e2e_real_docker.sh`](e2e_real_docker.sh)

تست تمام‌وکمال دنیای واقعی که روی **WSL2 واقعی با اینترنت** اجرا می‌شود:

- نصب کامل از منوی واقعی (قابل انتخاب: `both`/`litellm`/`omniroute` با `E2E_ENGINE`)
- LiteLLM: `docker ps`، `restart-policy=unless-stopped`، `UI_USERNAME=admin`، `DATABASE_URL`، کانتینر `litellm-db`، health، login پنل (بدون خطای «Not connected to DB!»)، `/v1/models == ["claude-freeagents"]`، روتینگ `claude-sonnet-4-5` و `/v1/messages`
- OmniRoute: `/healthz`، `.env` (۶۰۰) با `JWT_SECRET`/`API_KEY_SECRET`/`INITIAL_PASSWORD`/`REQUIRE_API_KEY`، لانچر ۷۰۰، login داشبورد `/api/auth/login` با کوکی، combo `claude-freeagents` و اتصال provider
- یکپارچگی: `freeagents status/credentials/doctor`، `freeagents-boot.sh`، نبود دستورهای قدیمی `litellm`/`omni`، `settings.json` کلاد کد (`ANTHROPIC_MODEL=claude-freeagents` + base URL درست)، پروفایل‌های Claude Desktop (`…a119e`/`…a110e`)
- حذف کامل از منو: همهٔ کانتینرها، `~/.litellm`، `~/.omniroute`، `~/.free-ai-agents`، `freeagents`، سرویس‌ها و پکیج npm پاک می‌شوند

```bash
bash tests/e2e_real_docker.sh
# فقط LiteLLM:
E2E_ENGINE=litellm bash tests/e2e_real_docker.sh
# با کلیدهای واقعی (اختیاری):
export LITELLM_E2E_REAL_KEYS=1 LITELLM_E2E_GROQ="gsk_..." 
bash tests/e2e_real_docker.sh
```

پیش‌نیاز: WSL2 + Docker + Node + دسترسی به `ghcr.io` و `npmjs.org`؛ خارج از WSL یا بدون شبکه SKIP می‌شود.

---

## 📁 ساختار پوشهٔ tests

```
tests/
├── README.md               ← همین سند
├── run_all_tests.sh        ← سوئیت ۲۳ سناریویی آفلاین (T00–T22)
├── e2e_litellm_real.sh     ← E2E با LiteLLM واقعی (PyPI/venv)
├── e2e_real_docker.sh      ← E2E با Docker+npm واقعی (WSL2 شما)
├── helpers/
│   ├── mock_omniroute.py   ← mock کامل REST OmniRoute (login, providers, keys, combos)
│   └── stubbin/            ← بدل‌های ایزوله: sudo, apt-get, docker(.installer),
│                              npm, node, curl, powershell.exe, service, systemctl,
│                              omniroute(.installer)
└── results/
    └── summary.txt         ← فقط همین فایل کامیت می‌شود (لاگ‌ها ignore)
```

`.gitignore` لاگ‌های `results/*.log` و بدل‌های تولیدشدهٔ `stubbin/docker` و `stubbin/omniroute` را نادیده می‌گیرد — این دو فایل در هر تست از روی `*.installer` کپی می‌شوند.

</div>
