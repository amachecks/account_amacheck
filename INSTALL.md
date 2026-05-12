# AMACheck Addon — Installation Guide

## Requirements

- Odoo 18.0 or 19.0
- The `account` and `mail` modules (standard Odoo — installed by default)
- An active AMAChecks license code (purchase at amachecks.com)

---

## Step 1 — Install the Addon

### Option A: Automated installer (recommended)

The installer script does everything for you: detects your Odoo setup (Docker or systemd), detects your Odoo version, downloads the right branch, updates your config, and installs the module.

1. Download `install.sh` from the [latest release](https://github.com/amachecks/account_amacheck/releases/latest).
2. Run it on your Odoo server:

   ```bash
   sudo bash install.sh
   ```

3. Follow the prompts. The installer will ask you to confirm before making any changes.

**Options:**
```bash
sudo bash install.sh --update             # pull the latest code and upgrade the module
sudo bash install.sh --uninstall          # remove AMACheck from the database
sudo bash install.sh --instance odoo1     # skip the instance picker
sudo bash install.sh --branch 19.0        # force a specific Odoo version branch
sudo bash install.sh --no-install         # set up files only; you'll click Install in the UI
sudo bash install.sh --help               # show all options
```

When the installer finishes, skip ahead to **Step 2 — Configure AMACheck Settings**.

---

### Option B: Manual install

If the automated installer doesn't fit your setup, follow these steps. Use the branch that matches your Odoo version — **`18.0`** for Odoo 18, **`19.0`** for Odoo 19.

**1. Get the code**

```bash
cd /opt/odoo/addons
git clone -b 18.0 https://github.com/amachecks/account_amacheck.git account_amacheck
# (replace 18.0 with 19.0 if you're on Odoo 19)
```

Or download the ZIP from the [repo](https://github.com/amachecks/account_amacheck), switch to the matching branch, click **Code → Download ZIP**, then extract into your addons directory.

**2. Add to Odoo addons path**

Open your Odoo config file (usually `/etc/odoo/odoo.conf`) and confirm the addons directory is listed:

```ini
addons_path = /opt/odoo/addons
```

If you placed the addon in a different folder, add it:
```ini
addons_path = /opt/odoo/addons,/path/to/your/folder
```

**3. Restart Odoo**

```bash
sudo systemctl restart odoo
```

**4. Install the module**

1. Log into Odoo as an Administrator
2. Go to **Settings → Activate Developer Mode** (Settings → General Settings → scroll to bottom)
3. Go to **Apps**
4. Click **Update Apps List**
5. Search for **AMACheck**
6. Click **Install**

---

## Step 2 — Configure AMACheck Settings

1. Go to **Settings → AMACheck**
2. Enter your **License Code**
3. Click **Refresh Balance** — this loads your provider settings and eCheck balance
4. Save

---

## Step 3 — Configure Your Bank Journal

1. Go to **Accounting → Configuration → Journals**
2. Open your bank journal (e.g. "Bank")
3. Scroll to the **AMACheck Settings** section
4. Fill in the **Signer** field (name that will appear as the check signer)
5. If your provider assigns check numbers, set the **Next Check Number**
6. Save

---

## Step 4 — Send Your First Check

1. Go to **Accounting → Vendors → Payments**
2. Create or open an outbound vendor payment
3. Make sure the vendor has a complete address (Street, City, State, ZIP, Country)
4. Click **Send AMACheck**
5. The **AMACheck** section on the payment will show Status, Check ID, Check Number, and Sent On upon success

---

## Updating the Addon

**With the installer:**

```bash
sudo bash install.sh --update
```

This pulls the latest code on the branch you're already on (18.0 or 19.0), stops Odoo, runs the module upgrade, and starts Odoo back up — no manual clicks needed.

**Manually:**

```bash
cd /opt/odoo/addons/account_amacheck
git pull
sudo systemctl restart odoo
```

Then in Odoo:
- Go to **Apps → AMACheck → Upgrade**

---

## Uninstalling the Addon

**With the installer:**

```bash
sudo bash install.sh --uninstall
```

This stops Odoo, runs the module's uninstall hook (removes all AMACheck transaction records and configuration from the database), restarts Odoo, and asks whether to also delete the addon files from disk.

To skip the prompt, add one of:

```bash
sudo bash install.sh --uninstall --remove-files   # also delete the addon folder
sudo bash install.sh --uninstall --keep-files     # leave the addon folder on disk
```

**Manually:**

1. In Odoo, go to **Apps**, find **AMACheck**, click the ⋮ menu → **Uninstall**.
2. (Optional) Delete the addon folder: `rm -rf /opt/odoo/addons/account_amacheck`
3. Restart Odoo: `sudo systemctl restart odoo`

> **Warning:** Uninstalling deletes every AMACheck transaction record and configuration field from the database. Export your transaction log first if you want to keep a copy.

---

## Troubleshooting

| Problem | Solution |
|---|---|
| Installer says "No Odoo installation detected" | The installer looks for Docker containers named `*odoo*-app` or `odoo*.service` units. If your setup is non-standard, use the manual steps in Option B. |
| Installer can't detect your Odoo version | Pass `--branch 18.0` or `--branch 19.0` explicitly. |
| "License Code is not configured" | Enter license code in Settings → AMACheck and save |
| "Signer is not set" | Open the bank journal and fill in the Signer field |
| "AMAChecks API key is not configured" | Click Refresh Balance in Settings → AMACheck |
| Vendor address errors | Open the vendor record and complete all address fields |
