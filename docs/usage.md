<div align="tight" dir="rtl">

# 🎮 راهنمای استفاده در Claude Code و Claude Desktop (ویندوز)

این سند یعنی: «نصب تمام شد، حالا از کجا شروع کنم؟» — از باز کردن ترمینال تا اولین کد تولیدشده. هر دو گیت‌وی (LiteLLM و OmniRoute) با **یک نام مدل** کار می‌کنند: `claude-freeagents`.

---

## ۰. تصویر کلی: چه چیزی کجاست؟

```
Claude Code / Desktop (ویندوز)
        %USERPROFILE%\.claude\settings.json        ─┐
        %LOCALAPPDATA%\Claude-3p\configLibrary\...  ─┤
                                                     ▼
                              گیت‌وی فعال روی 127.0.0.1
             ┌───────────────────────────┴───────────────────────────┐
             ▼                                                       ▼
  LiteLLM  (پورت 4000، داکر)                        OmniRoute (پورت 20128، npm)
  یک مدل: claude-freeagents                                  یک مدل: claude-freeagents
  router: retry/cooldown بین کلیدها                          combo با استراتژی auto
             └───────────────────────────┬───────────────────────────┘
                                         ▼
                     پراکسی ویندوز (اختیاری: Clash/v2rayN/Hiddify)
                                         ▼
                 Groq / OpenRouter / Google / Cerebras / Mistral / …
```

- کلیدها و آدرس پروکسی **از قبل** در `settings.json` ثبت شده‌اند — Claude هیچ کلیدی از شما نمی‌پرسد.
- شما فقط دو کار می‌کنید: **یک بار Claude را نصب می‌کنید، بعد هر بار فقط `claude` را اجرا می‌کنید.**
- هر دو گیت‌وی یکسان هستند؛ پیش‌فرض بعد از نصب حالت «هر دو»، گیت‌وی فعال **LiteLLM** است.

---

## ۱. نصب Claude Code در ویندوز (فقط یک بار)

در **PowerShell**:

```powershell
irm https://claude.ai/install.ps1 | iex
```

یا اگر Node.js دارید:

```powershell
npm install -g @anthropic-ai/claude-code
```

بعد از نصب، **ترمینال را ببندید و یک ترمینال جدید باز کنید** و نسخه را چک کنید:

```powershell
claude --version
```

> 💡 برای دیدن فهرست مدل‌های گیت‌وی در پیکر `/model` به نسخهٔ **v2.1.129 به بعد** نیاز دارید (قابلیت Gateway Model Discovery). اگر قدیمی‌تر بود: `claude update` یا دوباره نصب‌کنندهٔ PowerShell را اجرا کنید.

---

## ۲. بررسی سلامت پشته (در WSL)

قبل از اولین اجرا، مطمئن شوید گیت‌وی‌ها روشن‌اند:

```bash
freeagents status        # وضعیت هر دو گیت‌وی: health، پورت و فایل‌ها
freeagents doctor        # تشخیص کامل: اتصال به هر ارائه‌دهنده + تست واقعی درخواست
```

- اگر خاموش بودند: `freeagents up`
- بعد از ری‌استارت ویندوز، سرویس‌های `litellm.service` و `omniroute.service` خودکار بالا می‌آیند (چند ثانیه صبر کنید).

---

## ۳. اجرا در پوشهٔ پروژه

در ویندوز یک ترمینال جدید (PowerShell یا CMD) باز کنید:

```powershell
cd C:\projects\my-app
claude
```

**اولین اجرا:**
- سؤال «Do you trust the files in this folder?» → بله (فقط یک بار برای هر پوشه).
- انتخاب تم (دلخواه).
- ⚠️ Claude **نباید** صفحهٔ Login/اکانت آنتروپیک نشان دهد — توکن از `settings.json` می‌آید. اگر لاگین خواست، بخش رفع اشکال پایین را ببینید.

---

## ۴. انتخاب مدل با `/model`

داخل Claude تایپ کنید:

```
/model
```

مدل گیت‌وی با برچسب **«From gateway»** در فهرست ظاهر می‌شود:

| مدل | نمایش در کلاد | مناسب برای |
|---|---|---|
| `claude-freeagents` | `FreeAgents/LiteLLM` | همه‌کاره — LiteLLM بین همهٔ کلیدهایت retry/cooldown می‌کند |
| `claude-freeagents` | `FreeAgents/Omni` | همان مدل از مسیر OmniRoute (وقتی گیت‌وی فعال Omni باشد) |

- فقط **همین یک نام** را انتخاب کنید؛ LiteLLM (یا combo ام OmniRoute) خودش تصمیم می‌گیرد درخواست به کدام ارائه‌دهنده برود.
- اگر گیت‌وی فعال را عوض کردید (منو → `9` → Switch the ACTIVE gateway)، مدل همان `claude-freeagents` می‌ماند و فقط برچسب (`FreeAgents/…`) و پورت عوض می‌شود.

---

## ۵. استفاده در اپ Claude Desktop (نسخهٔ ویندوز)

> ⚠️ **تفاوت مهم:** اپ **Claude Desktop** (پنجرهٔ چت claude.ai) با **Claude Code** (CLI) فرق دارد. چت معمولی اپ مستقیم به سرور Anthropic وصل می‌شود و به اکانت claude.ai نیاز دارد — آن بخش قابل تغییر نیست. اما بخش ایجنتِ اپ (**Cowork**) و نشست‌های Code داخل اپ به گیت‌وی شما وصل می‌شوند.

### ✅ اتصال خودکار (پیش‌فرض)

نصاب برای هر دو گیت‌وی پروفایل می‌سازد، در `%LOCALAPPDATA%\Claude-3p\configLibrary\<uuid>.json`:

| گیت‌وی | شناسهٔ پروفایل |
|---|---|
| LiteLLM (برچسب `FreeAgents/LiteLLM`) | `…‎a119e` |
| OmniRoute (برچسب `FreeAgents/Omni`) | `…‎a110e` |

`_meta.json` هم به‌روز می‌شود و گیت‌وی فعال با `appliedId` علامت می‌خورد؛ `claude_desktop_config.json` هم نوشته می‌شود. بعد از نصب فقط اپ را **کامل ببندید و باز کنید**.

تعویض گیت‌وی فعال: منو → گزینهٔ `9` (Config Manager) → «Switch the ACTIVE gateway». سپس اپ‌های Claude را ری‌استارت کنید.

### مراحل اتصال دستی (فقط اگر خودکار کار نکرد)

1. اپ Desktop را باز کنید: منوی **Help > Troubleshooting > Enable Developer Mode**
2. از منوی **Developer** گزینهٔ **Configure Third-Party Inference…** را باز کنید
3. در بخش **Connection** این مقادیر را بدهید (مقادیر گیت‌وی فعال):

   | فیلد | مقدار |
   |---|---|
   | Inference provider | **Gateway** |
   | Gateway base URL | LiteLLM: `http://127.0.0.1:4000` — OmniRoute: `http://127.0.0.1:20128` (بدون `/v1`) |
   | Credential kind | **Static API key** |
   | Gateway API key | در WSL: `freeagents credentials` (Master Key یا کلید OmniRoute) |
   | Gateway auth scheme | **Bearer** |

4. **Apply** بزنید و اپ را کاملاً ببندید و دوباره باز کنید
5. داخل گفتگوی **Cowork**، پیکر مدل را باز کنید — `FreeAgents/LiteLLM` (یا `FreeAgents/Omni`) آنجاست.

### چرا فقط یک مدل می‌بینم؟

چون طراحی جدید **یک مدل واحد برای هر گیت‌وی** است: `claude-freeagents`. پشت این یک نام، همهٔ ارائه‌دهنده‌هایی که کلیدشان را داده‌اید قرار دارند و موتور خودش بین آن‌ها سوئیچ/retry می‌کند. برای هم‌خوانی با کاتالوگ اپ دسکتاپ، یک alias مخفی (`claude-sonnet-4-5`) هم به همان مدل وصل است (در `/v1/models` نمایش داده نمی‌شود).

### نکته‌ها و رفع اشکال اپ Desktop

- اپ هنگام باز شدن، فهرست مدل‌ها را از گیت‌وی می‌گیرد (`GET /v1/models`) — پس WSL و گیت‌وی باید روشن باشند.
- خطای `401`؟ توکن را با `freeagents credentials` چک کنید و با فیلد API key یکی کنید.
- کلاینت اپ روی همان ویندوز است، پس `127.0.0.1:4000` / `127.0.0.1:20128` مستقیم کار می‌کند (WSL2 پورت را با ویندوز به اشتراک می‌گذارد).
- نسخهٔ اپ باید جدید باشد (پشتیبانی Gateway در نسخه‌های ۲۰۲۶ به بعد) — از claude.ai/download به‌روز نگه دارید.

---

## ۶. استفادهٔ روزمره

فقط فارسی/انگلیسی حرف بزنید؛ Claude خودش فایل می‌خواند، کد می‌نویسد و دستور اجرا می‌کند:

| کار | چطور |
|---|---|
| شروع یک پروژه | بگویید: «یک REST API با Express بساز» — فایل‌ها را می‌سازد |
| ویرایش کد موجود | «تابع X در src/app.js را bug-fix کن» — خودش می‌خواند و ویرایش می‌کند |
| قوانین پروژه را یادش بدهیم | یک بار `/init` بزنید → فایل `CLAUDE.md` می‌سازد (سبک کد، دستورات build و…) |
| حالت برنامه‌ریزی | `Shift+Tab` (قبل از اجرای کارهای بزرگ، اول نقشه می‌کشد) |
| قطع وسط کار | `Esc` |
| شروع گفتگوی تازه | `/clear` |
| خروج | `exit` یا `Ctrl+C` دو بار |

---

## ۷. داشبوردها و مدیریت (اختیاری)

| کار | دستور |
|---|---|
| وضعیت هر دو گیت‌وی | `freeagents status` |
| تست عمیق (ارائه‌دهنده‌ها + درخواست واقعی) | `freeagents doctor` |
| لاگ زنده | `freeagents logs litellm` یا `freeagents logs omniroute` |
| اطلاعات ورود همهٔ پنل‌ها | `freeagents credentials` |

پنل LiteLLM: `http://127.0.0.1:4000/ui` (یوزر `admin`، رمز = Master Key) — از Logs همان‌جا می‌بینید هر درخواست به کدام ارائه‌دهنده رفته است.

داشبورد OmniRoute: `http://127.0.0.1:20128` (رمز در `~/.omniroute/.env`، مقدار `INITIAL_PASSWORD`) — اتصال‌ها، کلیدها و combo `claude-freeagents` اینجا دیده می‌شوند.

---

## ۸. رفع اشکال سریع

| علامت | علت | راه حل |
|---|---|---|
| `ECONNREFUSED` / `fetch failed` هنگام چت | گیت‌وی داخل WSL خاموش است | در WSL: `freeagents up` |
| صفحهٔ Login آنتروپیک موقع اولین اجرا | متغیر قدیمی `ANTHROPIC_API_KEY` در ویندوز ست شده | در Environment Variables ویندوز پاکش کنید؛ ترمینال را عوض کنید |
| مدل «From gateway» در `/model` نیست | نسخهٔ Claude قدیمی است | `claude update` → مطمئن شوید v2.1.129+ |
| خطای `401` هنگام چت | توکن تغییر کرده ولی `settings.json` قدیمی است | نصاب را دوباره اجرا کنید یا `freeagents credentials` و مقداردهی دستی |
| فقط مدل‌های Google/Cerebras خطای `403` می‌دهند | پراکسی ویندوز (v2rayN/Clash) خاموش یا Allow LAN خاموش | برنامهٔ پراکسی را روشن کنید؛ در WSL: `freeagents doctor` |
| گیت‌وی فعال را عوض کردم ولی کلاد همان قبلی را می‌زند | اپ‌های Claude ری‌استارت نشده‌اند | همهٔ پنجره‌های Claude را ببندید و باز کنید |
| OmniRoute بالا نمی‌آید | secretهای کوتاه در `~/.omniroute/.env` | `freeagents doctor omniroute` — حداقل‌ها: JWT≥۳۲، API_KEY_SECRET≥۱۶، رمز≥۸ |

راهنمای کامل‌تر: [troubleshooting.md](troubleshooting.md)

---

## ۹. سؤالات پرتکرار

**کدام گیت‌وی بهتر است؟** هر دو یک مدل می‌دهند و می‌توانید هر دو را هم‌زمان داشته باشید. LiteLLM (پیش‌فرض) برای retry/cooldown بین کلیدها قوی‌تر است؛ OmniRoute یک داشبورد کامل مدیریت اتصال/کلید دارد و بدون داکر نصب می‌شود.

**هزینه چقدر است؟** مدل‌های Groq و OpenRouter و Gemini و Cerebras رایگان‌اند (سقف مصرف در دقیقه دارند؛ اگر `429` گرفتید موتور خودش deployment بعدی را امتحان می‌کند). Mistral هم پلن رایگان دارد.

**هر بار ویندوز را ری‌استارت کردم چه کنم؟** هیچی. سرویس‌ها خودشان بالا می‌آیند. اگر Claude اتصال نداد: یک ترمینال WSL باز کنید و `freeagents status` را چک کنید.

**چند پروژهٔ همزمان؟** `settings.json` سراسری است — در هر پوشه‌ای که `claude` اجرا کنید به همان گیت‌وی فعال وصل می‌شود.

**تغییر پورت، اضافه‌کردن مدل، افزودن ارائه‌دهنده؟** [configuration.md](configuration.md)

</div>
