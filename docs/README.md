<div align="tight" dir="rtl">

# 📚 مستندات Free AI Agents

این پوشه مرجع کامل مستندات فارسی پروژه است: یک اسکریپت واحد برای **دو گیت‌وی** (LiteLLM و OmniRoute) با **یک مدل مشترک** برای Claude.

---

## 📑 فهرست مستندات

| سند | محتوا |
|---|---|
| [installation.md](installation.md) | پیش‌نیازها، روش‌های اجرا، منو و انتخاب گیت‌وی، دریافت کلیدهای ۹ ارائه‌دهنده، پنل‌ها و راه‌اندازی Claude |
| [configuration.md](configuration.md) | نقشهٔ فایل‌ها، ساختار `config.yaml`، کلیدها و secretها، اجرای سرویس‌ها، `settings.json` کلاد کد، پروکسی، متغیرهای محیطی |
| [usage.md](usage.md) | **راهنمای استفاده**: نصب Claude Code، پیکر `/model`، اپ Claude Desktop، استفادهٔ روزمره و رفع اشکال سریع |
| [uninstall.md](uninstall.md) | حذف کامل: چه چیزی پاک می‌شود، چه چیزی عمداً حفظ می‌شود و روش‌های حذف دستی |
| [troubleshooting.md](troubleshooting.md) | عیب‌یابی: داکر/ghcr، npm/OmniRoute، PowerShell، خطای 401، بلاک منطقه‌ای (403)، پنل‌ها و… |

---

## 🔗 لینک‌های مرتبط

- [README اصلی پروژه](../README.md)
- [مستندات تست‌ها](../tests/README.md)

---

## 🗺️ نقشهٔ کلی معماری

```
┌─────────────────────────── Windows ────────────────────────────┐
│   Claude Code / Claude Desktop                                │
│      %USERPROFILE%\.claude\settings.json                       │
│      %LOCALAPPDATA%\Claude-3p\configLibrary\<uuid>.json        │
└─────┬───────────────────────────────┬──────────────────────────┘
      │ http://127.0.0.1:4000/v1      │ http://127.0.0.1:20128/v1
      │ (Bearer: Master Key)          │ (Bearer: OmniRoute client key)
┌─────▼───────────────────────────────▼──────────────────────────┐
│                        WSL2 Ubuntu                             │
│                                                                │
│  LiteLLM (Docker, --restart unless-stopped)                    │
│    ├── image: ghcr.io/berriai/litellm:main-latest              │
│    ├── config: ~/.litellm/config.yaml (فقط-خواندنی)            │
│    └── کلیدها: متغیرهای محیطی کانتینر                          │
│                                                                │
│  OmniRoute (npm رسمی، سرویس systemd / لانچر)                   │
│    ├── package: omniroute (Node ≥ 20)                          │
│    ├── env: ~/.omniroute/.env  (JWT/API-KEY/رمز)               │
│    └── data: ~/.omniroute/storage.sqlite                       │
│                                                                │
│  هر دو: یک مدل → claude-freeagents                             │
│         (برچسب‌ها: FreeAgents/LiteLLM و FreeAgents/Omni)        │
│         لودبالانسر: LiteLLM=simple-shuffle+retry/cooldown       │
│                     OmniRoute=combo strategy auto               │
│  /etc/docker/daemon.json ← میرورهای ایرانی (رفع 403)            │
│  ~/.free-ai-agents/live_test.sh ← تست زنده upstream             │
└────────────────────────────────────────────────────────────────┘
      │  پراکسی ویندوز (اختیاری: Clash / v2rayN / Hiddify)
      ▼
   Groq │ OpenRouter │ Google AI Studio │ Cerebras │ Mistral
        │ GitHub Models │ SambaNova │ NVIDIA NIM │ Together AI
```

</div>
