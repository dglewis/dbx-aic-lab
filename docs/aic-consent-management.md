# Consent management in PingOne Advanced Identity Cloud

What PingOne Advanced Identity Cloud (AIC) provides for consent and user
preferences out of the box, whether it can record where and when a user
opted in or out, and how downstream systems should receive that data.

Researched against Ping's published documentation, October 2026. Not yet
verified in a live AIC tenant; the points to confirm are listed at the end.
Numbers in brackets, such as [1], refer to the [Sources](#sources).

## Summary

- AIC treats consent as part of identity and provisioning. It is not a
  dedicated consent management platform (CMP).
- Out of the box it records *whether* a user consented, plus a date for
  data-sharing consent. It does not record *where* (which page or channel)
  the user opted in or out, and it keeps no history of preference changes.
- Both can be added with a custom user attribute, written by a journey
  script that is told which page the user came from. The method is under
  [Capturing where and when a user opted in or out](#capturing-where-and-when-a-user-opted-in-or-out).
- Downstream systems should receive consent data through an IDM sync
  mapping, not a custom endpoint.

## What AIC provides out of the box

AIC combines Access Management (AM) and Identity Management (IDM). Consent
features sit in three places:

| Layer | What it does | Where it is stored |
|---|---|---|
| AM: OAuth 2.0 / OIDC consent [1] | Asks the user to approve the scopes an application requests. Off by default: clients use implied consent unless configured otherwise. Users revoke an application's access under "Authorized Applications" in the end-user UI. | A "Saved Consent Attribute" the administrator chooses, such as the extension attribute `fr-attr-multi2` |
| AM: journey nodes [3] [5] [6] | The **Consent Collector** node shows one consent notice for each IDM mapping that has Privacy & Consent enabled, typically during registration or progressive profiling. The **Accept Terms and Conditions** and **Terms and Conditions Decision** nodes handle versioned terms and conditions. | Written to the IDM user record |
| IDM: user data model [2] [11] [12] | `consentedMappings` is a list of `{mapping, consentDate}` entries: the downstream systems the user agreed to share data with. A mapping marked `consentRequired: true` [4] syncs only users who consented to it. `preferences` holds user-editable boolean flags; the defaults are `updates` ("Send me news and updates") and `marketing` ("Send me special offers and services"). Preferences can filter which users are reconciled to a target. | User attributes `fr-idm-consentedMapping` and `fr-idm-preferences` |

### How it compares

This comparison is our assessment, not vendor wording.

- **Strength:** consent is enforced where the data actually flows. A
  consent-required mapping does not provision a user to a downstream system
  they have not consented to, and preferences can decide who is synced.
  Ping's Marketo connector example builds a marketing leads list only from
  users who opted in [13].
- **Gap:** dedicated CMPs, such as OneTrust, and Ping's own PingOne consent
  features offer more: purpose and policy-version management, consent
  receipts, a full change history and cookie banners. AIC has none of these
  built in.

### Extending it for finer-grained control

There is no consent plugin. Finer control uses the platform's normal
extension points:

- more preference flags, or custom user attributes (`custom_*`) [2]
- one consent-required mapping per downstream system [4]
- scripted journey nodes that capture consent with extra context [7] [8]
- managed object scripts that react to changes on the user record [9]
- conditional sync scripts (`validSource` / `validTarget`) that read
  preferences [10]

## Capturing where and when a user opted in or out

### What exists today

| Requirement | Out of the box? |
|---|---|
| Timestamp of data-sharing consent | Yes: `consentDate` in each `consentedMappings` entry [11] |
| Current marketing or communication preferences | Yes: booleans in `preferences` [12] |
| Timestamp of a preference change | No |
| Page or channel where the user acted | No |
| History of opt-ins and opt-outs | No |

### The data: a consent event history on the user

Add a custom user attribute [2], for example `custom_consentEvents`, holding
a list with one entry per opt-in or opt-out:

```json
{
  "purpose": "marketing",
  "action": "optOut",
  "timestamp": "2026-10-09T14:02:11Z",
  "source": "checkout-step-3",
  "channel": "web",
  "policyVersion": "v3"
}
```

`preferences` keeps the current state for fast filtering;
`custom_consentEvents` keeps the full history, including where each change
happened.

### Method A (recommended): route every consent change through a journey

AIC cannot work out by itself which page the user was on. Once a journey
starts, the browser is on AIC's own pages, so the `Referer` header no longer
names the application page. The reliable method is for the application to
**say where the user is** when it sends them to AIC.

1. **The application starts the journey with a `source` parameter.** Every
   opt-in or opt-out link or button in the application points at one
   dedicated journey (here called `ConsentUpdate`) and names its own
   location:

   ```text
   https://<tenant>/am/XUI/?realm=alpha&authIndexType=service&authIndexValue=ConsentUpdate&source=checkout-step-3&channel=web
   ```

   Use short, stable identifiers for `source`, such as `checkout-step-3`,
   not full URLs, so reports can group on them.

2. **A Query Parameter node copies the values into the journey state** [7].
   Configure it to map `source` to `consentSource` and `channel` to
   `consentChannel`.

3. **The journey shows the choice and collects the answer**, for example a
   page with the marketing and updates options, or the Consent Collector
   node for data-sharing consent [5].

4. **A Scripted Decision node records the event** [8]. Using the
   next-generation scripting engine, which provides the `openidm` binding
   [8], the script:
   - reads `consentSource` and `consentChannel` from the journey state
     (`nodeState.get(...)`);
   - checks `source` against a list of known page identifiers, and records
     `unknown` otherwise;
   - takes the timestamp on the server, so the user's clock is not trusted;
   - updates `preferences` and appends the event to `custom_consentEvents`
     in one change on the user record (`managed/alpha_user/<id>`).

   ```javascript
   // Scripted Decision node, next-generation engine. Sketch only.
   var KNOWN_SOURCES = ['checkout-step-3', 'account-preferences', 'signup'];
   var source = nodeState.get('consentSource');
   if (KNOWN_SOURCES.indexOf(String(source)) < 0) { source = 'unknown'; }

   var event = {
     purpose: 'marketing',
     action: optedIn ? 'optIn' : 'optOut',   // from the collected answer
     timestamp: new Date().toISOString(),    // server time
     source: source,
     channel: nodeState.get('consentChannel') || 'web',
     policyVersion: 'v3'
   };

   openidm.patch('managed/alpha_user/' + userId, null, [
     { operation: 'replace', field: '/preferences/marketing', value: optedIn },
     { operation: 'add', field: '/custom_consentEvents/-', value: event }
   ]);
   action.goTo('true');
   ```

   `optedIn` and `userId` come from earlier nodes in the journey (the
   collected answer and the identified user); exact variable names depend on
   how the journey is built.

5. **If the application cannot pass a parameter**, the script can fall back
   to the `Referer` header via `requestHeaders.get('referer')` [8], read on
   the journey's first request only. Record it as `channel: 'referer'` so
   reports can tell a weaker source from a declared one.

The `source` value comes from the application, through the user's browser.
It records where the application says the user was; it is not proof. That
is normally enough for consent reporting, and the allowlist in step 4 stops
arbitrary values reaching the record.

### Method B: changes made outside a journey

Some changes do not go through a journey: the user edits preferences on the
hosted end-user UI's profile page, or an application updates the user
record over the IDM REST API. To record these too, add an `onUpdate` script
to the user managed object [9]:

- compare `oldObject.preferences` with `object.preferences`;
- for each flag that changed, append an event with a server timestamp to
  `custom_consentEvents`;
- take `source` from a header the calling application sets, such as
  `X-Consent-Source`, read from the `request` variable [9]; when the header
  is absent, record a fixed value such as `profile-page` (the hosted
  end-user UI does not send one).

The script must skip changes that Method A already recorded, for example by
not adding an event when the same update also appends to
`custom_consentEvents`, so each opt-in or opt-out is recorded once.

## How downstream systems should receive it

| Option | Use when | Notes |
|---|---|---|
| **IDM sync mapping (recommended)** | Reporting, analytics, or any system that needs consent state continuously | Map the user's `preferences`, `consentedMappings` and `custom_consentEvents` to the target, with liveSync or scheduled reconciliation. Consent enforcement [4] and preference filters [10] [12] apply on the same path. |
| REST query of the user record | Occasional, ad-hoc pulls | Query `managed/alpha_user` with `_fields=preferences,consentedMappings,custom_consentEvents`. Polling at scale is weaker than sync. |
| Custom IDM endpoint | A consumer needs a shaped or aggregated view on demand, such as "consent status for user X" | More code to own, and it enforces nothing. |

Sync copies the user's *current* state. If a downstream system needs every
change as its own row, sync the `custom_consentEvents` list and flatten it
in the target, or have the journey script also write each event straight to
the target. The history also grows on the user record, so decide how long
events stay there once they are copied downstream.

## Points to confirm in a tenant

- Whether AIC allows changing the schema of `preferences` itself, or only
  adding `custom_*` attributes.
- Whether a `custom_*` attribute can hold a list of objects, and how it
  appears in sync mappings.
- Where the hosted admin UI exposes `onUpdate` scripts for the user object,
  or whether they must be set over the IDM configuration REST API.
- That the `openidm` binding's `patch` works from a Scripted Decision node
  as sketched above.

## Sources

1. [AIC: Manage OAuth 2.0 consent](https://docs.pingidentity.com/pingoneaic/latest/am-oauth2/oauth2-manage-consent.html)
2. [AIC: User identity attributes reference](https://docs.pingidentity.com/pingoneaic/identities/user-identity-properties-attributes-reference.html)
3. [AIC: Progressive profile](https://docs.pingidentity.com/pingoneaic/latest/self-service/progressive-profile.html)
4. [AIC: Remote proxy sync mappings (`consentRequired`)](https://docs.pingidentity.com/pingoneaic/idm-objects/remote-proxy-create-sync-mappings.html)
5. [Consent Collector node](https://docs.pingidentity.com/auth-node-ref/latest/consent-collector.html)
6. [Terms and Conditions Decision node](https://docs.pingidentity.com/auth-node-ref/latest/terms-and-conditions-decision.md)
7. [Query Parameter node](https://docs.pingidentity.com/auth-node-ref/latest/query-parameter.html)
8. [AIC: Scripted Decision node API](https://docs.pingidentity.com/pingoneaic/latest/am-scripting/scripting-api-node.html)
   and [AIC: Next-generation scripts](https://docs.pingidentity.com/pingoneaic/latest/am-scripting/next-generation-scripts.html)
   (`requestParameters`, `requestHeaders`, `nodeState`, the `openidm` binding)
9. [AIC: Managed object script triggers](https://docs.pingidentity.com/pingoneaic/latest/idm-scripting/script-triggers-managedConfig.html)
   (`onUpdate`, `oldObject`, `request`)
10. [AIC: Scripts in mappings](https://docs.pingidentity.com/pingoneaic/idm-synchronization/scripts-in-mappings.html)
11. [PingIDM 7.5: Privacy and consent](https://docs.pingidentity.com/pingidm/7.5/self-service-reference/privacy-consent.html)
    (self-managed IDM documentation, used for the `consentedMappings`
    schema, which AIC's own pages do not publish)
12. [PingIDM 7.5: End-user preferences](https://docs.pingidentity.com/pingidm/7.5/self-service-reference/enduser-preferences.html)
13. [Marketo connector](https://docs.pingidentity.com/openicf/connector-reference/marketo.html)
