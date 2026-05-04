from odoo import models, fields
from odoo.exceptions import ValidationError, UserError
from .amacheck_mixin import amacheck_request_json
import json


class AccountJournal(models.Model):
    _inherit = "account.journal"

    amacheck_bank_account_id = fields.Char(string="Bank Account ID", copy=False)

    amacheck_assign_check_no = fields.Boolean(string="Assign Check Numbers", default=False)
    amacheck_next_check_no = fields.Integer(string="Next Check Number", default=0, copy=False)

    amacheck_sync_state = fields.Selection([
        ("not_synced", "Not Synced"),
        ("synced", "Synced"),
        ("failed", "Failed"),
    ], string="Sync Status", default="not_synced", copy=False)

    amacheck_sync_error = fields.Text(string="Sync Error", copy=False)

    def _amacheck_validate_bank_journal(self):
        self.ensure_one()

        missing = []

        if self.type != "bank":
            missing.append("Journal type must be 'Bank' (currently '%s')" % self.type)

        bank_account = self.bank_account_id

        if not bank_account:
            missing.append(
                "Bank Account — set this on the journal under the 'Bank Account' field "
                "(Accounting > Configuration > Journals > %s)" % self.name
            )
        else:
            if not bank_account.acc_number:
                missing.append(
                    "Account Number — open the bank account '%s' and fill in the Account Number"
                    % (bank_account.display_name or bank_account.id)
                )

            bank = bank_account.bank_id

            if not bank:
                missing.append(
                    "Bank Institution — open bank account '%s', then set the Bank field "
                    "(this holds the routing number and bank address)"
                    % (bank_account.display_name or bank_account.id)
                )
            else:
                if not bank.name:
                    missing.append("Bank Name — set on the bank record '%s'" % bank.id)
                if not bank.bic:
                    missing.append(
                        "Routing Number (BIC) — set on the bank record '%s' "
                        "(Accounting > Configuration > Banks)" % (bank.name or bank.id)
                    )
                if not bank.street:
                    missing.append(
                        "Bank Street Address — set on the bank record '%s'" % (bank.name or bank.id)
                    )
                if not bank.city:
                    missing.append(
                        "Bank City — set on the bank record '%s'" % (bank.name or bank.id)
                    )
                if not bank.zip:
                    missing.append(
                        "Bank ZIP — set on the bank record '%s'" % (bank.name or bank.id)
                    )

        company_partner = self.company_id.partner_id

        if not company_partner.street:
            missing.append(
                "Company Street Address — set on the company '%s' "
                "(Settings > Companies)" % self.company_id.name
            )
        if not company_partner.city:
            missing.append("Company City — set on the company '%s'" % self.company_id.name)
        if not company_partner.state_id:
            missing.append("Company State — set on the company '%s'" % self.company_id.name)
        if not company_partner.zip:
            missing.append("Company ZIP — set on the company '%s'" % self.company_id.name)

        if missing:
            raise ValidationError(
                "Journal '%s' is missing the following required fields for AMACheck:\n\n- %s"
                % (self.name, "\n- ".join(missing))
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
        env = params.get_param("account_amacheck.environment", "production")
        base_url = "https://app.onlinecheckwriter.com/api/v3" if env == "production" else "https://test.onlinecheckwriter.com/api/v3"

        for journal in self:
            try:
                if not api_key:
                    raise UserError("AMACheck API key is not configured.")

                journal._amacheck_validate_bank_journal()

                bank_url = base_url.rstrip("/") + "/bankAccounts"
                payload = journal._amacheck_bank_account_payload()

                result = amacheck_request_json(
                    bank_url,
                    api_key,
                    payload,
                    method="POST",
                )

                # Duplicate case = success
                if result.get("success") is False and result.get("bankAccountId"):
                    journal.write({
                        "amacheck_bank_account_id": result.get("bankAccountId"),
                        "amacheck_sync_state": "synced",
                        "amacheck_sync_error": (
                            "Bank account already existed in AMACheck. "
                            "Saved ID: %s" % result.get("bankAccountId")
                        ),
                    })
                    continue

                # Failure case with no ID
                if result.get("success") is False:
                    journal.write({
                        "amacheck_sync_state": "failed",
                        "amacheck_sync_error": (
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
                        "amacheck_sync_state": "failed",
                        "amacheck_sync_error": json.dumps(result, indent=2),
                    })
                    continue

                journal.write({
                    "amacheck_bank_account_id": bank_account_id,
                    "amacheck_sync_state": "synced",
                    "amacheck_sync_error": False,
                })

            except Exception as e:
                journal.write({
                    "amacheck_sync_state": "failed",
                    "amacheck_sync_error": str(e),
                })

        return True

    def action_amacheck_test_connection(self):
        params = self.env["ir.config_parameter"].sudo()
        api_key = params.get_param("account_amacheck.api_key")

        for journal in self:
            if api_key:
                journal.write({
                    "amacheck_sync_error": "AMACheck API key is configured.",
                })
            else:
                journal.write({
                    "amacheck_sync_state": "failed",
                    "amacheck_sync_error": "AMACheck API key is not configured.",
                })

        return True
