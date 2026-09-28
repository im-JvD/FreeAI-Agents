<div align="tight" dir="rtl">

# 🗑️ راهنمای حذف کامل (Uninstall)

حذف، **هر دو گیت‌وی** (LiteLLM و OmniRoute) را با هم پاک می‌کند و کاملاً قابل تکرار است.

---

## ۱. حذف از طریق دستور مدیریت (سریع‌ترین راه)

داخل WSL:

```bash
freeagents uninstall           # با یک تأیید
freeagents uninstall --yes     # بدون سؤال
```

## ۲. حذف از طریق منوی نصاب

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/im-JvD/FreeAI-Agents/main/setup.sh)
```

و گزینهٔ `6` را بزنید:

```
   6 - Remove ( full wipe, both gateways )
```

خروجی موفق چیزی شبیه این است:

```
[INFO] === FULL UNINSTALL ===
[ OK ] Stopped and removed container 'litellm'
[ OK ] Disabled and removed: /etc/systemd/system/omniroute.service
[ OK ] Removed OmniRoute npm package
[ OK ] Removed OmniRoute data folder: /home/<user>/.omniroute
[ OK ] Removed LiteLLM config folder: /home/<user>/.litellm
[ OK ] Restored the previous Claude Code settings
[ OK ] Removed the FreeAgents desktop profiles
[ OK ] Removed management CLI: /usr/local/bin/freeagents

=================================================================
  UNINSTALL COMPLETED SUCCESSFULLY!
=================================================================
```

اگر چیزی برای حذف وجود نداشته باشد، به‌جای خطا فقط هشدار می‌دهد و با کد خروج ۰ تمام می‌شود.

---

## ۳. چه چیزی حذف می‌شود و چه چیزی می‌ماند؟

| مورد | وضعیت | مسیر / توضیح |
|---|---|---|
| کانتینر `litellm` (+ کانتینر `litellm-db` و شبکهٔ آن) | ✅ حذف | `docker rm -f` |
| پوشهٔ کانفیگ LiteLLM | ✅ حذف | `~/.litellm/` (شامل `config.yaml`، `master_key.txt`، `pgdata/`) |
| سرویس systemd LiteLLM | ✅ حذف | `/etc/systemd/system/litellm.service` |
| سرویس systemd OmniRoute | ✅ حذف | `/etc/systemd/system/omniroute.service` |
| پکیج npm ام OmniRoute | ✅ حذف | `npm uninstall -g omniroute` (با `FREEAGENTS_KEEP_NPM=1` حفظ می‌شود) |
| دادهٔ OmniRoute | ✅ حذف | `~/.omniroute/` (`.env`، `storage.sqlite`) |
| لانچر و state نصاب | ✅ حذف | `~/.free-ai-agents/` (کلیدها، پراکسی، لاگ‌ها، کپی اسکریپت) |
| کانفیگ Claude Code ویندوز | ✅ حذف/بازگردانی | `%USERPROFILE%\.claude\settings.json` — جدیدترین بکاپ `settings.json.bak.*` برمی‌گردد |
| پروفایل‌های اپ Claude Desktop | ✅ حذف/بازگردانی | `%LOCALAPPDATA%\Claude-3p\configLibrary` (پروفایل‌های FreeAgents + اصلاح `_meta.json`) |
| سرویس/خط بوت | ✅ حذف | `litellm.service`/`omniroute.service` یا خط boot در `/etc/wsl.conf` |
| دستورات مدیریت | ✅ حذف | `/usr/local/bin/freeagents`، `freeagents-boot.sh` و باقی‌ماندهٔ `litellm`/`omni` قدیمی |
| خودِ Docker | ❌ حفظ | — |
| میرورهای ایرانی | ❌ حفظ | `/etc/docker/daemon.json` |
| ایمیج LiteLLM (دانلودشده) | ❌ حفظ | برای نصب مجدد سریع |

---

## ۴. حذف دستی (اگر اسکریپت در دسترس نیست)

داخل WSL:

```bash
# LiteLLM
sudo docker rm -f litellm litellm-db 2>/dev/null
sudo systemctl disable --now litellm.service 2>/dev/null
sudo rm -f /etc/systemd/system/litellm.service
rm -rf ~/.litellm

# OmniRoute
sudo systemctl disable --now omniroute.service 2>/dev/null
sudo rm -f /etc/systemd/system/omniroute.service
sudo npm uninstall -g omniroute
rm -rf ~/.omniroute

# نصاب
sudo sed -i '\|^command = /usr/local/bin/freeagents-boot.sh$|d' /etc/wsl.conf 2>/dev/null
sudo rm -f /usr/local/bin/freeagents /usr/local/bin/freeagents-boot.sh
rm -rf ~/.free-ai-agents
sudo systemctl daemon-reload 2>/dev/null
```

در ویندوز (PowerShell):

```powershell
del "$env:USERPROFILE\.claude\settings.json"
# پروفایل‌های دسکتاپ (اختیاری):
Remove-Item "$env:LOCALAPPDATA\Claude-3p\configLibrary\*" -Force
```

---

## ۵. حذف کامل‌تر (اختیاری)

اگر می‌خواهید اثری از نصب باقی نماند:

```bash
# حذف ایمیج (حدود ۲ گیگابایت آزاد می‌شود)
sudo docker rmi ghcr.io/berriai/litellm:main-latest

# حذف میرورهای ایرانی (daemon.json به حالت قبل برمی‌گردد)
sudo rm -f /etc/docker/daemon.json
sudo service docker restart

# غیرفعال کردن استارت خودکار داکر (اگر systemd دارید)
sudo systemctl disable docker.service
```

و اگر خودِ داکر هم لازم نیست (فقط اگر از OmniRoute استفاده نمی‌کنید):

```bash
sudo apt-get remove --purge -y docker.io
sudo apt-get autoremove -y
```

---

## ۶. نصب مجدد

بعد از Uninstall، برای نصب مجدد کافی است دوباره گزینهٔ `1` را اجرا کنید. داکر، ایمیج و پکیج npm (اگر حذفشان نکرده باشید) حفظ شده‌اند، پس نصب مجدد فقط چند ثانیه طول می‌کشد.

</div>
