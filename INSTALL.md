# AMACheck Addon — Installation Guide

## Requirements

- Odoo 18.0 or 19.0 (Community or Enterprise)
  - **Self-hosted:** use the automated installer or the manual steps below
  - **Odoo.sh:** see [Odoo.sh](#odoosh) below — the installer script does not apply
  - **Odoo Online (SaaS):** not supported, because Odoo Online doesn't allow custom modules
- The `account` and `mail` modules (standard Odoo, installed by default)
- An AMAChecks license code and prepaid eChecks (buy eCheck bundles at [amasystems.net/shop](https://www.amasystems.net/shop/echeck-10-pack-33))

---

## Step 1 — Install the Addon

### Option A: Automated installer (recommended)

The installer:

- finds your Odoo
- detects your Odoo version
- downloads the matching AMACheck branch
- puts it in a sensible addons folder
- updates `addons_path` if needed
- installs the module
- checks that the install worked

It asks you to confirm before it changes anything.

Run these two commands on your Odoo server:

```bash
curl -fsSL -o install.sh https://raw.githubusercontent.com/amachecks/account_amacheck/19.0/scripts/install.sh
sudo bash install.sh
```

The installer is the same on the `18.0` and `19.0` branches and detects your Odoo version itself, so either URL works.

**Setups it handles**

| Setup | How it's detected | How the module is installed |
|---|---|---|
| Docker / Podman: the official `odoo` image, docker compose, or a custom image | Any running container that has an Odoo binary inside | `docker exec` into the running container, which uses the container's own network, hosts entries and database settings. The container is then restarted. |
| systemd: deb/rpm package, source checkout, or virtualenv | Any service whose name contains `odoo` or `openerp` | The service is stopped, the module is installed with the service's own Python/Odoo command and user, and the service is started again. |
| Anything else: supervisor, a hosting panel, etc. | — | Run `sudo bash install.sh --addons-dir /path/to/custom/addons`. This places the files only. You then restart Odoo and click Install in Apps. |

**Where the files go**

- If AMACheck is already in one of your addons folders, it's updated there, so you never end up with two copies.
- Otherwise the installer prefers a custom addons folder (for example `/mnt/extra-addons`) over Odoo's core or Enterprise folders.
- For systemd installs with no custom folder, it creates `/opt/odoo-custom-addons` and adds it to `addons_path`.
- Use `--addons-dir` to choose the folder yourself.

**Options:**

```bash
sudo bash install.sh --update             # pull the latest code and upgrade the module
sudo bash install.sh --uninstall          # remove AMACheck from the database
sudo bash install.sh --instance odoo19    # use this container/service (skip the picker)
sudo bash install.sh --db mycompany       # use this database (skip the picker)
sudo bash install.sh --addons-dir DIR     # put the addon in this folder on the server
sudo bash install.sh --config PATH        # Odoo config file, if it isn't found automatically
sudo bash install.sh --branch 19.0        # force a specific Odoo version branch
sudo bash install.sh --no-install         # set up files only; you'll click Install in the UI
sudo bash install.sh --no-restart         # don't restart Odoo at the end
sudo bash install.sh --yes                # don't ask for confirmation (for automation)
sudo bash install.sh --help               # show all options
```

Every run is logged to `/var/log/amacheck-installer.log`. Before the installer replaces or deletes an existing copy of the addon, it saves a backup to `/var/backups/amacheck/`. Before it edits your Odoo config, it saves a backup next to the config as `odoo.conf.bak.<date>`.

When the installer finishes, skip ahead to **Step 2 — Configure AMACheck Settings**.

---

### Option B: Manual install

Use the branch that matches your Odoo version: **`18.0`** for Odoo 18, **`19.0`** for Odoo 19.

**1. Get the code** into a custom addons folder:

```bash
cd /opt/odoo/custom-addons            # your custom addons folder
git clone -b 19.0 https://github.com/amachecks/account_amacheck.git account_amacheck
# (use -b 18.0 if you're on Odoo 18)
```

Or download the ZIP from the [repo](https://github.com/amachecks/account_amacheck). Switch to the matching branch, click **Code → Download ZIP**, extract it, and rename the folder to `account_amacheck`.

> Docker users: put the code in a host folder that is mounted into the container, for example `-v /opt/odoo/extra-addons:/mnt/extra-addons`.

**2. Add the folder to Odoo's addons path**

In your Odoo config file (usually `/etc/odoo/odoo.conf`), make sure the folder is listed. For Docker, list the path *inside* the container:

```ini
addons_path = /opt/odoo/odoo/addons,/opt/odoo/custom-addons
```

**3. Install the module**

*From the command line (recommended):*

```bash
# systemd
sudo systemctl stop odoo
sudo -u odoo /path/to/odoo-bin -c /etc/odoo/odoo.conf -d YOUR_DB -i account_amacheck --stop-after-init --no-http
sudo systemctl start odoo

# Docker: run inside the running container, then restart it
sudo docker exec -it odoo19 odoo -c /etc/odoo/odoo.conf -d YOUR_DB -i account_amacheck --stop-after-init --no-http
sudo docker restart odoo19
```

*Or from the Odoo UI:* restart Odoo, then:

1. Log into Odoo as an Administrator
2. Go to **Settings → Activate Developer Mode** (Settings → General Settings → scroll to bottom)
3. Go to **Apps**
4. Click **Update Apps List**
5. Search for **AMACheck**
6. Click **Install**

---

### Odoo.sh

The installer script doesn't apply to Odoo.sh. Instead:

1. Add the module to your Odoo.sh project's GitHub repository. Either copy the `account_amacheck` folder in, or add it as a git submodule on the `18.0`/`19.0` branch that matches your Odoo version.
2. Push. Odoo.sh rebuilds the branch.
3. In that build, go to **Apps → Update Apps List** and install **AMACheck**.

---

## Step 2 — Configure AMACheck Settings

1. Go to **Settings → AMACheck**
2. Enter your **License Code**
3. Click **Refresh Balance**. This saves the code and shows your eCheck balance and the name the license is registered to.

---

## Step 3 — Configure Your Bank Journal

1. Go to **Accounting → Configuration → Journals**
2. Open your bank journal (e.g. "Bank")
3. Scroll to the **AMACheck Settings** section
4. Fill in the **Signer** field (the name that will appear as the check signer)
5. Set the **Next Check Number** to the number your next check should carry (it goes up by one after each check)
6. Make sure the journal's bank account has an account number, and its bank (**Accounting → Configuration → Banks**) has the 9-digit routing number in **Bank Identifier Code**
7. Save

---

## Step 4 — Send Your First Check

1. Go to **Accounting → Vendors → Payments**
2. Create or open an outbound vendor payment
3. Make sure the vendor has a complete address (Street, City, State, ZIP, Country)
4. Click **Send Check**
5. When it succeeds, the **AMACheck** section on the payment shows Status, Check ID, Check Number, and Sent On

---

## Updating the Addon

**With the installer:**

```bash
sudo bash install.sh --update
```

This pulls the latest code on the branch you're already on, upgrades the module, and restarts Odoo. If you've edited the addon's files locally, those files are backed up to `/var/backups/amacheck/` first.

**Manually:**

```bash
cd /path/to/custom-addons/account_amacheck
git pull
```

Then upgrade it with the same command as in Option B, step 3, using `-u account_amacheck` instead of `-i account_amacheck`. Or go to **Apps → AMACheck → Upgrade** after restarting Odoo.

---

## Uninstalling the Addon

**With the installer:**

```bash
sudo bash install.sh --uninstall
```

This uninstalls the module from your Odoo database, which removes the AMACheck fields it added (check status and number on payments, Signer and Next Check Number on journals) and your saved license code. It then restarts Odoo and asks whether to also delete the addon files from disk. If deleting the files leaves the addons folder empty, the installer also removes that folder from `addons_path`, because Odoo refuses to start with an empty addons folder.

To skip the prompt, add one of:

```bash
sudo bash install.sh --uninstall --remove-files   # also delete the addon folder (a backup is kept)
sudo bash install.sh --uninstall --keep-files     # leave the addon folder on disk
```

**Manually:**

1. In Odoo, go to **Apps**, find **AMACheck**, click the ⋮ menu → **Uninstall**.
2. (Optional) Delete the addon folder. If that leaves the addons folder empty, remove it from `addons_path`.
3. Restart Odoo.

> **Note:** Your check history is kept by AMAChecks, not in Odoo, so uninstalling doesn't delete it. Reinstall and enter the same license code to see it again. Payments in Odoo lose their AMACheck status and check number, so export those first if you need them.

---

## Troubleshooting

| Problem | Solution |
|---|---|
| "No Odoo installation detected" | Make sure Odoo is running (`docker ps` or `systemctl status`). For other setups, use `--addons-dir DIR`, then install from Apps. |
| Container skipped, "no config file I recognise" | Re-run with `--instance NAME --config /path/inside/container/odoo.conf`. |
| "Container has no addons folder mounted" | Add a volume for custom addons (for example `-v /opt/odoo/extra-addons:/mnt/extra-addons`), recreate the container, and re-run. |
| `could not translate host name "host.docker.internal"` | Your Odoo container must be created with `--add-host=host.docker.internal:host-gateway` (compose: `extra_hosts`). Installer v1.1+ runs inside your existing container, so it uses the same settings Odoo already uses. |
| `password authentication failed` / `Connection refused` | Check `db_host`, `db_port`, `db_user`, `db_password` in your Odoo config. |
| Installer can't detect your Odoo version | Pass `--branch 18.0` or `--branch 19.0`. |
| `$'\r': command not found` when running install.sh | The file has Windows line endings. Re-download it with the `curl` command above, or run `sed -i 's/\r$//' install.sh`. |
| Something else went wrong | See `/var/log/amacheck-installer.log` for the full Odoo output. |
| "License Code is not configured" | Enter your license code in Settings → AMACheck and click Refresh Balance. |
| "Signer is not set" | Open the bank journal and fill in the Signer field. |
| "Bank routing number must be 9 digits" | Put the routing number in **Bank Identifier Code** on the bank record (Accounting → Configuration → Banks). |
| "You are out of eChecks" | Buy more from the link in Settings → AMACheck, then click Refresh Balance. |
| Payment shows **Unconfirmed** | The mail service didn't confirm the check, so it may or may not have been mailed. Don't resend it: contact AMA Systems with the reference number shown on the payment. |
| "Could not reach AMAChecks" | It's safe to click Send Check again. AMAChecks never mails the same payment twice. |
| Vendor address errors | Open the vendor record and complete all address fields. |
