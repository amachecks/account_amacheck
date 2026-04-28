from odoo import models, fields, api
from odoo.exceptions import UserError
from .amacheck_mixin import amacheck_request_json
import json


class AccountPayment(models.Model):
    _inherit = "account.payment"

    amacheck_state = fields.Selection([
        ("ready", "Ready"),
        ("sent", "Sent"),
        ("failed", "Failed"),
    ], string="AMACheck Status")

    amacheck_zil_id = fields.Char(string="AMA Check ID")
    amacheck_sent_at = fields.Datetime(string="AMACheck Sent At")
    amacheck_error = fields.Text(string="AMACheck Error")

    amacheck_journal_id = fields.Many2one(
        "account.journal",
        string="AMACheck Account",
        domain="[('type', '=', 'bank')]",
        copy=False,
    )

    @api.onchange("journal_id")
    def _onchange_amacheck_journal_id(self):
        if self.journal_id and self.journal_id.type == "bank":
            self.amacheck_journal_id = self.journal_id

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

    def _amacheck_payee_payload(self, partner):
        return {
            "name": partner.name,
            "nickName": partner.name,
            "company": partner.commercial_company_name or partner.parent_id.name or partner.name,
            "email": partner.email or "",
            "phone": partner.phone or partner.mobile or "",
            "address1": partner.street or "",
            "address2": partner.street2 or "",
            "city": partner.city or "",
            "state": partner.state_id.code or partner.state_id.name or "",
            "zip": partner.zip or "",
            "country": partner.country_id.code or partner.country_id.name or "",
        }

    def _amacheck_create_payee(self, partner, api_key, base_url):
        payee_url = base_url.rstrip("/") + "/payees"

        payload = {
            "payees": [
                self._amacheck_payee_payload(partner)
            ]
        }

        result = amacheck_request_json(
            payee_url,
            api_key,
            payload,
            method="POST",
        )

        if result.get("success") is False and result.get("payeeId"):
            partner.write({"amacheck_payee_id": result.get("payeeId")})
            return result.get("payeeId")

        payees = result.get("data", {}).get("payees") or result.get("payees") or []

        payee_id = False

        if payees:
            payee_id = (
                payees[0].get("payeeId")
                or payees[0].get("id")
            )

        payee_id = (
            payee_id
            or result.get("data", {}).get("payeeId")
            or result.get("data", {}).get("id")
            or result.get("payeeId")
            or result.get("id")
        )

        if not payee_id:
            raise UserError(
                "Failed to create AMACheck payee.\n\nPayload:\n%s\n\nResponse:\n%s"
                % (
                    json.dumps(payload, indent=2),
                    json.dumps(result, indent=2),
                )
            )

        partner.write({"amacheck_payee_id": payee_id})

        return payee_id

    def _amacheck_update_payee(self, partner, api_key, base_url):
        payee_id = partner.amacheck_payee_id
        payee_url = base_url.rstrip("/") + "/payees/" + payee_id

        payload = self._amacheck_payee_payload(partner)

        result = amacheck_request_json(
            payee_url,
            api_key,
            payload,
            method="PUT",
        )

        if result.get("success") is False:
            raise UserError(
                "Failed to update AMACheck payee.\n\nPayload:\n%s\n\nResponse:\n%s"
                % (
                    json.dumps(payload, indent=2),
                    json.dumps(result, indent=2),
                )
            )

        return result

    def _amacheck_get_or_create_payee_id(self, partner, api_key, base_url):
        self._amacheck_validate_partner(partner)

        if not partner.amacheck_payee_id:
            return self._amacheck_create_payee(partner, api_key, base_url)

        self._amacheck_update_payee(partner, api_key, base_url)

        return partner.amacheck_payee_id

    def _amacheck_get_bank_journal(self):
        self.ensure_one()

        if self.amacheck_journal_id and self.amacheck_journal_id.type == "bank":
            return self.amacheck_journal_id

        if self.journal_id and self.journal_id.type == "bank":
            return self.journal_id

        default_journal = self.env["account.journal"].search([
            ("type", "=", "bank"),
            ("amacheck_is_default", "=", True),
            ("company_id", "=", self.company_id.id),
        ], limit=1)

        if default_journal:
            return default_journal

        raise UserError(
            "No AMACheck bank account is available. "
            "Select a bank journal or mark one bank journal as the default AMACheck account."
        )

    def _amacheck_get_or_create_bank_account_id(self, journal, api_key, base_url):
        if journal.amacheck_bank_account_id:
            return journal.amacheck_bank_account_id

        journal.action_amacheck_sync_bank_account()

        if journal.amacheck_bank_account_id:
            return journal.amacheck_bank_account_id

        raise UserError(
            "Unable to create or locate AMACheck bank account: %s"
            % (journal.amacheck_sync_error or "Unknown error")
        )

    def _amacheck_quickpay_payload(self, payment, bank_account_id, payee_id=None):
        partner = payment.partner_id

        return {
            "source": {
                "accountType": "bankaccount",
                "accountId": bank_account_id,
            },
            "destination": {
                "name": partner.name,
                "company": partner.commercial_company_name or partner.parent_id.name or partner.name,
                "address1": partner.street or "",
                "address2": partner.street2 or "",
                "city": partner.city or "",
                "state": partner.state_id.code or partner.state_id.name or "",
                "zip": partner.zip or "",
                "phone": partner.phone or partner.mobile or "",
                "email": partner.email or "",
                "shippingTypeId": 1,
            },
            "payment_details": {
                "amount": float(payment.amount),
                "memo": payment.name or "Odoo Payment",
                "note": "Created from Odoo AMACheck",
                "issueDate": fields.Date.today().strftime("%Y-%m-%d"),
            },
        }

    def action_send_amacheck(self):
        params = self.env["ir.config_parameter"].sudo()

        api_key = params.get_param("account_amacheck.api_key")
        env = params.get_param("account_amacheck.environment", "sandbox")
        base_url = "https://app.onlinecheckwriter.com/api/v3" if env == "production" else "https://test.onlinecheckwriter.com/api/v3"
        quickpay_url = base_url.rstrip("/") + "/quickpay/mailcheck"

        for payment in self:
            if payment.amacheck_state == "sent" or payment.amacheck_zil_id:
                payment.write({
                    "amacheck_error": "Duplicate send blocked. This payment already has an AMA Check ID.",
                })
                continue

            if not api_key:
                payment.write({
                    "amacheck_state": "failed",
                    "amacheck_error": "AMACheck API key is not configured.",
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

                bank_journal = payment._amacheck_get_bank_journal()

                bank_account_id = payment._amacheck_get_or_create_bank_account_id(
                    bank_journal,
                    api_key,
                    base_url,
                )

                payee_id = payment._amacheck_get_or_create_payee_id(
                    payment.partner_id,
                    api_key,
                    base_url,
                )

                payload = payment._amacheck_quickpay_payload(
                    payment,
                    bank_account_id,
                    payee_id,
                )

                result = amacheck_request_json(
                    quickpay_url,
                    api_key,
                    payload,
                    method="POST",
                )

                if result.get("success") is False:
                    payment.write({
                        "amacheck_state": "failed",
                        "amacheck_error": (
                            "AMACheck check send failed.\n\nPayload:\n%s\n\nResponse:\n%s"
                            % (
                                json.dumps(payload, indent=2),
                                json.dumps(result, indent=2),
                            )
                        ),
                    })
                    continue

                checks = result.get("data", {}).get("checks") or result.get("checks") or []

                check_id = False

                if checks:
                    check_id = (
                        checks[0].get("checkId")
                        or checks[0].get("id")
                    )

                check_id = (
                    check_id
                    or result.get("data", {}).get("checkId")
                    or result.get("data", {}).get("id")
                    or result.get("checkId")
                    or result.get("id")
                    or result.get("data", {}).get("paymentId")
                    or result.get("paymentId")
                )

                if not check_id:
                    payment.write({
                        "amacheck_state": "failed",
                        "amacheck_error": (
                            "AMACheck check was submitted but no check ID was returned.\n\n"
                            "Payload:\n%s\n\nResponse:\n%s"
                            % (
                                json.dumps(payload, indent=2),
                                json.dumps(result, indent=2),
                            )
                        ),
                    })
                    continue

                payment.write({
                    "amacheck_state": "sent",
                    "amacheck_zil_id": check_id,
                    "amacheck_sent_at": fields.Datetime.now(),
                    "amacheck_error": False,
                    "amacheck_journal_id": bank_journal.id,
                })

            except Exception as e:
                payment.write({
                    "amacheck_state": "failed",
                    "amacheck_error": str(e),
                })

        return True
