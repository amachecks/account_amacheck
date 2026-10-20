"""1.2.0: AMAChecks now sends checks server-side. Remove the shared API key,
the Checkeeper key and Online Check Writer settings stored by older versions."""

LEGACY_PARAMS = (
    "account_amacheck.license_api_key",
    "account_amacheck.checkeeper_api_key",
    "account_amacheck.active_provider",
    "account_amacheck.assign_check_no",
    "account_amacheck.provider_name",
    "account_amacheck.is_ocw",
)


def migrate(cr, version):
    cr.execute("DELETE FROM ir_config_parameter WHERE key IN %s", (LEGACY_PARAMS,))
