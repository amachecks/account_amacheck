from odoo import models, fields
from odoo.exceptions import UserError
from .amacheck_mixin import amacheck_get_credentials, amacheck_send_check, AMACheckLicenseInactiveError


class AccountPayment(models.Model):
    _inherit = "account.payment"

    amacheck_state = fields.Selection([
        ("ready",  "Ready"),
        ("sent",   "Sent"),
        ("failed", "Failed"),
    ], string="Status")

    amacheck_zil_id        = fields.Char(string="Check ID")
    amacheck_check_number  = fields.Char(string="Check Number", copy=False)
    amacheck_sent_at       = fields.Datetime(string="Sent On")
    amacheck_error         = fields.Text(string="Errors")
    amacheck_inactive      = fields.Boolean(string="License Inactive", default=False, copy=False)

    def _amacheck_validate_partner(self, partner):
        missing = []

        if not partner.name:
            missing.append("Vendor Name")
        if not partner.street:
            missing.append("Street Address")
        if not partner.city:
            missing.append("City")
        if not partner.state_id:
            missing.append("State")
        if not partner.zip:
            missing.append("ZIP")
        if not partner.country_id:
            missing.append("Country")

        if missing:
            raise UserError(
                "Vendor '%s' is missing required fields for AMACheck: %s"
                % (partner.name or "(no name)", ", ".join(missing))
            )

    def _amacheck_vendor_payload(self, partner):
        return {
            "name":    partner.name,
            "company": partner.commercial_company_name or partner.parent_id.name or partner.name,
            "email":   partner.email or "",
            "phone":   partner.phone or partner.mobile or "",
            "address1": partner.street or "",
            "address2": partner.street2 or "",
            "city":    partner.city or "",
            "state":   partner.state_id.code or partner.state_id.name or "",
            "zip":     partner.zip or "",
            "country": partner.country_id.code or partner.country_id.name or "",
        }

    def _amacheck_get_bank_journal(self):
        self.ensure_one()

        if self.journal_id and self.journal_id.type == "bank":
            return self.journal_id

        raise UserError(
            "Payment '%s' must use a Bank journal to send via AMACheck. "
            "Change the journal on this payment to a bank account journal."
            % (self.name or self.id)
        )

    def _amacheck_get_or_create_bank_account_id(self, journal):
        if journal.amacheck_bank_account_id:
            return journal.amacheck_bank_account_id

        journal.action_amacheck_sync_bank_account()

        if journal.amacheck_bank_account_id:
            return journal.amacheck_bank_account_id

        raise UserError(
            "Unable to create or locate AMACheck bank account: %s"
            % (journal.amacheck_sync_message or "Unknown error")
        )

    def action_send_amacheck(self):
        params       = self.env["ir.config_parameter"].sudo()
        license_code = params.get_param("account_amacheck.license_code")
        env          = params.get_param("account_amacheck.environment", "production")

        try:
            _, checks_left = amacheck_get_credentials(license_code)
        except AMACheckLicenseInactiveError:
            for payment in self:
                payment.write({
                    "amacheck_state":    "failed",
                    "amacheck_inactive": True,
                    "amacheck_error":    False,
                })
            return True
        except Exception as e:
            for payment in self:
                payment.write({
                    "amacheck_state":    "failed",
                    "amacheck_inactive": False,
                    "amacheck_error":    str(e),
                })
            return True

        if checks_left <= 0:
            for payment in self:
                payment.write({
                    "amacheck_state":    "failed",
                    "amacheck_inactive": False,
                    "amacheck_error": (
                        "You are out of eChecks. "
                        "Please go to Settings / AMACheck to purchase more."
                    ),
                })
            return True

        for payment in self:
            if payment.amacheck_state == "sent" or payment.amacheck_zil_id:
                payment.write({
                    "amacheck_error": "Duplicate send blocked. This payment already has an AMA Check ID.",
                })
                continue

            if payment.payment_type != "outbound":
                payment.write({
                    "amacheck_state": "failed",
                    "amacheck_error": "AMACheck only supports outbound payments.",
                })
                continue

            if payment.partner_type != "supplier":
                payment.write({
                    "amacheck_state": "failed",
                    "amacheck_error": "AMACheck only supports vendor payments.",
                })
                continue

            if payment.amount <= 0:
                payment.write({
                    "amacheck_state": "failed",
                    "amacheck_error": "Payment amount must be greater than zero.",
                })
                continue

            if not payment.partner_id:
                payment.write({
                    "amacheck_state": "failed",
                    "amacheck_error": "Payment is missing a vendor.",
                })
                continue

            try:
                payment._amacheck_validate_partner(payment.partner_id)

                bank_journal    = payment._amacheck_get_bank_journal()
                bank_account_id = payment._amacheck_get_or_create_bank_account_id(bank_journal)
                partner         = payment.partner_id

                result = amacheck_send_check(
                    license_code  = license_code,
                    environment   = env,
                    bank_account_id = bank_account_id,
                    payee_id      = partner.amacheck_payee_id or None,
                    amount        = float(payment.amount),
                    memo          = payment.name or "Odoo Payment",
                    vendor        = payment._amacheck_vendor_payload(partner),
                )

                if result.get("payeeId") and result["payeeId"] != partner.amacheck_payee_id:
                    partner.write({"amacheck_payee_id": result["payeeId"]})

                payment.write({
                    "amacheck_state":        "sent",
                    "amacheck_zil_id":       result["checkId"],
                    "amacheck_check_number": result.get("checkNumber") or False,
                    "amacheck_sent_at":      fields.Datetime.now(),
                    "amacheck_error":        False,
                    "amacheck_inactive":     False,
                })

                if result.get("checksLeft") is not None:
                    self.env["ir.config_parameter"].sudo().set_param(
                        "account_amacheck.checks_left", str(result["checksLeft"])
                    )

            except Exception as e:
                payment.write({
                    "amacheck_state":    "failed",
                    "amacheck_inactive": False,
                    "amacheck_error":    str(e),
                })

        return True
