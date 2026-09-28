<div align="tight" dir="rtl">

# 🗑️ راهنمای حذف کامل (Uninstall)

---

## ۱. حذف از طریق دستور مدیریت (سریع‌ترین راه)

اگر نصب کامل است، فقط داخل WSL بزنید:

```bash
freeagents uninstall
```

(برای اجرای بدون سؤال: `freeagents uninstall --yes`)

## ۲. حذف از طریق منوی نصاب

اسکریپت را اجرا کنید و گزینهٔ `2` را بزنید:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/im-JvD/FreeAI-Agents/main/setup.sh)
```

```
   Enter your choice [1/2/q]: 2
```

خروجی موفق:

```
[INFO] === FULL UNINSTALL: starting ===
[INFO] Stopping and removing container 'litellm'...
[ OK ] Container removed.
[ OK ] Removed LiteLLM config folder: /home/<user>/.litellm
[ OK ] Removed Claude Code settings: /mnt/c/Users/<Name>/.claude/settings.json

=================================================================
  UNINSTALL COMPLETED SUCCESSFULLY!
=================================================================
```

این کار **قابل تکرار** است؛ اگر چیزی برای حذف وجود نداشته باشد، به‌جای خطا فقط هشدار می‌دهد و با کد خروج ۰ تمام می‌شود.

---

## ۳. چه چیزی حذف می‌شود و چه چیزی می‌ماند؟

| مورد | وضعیت | مسیر |
|---|---|---|
| کانتینر `litellm` | ✅ حذف (stop + rm) | — |
| پوشهٔ کانفیگ لینوکس | ✅ حذف | `~/.litellm/` (شامل `config.yaml` و `master_key.txt`) |
| کانفیگ Claude Code ویندوز | ✅ حذف | `%USERPROFILE%\.claude\settings.json` |
| تنظیمات پروکسی ویندوز | ✅ حذف | `~/.litellm/windows_proxy.txt` (داخل پوشهٔ `~/.litellm` حذف می‌شود) |
| اپ Claude Desktop (پالیسی گیت‌وی) | ✅ حذف/بازگردانی | مقادیر `HKCU\SOFTWARE\Policies\Claude` پاک و جدیدترین بکاپ `claude_desktop_policy.reg.bak.*` import می‌شود |
| سرویس systemd / boot command | ✅ حذف | `litellm.service` یا خط boot در `/etc/wsl.conf` |
| اسکریپت استارت بوت | ✅ حذف | `/usr/local/bin/litellm-boot.sh` |
| دستور مدیریت `litellm` | ✅ حذف | `/usr/local/bin/litellm` |
| خودِ Docker | ❌ حفظ | — |
| میرورهای ایرانی | ❌ حفظ | `/etc/docker/daemon.json` |
| ایمیج LiteLLM (دانلودشده) | ❌ حفظ | برای نصب مجدد سریع |
| پوشهٔ `.claude` (اگر بکاپ `settings.json.bak.*` داشته باشد) | ⛳ بازگردانی | جدیدترین بکاپ به‌جای `settings.json` برمی‌گردد |

---

## ۴. حذف دستی (اگر اسکریپت در دسترس نیست)

داخل WSL:

```bash
sudo docker stop litellm 2>/dev/null
sudo docker rm litellm 2>/dev/null
rm -rf ~/.litellm
sudo rm -f /usr/local/bin/freeagents /usr/local/bin/litellm-boot.sh
sudo rm -f /etc/systemd/system/litellm.service
sudo sed -i '\|^command = /usr/local/bin/litellm-boot.sh$|d' /etc/wsl.conf 2>/dev/null
```

در ویندوز (PowerShell یا Run):

```powershell
del "$env:USERPROFILE\.claude\settings.json"
```

---

## ۵. حذف کامل‌تر (اختیاری)

اگر می‌خواهید اثری از نصب باقی نماند:

```bash
# حذف ایمیج (حدود ۲ گیگابایت آزاد می‌شود)
sudo docker rmi ghcr.io/berriai/litellm:main-latest

# حذف میرورهای ایرانی (پوشهٔ /etc/docker را برمی‌گرداند به حالت قبل)
sudo rm -f /etc/docker/daemon.json
sudo service docker restart

# غیرفعال کردن استارت خودکار (اگر systemd دارید)
sudo systemctl disable docker.service
```

و در نهایت اگر خودِ داکر هم لازم ندارید:

```bash
sudo apt-get remove --purge -y docker.io
sudo apt-get autoremove -y
```

---

## ۶. نصب مجدد

بعد از Uninstall، برای نصب مجدد کافی است دوباره گزینهٔ `1` را اجرا کنید. چون ایمیج و داکر حفظ شده‌اند، نصب مجدد فقط چند ثانیه طول می‌کشد (بدون دانلود مجدد).

</div>
