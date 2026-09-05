#!/usr/bin/env python3
"""Unit tests for normalise(): the usage endpoint's body → the cache record.

Run:  python3 tests/test_normalise.py      (exit 0 = pass; no dependencies)

normalise() is the one function in usage.py that knows the shape of the
endpoint's response, and the endpoint is undocumented. Its shape moved under
ccgauge once already — the model-scoped weekly window left the top-level
`seven_day_opus` key (now null) for a row in a `limits` array — and nothing
said so, because `show` printed the Opus row only when the key had a value.
The function had no coverage; the drift stayed silent for months.

FULL_BODY is a real response, captured 2026-09-04, verbatim. It pins the shape
as it is today. The cases after it pin the fallbacks — the legacy shape, a
body with both, and the ways a body can be malformed — so a change in either
direction fails here first, not on a status line.
"""
import importlib.util
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
USAGE = HERE.parent / "usage.py"


def load_usage():
    """Import usage.py as a module without running main()."""
    spec = importlib.util.spec_from_file_location("ccgauge_usage", USAGE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


u = load_usage()
failures = []


def check(label, got, want):
    if got != want:
        failures.append(f"{label}\n     got:  {got!r}\n     want: {want!r}")


def norm(body):
    """normalise() minus the clock, so records compare as plain values."""
    out = u.normalise(body)
    check("fetched_at is a number", isinstance(out.pop("fetched_at"), (int, float)), True)
    return out


S_RESET = "2026-09-05T01:39:59.764689+00:00"
W_RESET = "2026-09-06T21:59:59.764710+00:00"
F_RESET = "2026-09-06T21:59:59.764930+00:00"

# The endpoint's body on 2026-09-04, on a Max 5x plan. Note what it says about
# the legacy keys: `five_hour` and `seven_day` are still populated (and agree
# with the array), while every model-scoped legacy key is null — the scoped
# weekly limit exists only as the `weekly_scoped` row, labelled by the payload.
FULL_BODY = {
    "amber_ladder": None,
    "cinder_cove": None,
    "copper_kite": None,
    "extra_usage": {
        "credits_ever_enabled": True, "currency": None, "daily": None,
        "decimal_places": None, "disabled_reason": None, "is_enabled": False,
        "monthly_limit": None, "spend_limit_reached": False,
        "used_credits": None, "user_disabled": True, "utilization": None,
        "weekly": None,
    },
    "five_hour": {
        "limit_dollars": None, "locked_reason": None, "remaining_dollars": None,
        "resets_at": S_RESET, "used_dollars": None, "utilization": 16.0,
    },
    "iguana_necktie": None,
    "juniper_tide": None,
    "limits": [
        {"group": "session", "is_active": True, "kind": "session", "percent": 16,
         "resets_at": S_RESET, "scope": None, "severity": "normal"},
        {"group": "weekly", "is_active": False, "kind": "weekly_all", "percent": 2,
         "resets_at": W_RESET, "scope": None, "severity": "normal"},
        {"group": "weekly", "is_active": False, "kind": "weekly_scoped", "percent": 3,
         "resets_at": F_RESET,
         "scope": {"model": {"display_name": "Fable", "id": None}, "surface": None},
         "severity": "normal"},
    ],
    "member_dashboard_available": False,
    "nimbus_quill": {
        "limit_dollars": None, "locked_reason": None, "remaining_dollars": None,
        "resets_at": None, "used_dollars": None, "utilization": 0.0,
    },
    "omelette_promotional": None,
    "seven_day": {
        "limit_dollars": None, "locked_reason": None, "remaining_dollars": None,
        "resets_at": W_RESET, "used_dollars": None, "utilization": 2.0,
    },
    "seven_day_cowork": None,
    "seven_day_oauth_apps": None,
    "seven_day_omelette": None,
    "seven_day_opus": None,
    "seven_day_sonnet": None,
    "spend": {
        "auto_reload": None, "balance": None, "can_purchase_credits": False,
        "can_toggle": False, "cap": None, "disabled_reason": None,
        "disclaimer": "Usage credits cover you when you hit your plan limits.",
        "enabled": False, "limit": None, "percent": 0, "severity": "normal",
        "used": {"amount_minor": 0, "currency": "USD", "exponent": 2},
    },
    "tangelo": None,
}

# --- the shape as it is today -------------------------------------------------
# The Fable row at 3% is the tightest weekly limit, so it is the 7d headline;
# the all-models row at 2% is still there for `show`. `nimbus_quill` (0%) and
# the codenamed nulls are ignored: only `limits` rows and the legacy windows
# count, and the legacy windows only when the array has nothing for them.
check("today's body", norm(FULL_BODY), {
    "five_hour_pct": 16, "five_hour_reset": S_RESET,
    "seven_day_pct": 3, "seven_day_reset": F_RESET, "seven_day_scope": "Fable",
    "weekly": [{"label": None, "pct": 2, "reset": W_RESET},
               {"label": "Fable", "pct": 3, "reset": F_RESET}],
})
check("hook tag names the scope and the all-models figure",
      u._scope_tag(norm(FULL_BODY)), " [Fable; all models 2%]")

# --- the legacy shape ---------------------------------------------------------
# What the endpoint returned when ccgauge was written: one object per window,
# the scoped one without a reset. The same tightest-wins rule applies, and the
# scoped row borrows the all-models reset so its countdown still draws.
LEGACY = {
    "five_hour": {"utilization": 11.0, "resets_at": "5h"},
    "seven_day": {"utilization": 30.0, "resets_at": "7d"},
    "seven_day_opus": {"utilization": 40.0},
}
check("legacy body", norm(LEGACY), {
    "five_hour_pct": 11, "five_hour_reset": "5h",
    "seven_day_pct": 40, "seven_day_reset": "7d", "seven_day_scope": "Opus",
    "weekly": [{"label": None, "pct": 30, "reset": "7d"},
               {"label": "Opus", "pct": 40, "reset": "7d"}],
})
check("legacy sonnet window is a row too",
      norm({"seven_day": {"utilization": 1}, "seven_day_sonnet": {"utilization": 9}})["weekly"],
      [{"label": None, "pct": 1, "reset": None}, {"label": "Sonnet", "pct": 9, "reset": None}])
check("no tag for the all-models reading",
      u._scope_tag(norm({"seven_day": {"utilization": 50}, "seven_day_opus": {"utilization": 20}})), "")

# --- both shapes at once -----------------------------------------------------
# Per window the array wins outright: the legacy `seven_day_opus` at 40% must
# not be merged in beside the array's weekly rows, or the body counts twice.
BOTH = dict(LEGACY, limits=[
    {"kind": "session", "group": "session", "percent": 5, "resets_at": "s"},
    {"kind": "weekly_all", "group": "weekly", "percent": 7, "resets_at": "w"},
])
check("array wins over legacy", norm(BOTH), {
    "five_hour_pct": 5, "five_hour_reset": "s",
    "seven_day_pct": 7, "seven_day_reset": "w", "seven_day_scope": None,
    "weekly": [{"label": None, "pct": 7, "reset": "w"}],
})
check("legacy fills a window the array lacks", norm({
    "five_hour": {"utilization": 9, "resets_at": "s"},
    "limits": [{"kind": "weekly_all", "group": "weekly", "percent": 1, "resets_at": "w"}],
})["five_hour_pct"], 9)


# --- which weekly limit is the headline --------------------------------------
def weekly(*rows):
    return norm({"limits": list(rows)})


def scoped(percent, scope, kind="weekly_scoped", reset="w"):
    return {"kind": kind, "group": "weekly", "percent": percent, "resets_at": reset,
            "scope": scope}


ALL = {"kind": "weekly_all", "group": "weekly", "percent": 5, "resets_at": "w"}
FABLE = {"model": {"display_name": "Fable", "id": None}, "surface": None}

r = weekly(scoped(5, FABLE), ALL)
check("tie keeps the all-models reading", r["seven_day_scope"], None)
check("all-models row leads whatever the payload order",
      [row["label"] for row in r["weekly"]], [None, "Fable"])
check("scoped ahead by one wins", weekly(ALL, scoped(6, FABLE))["seven_day_scope"], "Fable")
r = weekly(ALL, scoped(9, {"model": {"display_name": "Opus 5"}}),
           scoped(4, {"model": {"display_name": "Sonnet 5"}}))
check("highest of several scoped rows",
      (r["seven_day_pct"], r["seven_day_scope"]), (9, "Opus 5"))
check("every row is kept for show", [row["label"] for row in r["weekly"]],
      [None, "Opus 5", "Sonnet 5"])
check("scoped row alone is the headline", weekly(scoped(8, FABLE))["seven_day_scope"], "Fable")


# --- labels come from the payload --------------------------------------------
def label_of(row):
    return weekly(row)["weekly"][0]["label"]


check("model display name", label_of(scoped(1, {"model": {"display_name": "  Fable "}})), "Fable")
check("surface when there is no model",
      label_of(scoped(1, {"model": {"display_name": None}, "surface": "Cowork"})), "Cowork")
check("surface as an object",
      label_of(scoped(1, {"model": None, "surface": {"display_name": "Cowork"}})), "Cowork")
check("unfamiliar kind falls back to the kind",
      label_of(scoped(1, None, kind="weekly_cowork")), "cowork")
check("scoped with nothing to name it", label_of(scoped(1, None)), "scoped")
check("scoped with an empty scope", label_of(scoped(1, {})), "scoped")

# --- malformed bodies never raise, and never invent a reading -----------------
EMPTY = {"five_hour_pct": None, "five_hour_reset": None, "seven_day_pct": None,
         "seven_day_reset": None, "seven_day_scope": None, "weekly": []}
check("empty body", norm({}), EMPTY)
check("body not a dict", norm(None), EMPTY)
check("body a string", norm("not json"), EMPTY)
check("limits not a list falls back to legacy",
      norm({"limits": {"kind": "session"}, "five_hour": {"utilization": 3}})["five_hour_pct"], 3)
check("non-dict rows are skipped",
      norm({"limits": [None, "x", 3, [], {"kind": "session", "percent": 4}]})["five_hour_pct"], 4)
check("row without a usable percent is dropped",
      norm({"limits": [{"kind": "weekly_all", "percent": "abc"},
                       {"kind": "weekly_all", "percent": None},
                       scoped(6, FABLE)]})["weekly"],
      [{"label": "Fable", "pct": 6, "reset": "w"}])
check("nan percent is no reading",
      norm({"limits": [{"kind": "session", "percent": float("nan")}]})["five_hour_pct"], None)
check("legacy window not a dict", norm({"five_hour": "16%"})["five_hour_pct"], None)
check("legacy utilization not a number",
      norm({"seven_day": {"utilization": "lots"}})["seven_day_pct"], None)
check("rows told apart by kind, not position",
      norm({"limits": [ALL, {"kind": "session", "percent": 12, "resets_at": "s"}]})["five_hour_pct"], 12)
check("group alone identifies a session row",
      norm({"limits": [{"group": "session", "percent": 2}]})["five_hour_pct"], 2)

# --- rounding: half away from zero, like the bar -------------------------------
check("2.5 rounds up", u._round_pct(2.5), 3)
check("3.5 rounds up", u._round_pct(3.5), 4)
check("2.49 rounds down", u._round_pct(2.49), 2)
check("a numeric string", u._round_pct("16.0"), 16)
check("infinity is no reading", u._round_pct(float("inf")), None)
check("None is no reading", u._round_pct(None), None)
check("legacy utilization rounds the same way", u._pct({"utilization": 2.5}), 3)
check("array percent rounds the same way",
      norm({"limits": [{"kind": "session", "percent": 2.5}]})["five_hour_pct"], 3)

if failures:
    print(f"FAILED ({len(failures)}):", file=sys.stderr)
    for f in failures:
        print("  - " + f, file=sys.stderr)
    sys.exit(1)
print("normalise: all checks passed")
