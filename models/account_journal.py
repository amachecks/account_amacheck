from odoo import models, fields
from odoo.exceptions import ValidationError
from .amacheck_mixin import amacheck_get_credentials, amacheck_sync_bank_account, AMACheckLicenseInactiveError


class AccountJournal(models.Model):
    _inherit = "account.journal"

    amacheck_bank_account_id = fields.Char(string="Bank Account ID", copy=False)

    amacheck_sync_state = fields.Selection([
        ("not_synced", "Not Synced"),
        ("synced",     "Synced"),
        ("failed",     "Failed"),
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
        bank_account    = self.bank_account_id
        bank            = bank_account.bank_id

        return {
            "name":              self.name,
            "accountNumber":     bank_account.acc_number,
            "addressLine1":      company_partner.street or "",
            "addressLine2":      company_partner.street2 or "",
            "phone":             company_partner.phone or company_partner.mobile or "",
            "city":              company_partner.city or "",
            "state":             company_partner.state_id.code or company_partner.state_id.name or "",
            "zip":               company_partner.zip or "",
            "bankName":          bank.name,
            "bankRoutingNumber": bank.bic,
            "bankAddress1":      bank.street,
            "bankCity":          bank.city,
            "bankState":         company_partner.state_id.code or company_partner.state_id.name or "",
            "bankZip":           bank.zip,
        }

    def action_amacheck_sync_bank_account(self):
        params        = self.env["ir.config_parameter"].sudo()
        license_code  = params.get_param("account_amacheck.license_code")
        env           = params.get_param("account_amacheck.environment", "production")

        for journal in self:
            try:
                journal._amacheck_validate_bank_journal()
                bank_account_id = amacheck_sync_bank_account(
                    license_code, env, journal._amacheck_bank_account_payload()
                )
                journal.write({
                    "amacheck_bank_account_id": bank_account_id,
                    "amacheck_sync_state":      "synced",
                    "amacheck_sync_error":      False,
                })
            except Exception as e:
                journal.write({
                    "amacheck_sync_state": "failed",
                    "amacheck_sync_error": str(e),
                })

        return True

    def action_amacheck_test_connection(self):
        params       = self.env["ir.config_parameter"].sudo()
        license_code = params.get_param("account_amacheck.license_code")

        for journal in self:
            try:
                _, checks_left = amacheck_get_credentials(license_code)
                journal.write({
                    "amacheck_sync_error": "AMAChecks license is valid. eChecks available: %d" % checks_left,
                })
            except Exception as e:
                journal.write({
                    "amacheck_sync_state": "failed",
                    "amacheck_sync_error": str(e),
                })

        return True
