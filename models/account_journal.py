from odoo import models, fields, api
from odoo.exceptions import ValidationError
import json
import urllib.request
import urllib.error


class AccountJournal(models.Model):
    _inherit = "account.journal"

    x_amacheck_bank_account_id = fields.Char(string="AMACheck Bank Account ID", copy=False)
    x_amacheck_is_default = fields.Boolean(string="Default AMACheck Account", copy=False)

    x_amacheck_sync_state = fields.Selection([
        ("not_synced", "Not Synced"),
        ("synced", "Synced"),
        ("failed", "Failed"),
    ], string="AMACheck Sync Status", default="not_synced", copy=False)

    x_amacheck_sync_error = fields.Text(string="AMACheck Sync Error", copy=False)

    @api.constrains("x_amacheck_is_default", "type", "company_id")
    def _check_default_amacheck_account(self):
        for journal in self:
            if not journal.x_amacheck_is_default:
                continue

            if journal.type != "bank":
                raise ValidationError("Only bank journals can be set as the default AMACheck account.")

            existing = self.search([
                ("id", "!=", journal.id),
                ("x_amacheck_is_default", "=", True),
                ("company_id", "=", journal.company_id.id),
            ], limit=1)

            if existing:
                raise ValidationError("Only one default AMACheck account is allowed per company.")

    def _amacheck_request_json(self, url, api_key, payload=None, method="POST"):
        data = json.dumps(payload).encode("utf-8") if payload is not None else None

        req = urllib.request.Request(
            url,
            data=data,
            headers={
                "Authorization": "Bearer " + api_key,
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            method=method,
        )

        try:
            with urllib.request.urlopen(req, timeout=15) as response:
                body = response.read().decode("utf-8")
                return json.loads(body) if body else {}

        except urllib.error.HTTPError as e:
            try:
                error_body = e.read().decode("utf-8")
                return json.loads(error_body) if error_body else {
                    "success": False,
                    "errorMsg": str(e),
                }
            except Exception:
                return {
                    "success": False,
                    "errorMsg": str(e),
                }

    def _amacheck_validate_bank_journal(self):
        self.ensure_one()

        missing = []

        if self.type != "bank":
            missing.append("Journal must be a Bank journal")

        bank_account = self.bank_account_id

        if not bank_account:
            missing.append("Odoo Bank Account")
        else:
            if not bank_account.acc_number:
                missing.append("Bank Account Number")

            bank = bank_account.bank_id

            if not bank:
                missing.append("Bank")
            else:
                if not bank.name:
                    missing.append("Bank Name")
                if not bank.bic:
                    missing.append("Routing Number / BIC")
                if not bank.street:
                    missing.append("Bank Address")
                if not bank.city:
                    missing.append("Bank City")
                if not bank.zip:
                    missing.append("Bank ZIP")

        company_partner = self.company_id.partner_id

        if not company_partner.street:
            missing.append("Company Street Address")
        if not company_partner.city:
            missing.append("Company City")
        if not company_partner.state_id:
            missing.append("Company State")
        if not company_partner.zip:
            missing.append("Company ZIP")

        if missing:
            raise ValidationError(
                "Bank journal is missing required AMACheck bank fields: %s"
                % ", ".join(missing)
            )

    def _amacheck_bank_account_payload(self):
        self.ensure_one()

        company_partner = self.company_id.partner_id
        bank_account = self.bank_account_id
        bank = bank_account.bank_id

        return {
            "bankAccounts": [
                {
                    "name": self.name,
                    "nickName": self.name,
                    "accountNumber": bank_account.acc_number,
                    "addressLine1": company_partner.street or "",
                    "addressLine2": company_partner.street2 or "",
                    "phone": company_partner.phone or company_partner.mobile or "",
                    "city": company_partner.city or "",
                    "state": company_partner.state_id.code or company_partner.state_id.name or "",
                    "zip": company_partner.zip or "",
                    "bankName": bank.name,
                    "bankRoutingNumber": bank.bic,
                    "bankAddress1": bank.street,
                    "bankCity": bank.city,
                    "bankState": company_partner.state_id.code or company_partner.state_id.name or "",
                    "bankZip": bank.zip,
                }
            ]
        }

    def action_amacheck_sync_bank_account(self):
        params = self.env["ir.config_parameter"].sudo()
        api_key = params.get_param("account_amacheck.api_key")
        env = params.get_param("account_amacheck.environment", "sandbox")
        base_url = "https://app.onlinecheckwriter.com/api/v3" if env == "production" else "https://test.onlinecheckwriter.com/api/v3"

        for journal in self:
            try:
                if not api_key:
                    raise Exception("AMACheck API key is not configured.")

                journal._amacheck_validate_bank_journal()

                bank_url = base_url.rstrip("/") + "/bankAccounts"
                payload = journal._amacheck_bank_account_payload()

                result = journal._amacheck_request_json(
                    bank_url,
                    api_key,
                    payload,
                    method="POST",
                )

                # Duplicate case = success
                if result.get("success") is False and result.get("bankAccountId"):
                    journal.write({
                        "x_amacheck_bank_account_id": result.get("bankAccountId"),
                        "x_amacheck_sync_state": "synced",
                        "x_amacheck_sync_error": (
                            "Bank account already existed in AMACheck. "
                            "Saved ID: %s" % result.get("bankAccountId")
                        ),
                    })
                    continue

                # Failure case with no ID
                if result.get("success") is False:
                    journal.write({
                        "x_amacheck_sync_state": "failed",
                        "x_amacheck_sync_error": (
                            "AMACheck bank account sync failed.\n\n"
                            "Payload:\n%s\n\nResponse:\n%s"
                            % (
                                json.dumps(payload, indent=2),
                                json.dumps(result, indent=2),
                            )
                        ),
                    })
                    continue

                bank_accounts = result.get("data", {}).get("bankAccounts") or result.get("bankAccounts") or []

                bank_account_id = False

                if bank_accounts:
                    bank_account_id = (
                        bank_accounts[0].get("bankAccountId")
                        or bank_accounts[0].get("id")
                    )

                bank_account_id = (
                    bank_account_id
                    or result.get("data", {}).get("bankAccountId")
                    or result.get("data", {}).get("id")
                    or result.get("bankAccountId")
                    or result.get("id")
                )

                if not bank_account_id:
                    journal.write({
                        "x_amacheck_sync_state": "failed",
                        "x_amacheck_sync_error": json.dumps(result, indent=2),
                    })
                    continue

                journal.write({
                    "x_amacheck_bank_account_id": bank_account_id,
                    "x_amacheck_sync_state": "synced",
                    "x_amacheck_sync_error": False,
                })

            except Exception as e:
                journal.write({
                    "x_amacheck_sync_state": "failed",
                    "x_amacheck_sync_error": str(e),
                })

        return True

    def action_amacheck_test_connection(self):
        params = self.env["ir.config_parameter"].sudo()
        api_key = params.get_param("account_amacheck.api_key")

        for journal in self:
            if api_key:
                journal.write({
                    "x_amacheck_sync_error": "AMACheck API key is configured.",
                })
            else:
                journal.write({
                    "x_amacheck_sync_state": "failed",
                    "x_amacheck_sync_error": "AMACheck API key is not configured.",
                })

        return True
