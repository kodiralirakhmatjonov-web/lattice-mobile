PRAGMA foreign_keys = ON;

-- Production iumrah client moved from the legacy beta topic to com.iumrah.app.
-- APNs device tokens are app/topic scoped, therefore legacy beta tokens must NOT
-- be relabelled as com.iumrah.app. Disable them and let the production client
-- re-register its current token through the normal registration endpoints.
UPDATE client_push_subscriptions
SET enabled = 0,
    last_error = 'LEGACY_APP_BUNDLE_ID:com.iumrah.beta',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
WHERE app_bundle_id = 'com.iumrah.beta';

UPDATE client_notification_devices
SET enabled = 0,
    last_error = 'LEGACY_APP_BUNDLE_ID:com.iumrah.beta',
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
WHERE app_bundle_id = 'com.iumrah.beta';
