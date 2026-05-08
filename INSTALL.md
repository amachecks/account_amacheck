# AMACheck Addon — Installation Guide

## Requirements

- Odoo 19.0
- The `account` and `mail` modules (standard Odoo — installed by default)
- An active AMAChecks license code (purchase at amachecks.com)

---

## Step 1 — Get the Code

**Option A: Git clone (recommended)**
```bash
cd /opt/odoo/addons
git clone -b 19.0 https://github.com/amachecks/account_amacheck.git account_amacheck
```

**Option B: Download ZIP**
1. Go to https://github.com/amachecks/account_amacheck
2. Switch to the **19.0** branch using the branch dropdown
3. Click **Code → Download ZIP**
4. Extract the folder to your Odoo addons directory and rename it `account_amacheck`

---

## Step 2 — Add to Odoo Addons Path

Open your Odoo config file (usually `/etc/odoo/odoo.conf`) and confirm the addons directory is listed:

```ini
addons_path = /opt/odoo/addons
```

If you placed the addon in a different folder, add it:
```ini
addons_path = /opt/odoo/addons,/path/to/your/folder
```

---

## Step 3 — Restart Odoo

```bash
sudo systemctl restart odoo
```

---

## Step 4 — Install the Module

1. Log into Odoo as an Administrator
2. Go to **Settings → Activate Developer Mode** (Settings → General Settings → scroll to bottom)
3. Go to **Apps**
4. Click **Update Apps List**
5. Search for **AMACheck**
6. Click **Install**

---

## Step 5 — Configure AMACheck Settings

1. Go to **Settings → AMACheck**
2. Enter your **License Code**
3. Click **Refresh Balance** — this loads your provider settings and eCheck balance
4. Save

---

## Step 6 — Configure Your Bank Journal

1. Go to **Accounting → Configuration → Journals**
2. Open your bank journal (e.g. "Bank")
3. Scroll to the **AMACheck Settings** section
4. Fill in the **Signer** field (name that will appear as the check signer)
5. If your provider assigns check numbers, set the **Next Check Number**
6. Save

---

## Step 7 — Send Your First Check

1. Go to **Accounting → Vendors → Payments**
2. Create or open an outbound vendor payment
3. Make sure the vendor has a complete address (Street, City, State, ZIP, Country)
4. Click **Send AMACheck**
5. The **AMACheck** section on the payment will show Status, Check ID, Check Number, and Sent On upon success

---

## Updating the Addon

```bash
cd /opt/odoo/addons/account_amacheck
git pull origin 19.0
sudo systemctl restart odoo
```

Then in Odoo:
- Go to **Apps → AMACheck → Upgrade**

---

## Troubleshooting

| Problem | Solution |
|---|---|
| "License Code is not configured" | Enter license code in Settings → AMACheck and save |
| "Signer is not set" | Open the bank journal and fill in the Signer field |
| "AMAChecks API key is not configured" | Click Refresh Balance in Settings → AMACheck |
| Vendor address errors | Open the vendor record and complete all address fields |
