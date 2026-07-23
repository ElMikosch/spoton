# Non-ASCII 3rd-party Home Extra titles are double-encoded (mojibake) in getHomeExtra3rdPartyItems

## Environment

- Material Skin version: 6.4.4 (from `install.xml`)
- Confirmed unchanged on current `master` (`MaterialSkin/Plugin.pm`, `getHomeExtra3rdPartyItems` at line 556 and the `home-extra-3rdparty` handler at line 2049, checked against `https://raw.githubusercontent.com/CDrummond/lms-material/master/MaterialSkin/Plugin.pm`)
- LMS version: 9.2.0
- Reproduced with a German-language LMS server; affects any locale whose translated strings contain non-ASCII characters

## Symptom

A 3rd-party plugin that registers a Home Extra (via `Plugins::MaterialSkin::Plugin->registerHomeExtra` / the `3rdparty_*` mechanism) with a translated `title` or `subtitle` containing non-ASCII characters shows mojibake on the Material Skin home screen instead of the correct text.

Example: the German string "Für dich gemacht" is displayed as "FÃ¼r dich gemacht".

This is reproducible with at least two independent 3rd-party Spotify plugins (Spotty and SpotOn) registering a Home Extra with a German title, so the issue appears to be in Material Skin's own handling rather than in either plugin.

## Root cause (our analysis — based on code reading, not an MS-side debugger trace)

`getHomeExtra3rdPartyItems()` builds its item list from `Slim::Utils::Strings::getString(...)`, which returns Perl character strings (correctly decoded text), and then calls `to_json(...)` on the whole array:

```perl
# MaterialSkin/Plugin.pm, ~line 556
sub getHomeExtra3rdPartyItems {
    return to_json([ map {
        my $item = $HOME_EXTRAS->{$_};
        {
            id          => $_,
            title       => Slim::Utils::Strings::getString($item->{title}),
            subtitle    => Slim::Utils::Strings::getString($item->{subtitle}),
            icon        => $item->{icon},
            needsPlayer => $item->{needsPlayer}
        }
    } keys %$HOME_EXTRAS ]);
}
```

`to_json()` (JSON::XS) UTF-8-encodes its input by default, so the return value here is already a byte string containing UTF-8 octets — it is no longer a Perl character string.

That byte string is then passed straight into `$request->addResult(...)` at the call site:

```perl
# MaterialSkin/Plugin.pm, ~line 2049
if ($cmd eq 'home-extra-3rdparty') {
    $request->addResult("items", getHomeExtra3rdPartyItems());
    $request->setStatusDone();
    return;
}
```

The outer JSON-RPC / CometD response path serializes the whole result structure to JSON again for transport. Because the `items` value is already a UTF-8 byte string rather than a decoded character string, that second encoding pass treats each UTF-8 byte as if it were a separate Latin-1 character and re-encodes it — producing the classic double-encoding mojibake ("Für" → "FÃ¼r").

We believe this only manifests for the `3rdparty_*` Home Extra path, since `getHomeExtra3rdPartyItems()` appears to be the only place that pre-serializes its payload with `to_json()` before handing it to `addResult()`; built-in (non-3rd-party) Home Extras seem to pass plain character strings through `addResult()` and are serialized once, which would explain why this is scoped to 3rd-party registrations. We have not traced every code path that constructs the outer response, so please treat this framing as a hypothesis rather than a confirmed fact — you know the response serialization path far better than we do.

## Suggested fix

A couple of options that would restore single-encoding:

1. Decode the `to_json()` output back to a Perl character string before returning it, e.g. `Encode::decode('UTF-8', to_json([...]))`, so it participates correctly in the outer serialization pass.
2. Simpler: don't pre-serialize at all — have `getHomeExtra3rdPartyItems()` return the plain Perl array/hashref data structure (as built by the `map`), and let `addResult()` / the outer JSON-RPC response serializer handle JSON encoding once, the same way other result fields are handled.

We'd lean towards option 2 since it avoids the double-serialization altogether, but we don't know if calling code elsewhere depends on `getHomeExtra3rdPartyItems()` returning an already-serialized JSON string (e.g. if it's also called directly by a template rather than only through `addResult()`), so we're flagging both as a starting point rather than prescribing which is correct for this codebase.

Happy to help test a fix against SpotOn's Home Extra registration if useful.

---
Filed as: https://github.com/CDrummond/lms-material/issues/1243 (2026-07-23)
