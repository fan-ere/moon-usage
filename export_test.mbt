///|
fn json_field(value : Json, key : String) -> Json {
  match value {
    Object(fields) => fields.get(key).unwrap()
    _ => abort("Expected JSON object")
  }
}

///|
fn export_plan() -> @moon-usage.Plan {
  {
    currency: "CNY",
    pricing: Graduated,
    rounding: HalfEven,
    per_units: 1,
    base_minor: 0,
    tiers: [{ up_to: None, rate: 8, }],
  }
}

///|
test "counter trace conserves increments and records reset from prior reading" {
  let events : Array[@moon-usage.Event] = [
    { id: "base", account: "a", meter: "m", time: 9, value: 100, },
    { id: "r1", account: "a", meter: "m", time: 11, value: 130, },
    { id: "reset", account: "a", meter: "m", time: 12, value: 4, },
    { id: "r2", account: "a", meter: "m", time: 13, value: 12, },
    { id: "r2", account: "a", meter: "m", time: 13, value: 12, },
  ]
  let u = @moon-usage.aggregate(
    events,
    "a",
    "m",
    10,
    20,
    Counter(RestartAtZero),
  ).unwrap()
  assert_eq(u.counter_deltas, [
    @moon-usage.CounterDelta::{
      event_id: "r1",
      time: 11,
      previous: 100,
      reading: 130,
      delta: 30,
      reset: false,
    },
    {
      event_id: "reset",
      time: 12,
      previous: 130,
      reading: 4,
      delta: 4,
      reset: true,
    },
    {
      event_id: "r2",
      time: 13,
      previous: 4,
      reading: 12,
      delta: 8,
      reset: false,
    },
  ])
  let mut quantity = 0
  let mut resets = 0
  for delta in u.counter_deltas {
    quantity += delta.delta
    if delta.reset {
      resets += 1
    }
  }
  assert_eq(quantity, u.quantity)
  assert_eq(resets, u.reset_events)
  assert_eq(u.counter_deltas.map(fn(d) { d.event_id }), u.event_ids)
  assert_eq(u.duplicate_events, 1)
}

///|
test "zero counter reset and unchanged readings remain visible" {
  let events : Array[@moon-usage.Event] = [
    { id: "base", account: "a", meter: "m", time: 9, value: 100, },
    { id: "same", account: "a", meter: "m", time: 10, value: 100, },
    { id: "zero", account: "a", meter: "m", time: 11, value: 0, },
  ]
  let u = @moon-usage.aggregate(
    events,
    "a",
    "m",
    10,
    20,
    Counter(RestartAtZero),
  ).unwrap()
  assert_eq(u.quantity, 0)
  assert_eq(u.counter_deltas.length(), 2)
  assert_eq(u.counter_deltas[0].reset, false)
  assert_eq(u.counter_deltas[1].reset, true)
  assert_eq(u.reset_events, 1)
}

///|
test "ordinary aggregation excludes history but still validates batch conflicts" {
  let history : Array[@moon-usage.Event] = [
    { id: "old1", account: "a", meter: "m", time: 9, value: 100, },
    { id: "old2", account: "a", meter: "m", time: 9, value: 200, },
    { id: "now", account: "a", meter: "m", time: 10, value: 3, },
  ]
  for mode in [@moon-usage.Aggregation::Sum, Peak, Last] {
    let u = @moon-usage.aggregate(history, "a", "m", 10, 20, mode).unwrap()
    assert_eq(u.quantity, 3)
    assert_eq(u.event_ids, ["now"])
    assert_eq(u.counter_deltas.length(), 0)
    let conflict = history.copy()
    conflict.push({ id: "old1", account: "a", meter: "m", time: 9, value: 101, })
    assert_eq(
      @moon-usage.aggregate(conflict, "a", "m", 10, 20, mode).unwrap_err(),
      @moon-usage.UsageError::DuplicateConflict("old1"),
    )
  }
}

///|
test "JSON export preserves amounts beyond JS safe integer as decimal strings" {
  let p : @moon-usage.Plan = {
    ..export_plan(),
    base_minor: 1000000000,
    tiers: [{ up_to: None, rate: 1000000000, }],
  }
  let events : Array[@moon-usage.Event] = [
    { id: "large", account: "a", meter: "m", time: 1, value: 1000000000, },
  ]
  let b = @moon-usage.bill(events, "a", "m", 0, 2, Sum, p).unwrap()
  let encoded = b.to_json()
  let decoded = @json.parse(encoded.stringify())
  assert_eq(decoded, encoded)
  let quote = json_field(decoded, "quote")
  assert_eq(json_field(quote, "total_minor"), Json("1000000001000000000"))
  assert_eq(json_field(quote, "usage_numerator"), Json("1000000000000000000"))
  assert_eq(json_field(quote, "usage_minor"), Json("1000000000000000000"))
  assert_eq(json_field(quote, "pricing"), Json("graduated"))
  assert_eq(json_field(quote, "rounding"), Json("half_even"))
  assert_eq(json_field(decoded, "schema"), Json("moon-usage.bill.v1"))
}

///|
test "JSON export escapes identifiers and includes empty trace and null baseline" {
  let account = "账户\"\n\\"
  let events : Array[@moon-usage.Event] = [
    { id: "ID\t\"\\", account, meter: "m", time: 1, value: 2, },
  ]
  let b = @moon-usage.bill(events, account, "m", 0, 2, Sum, export_plan()).unwrap()
  let decoded = @json.parse(b.to_json().stringify())
  assert_eq(json_field(decoded, "account"), Json(account))
  let usage = json_field(decoded, "usage")
  assert_eq(json_field(usage, "aggregation"), Json("sum"))
  assert_eq(json_field(usage, "reset_policy"), Json::null())
  assert_eq(json_field(usage, "event_ids"), Json([Json("ID\t\"\\")]))
  assert_eq(json_field(usage, "counter_deltas"), Json::array([]))
  assert_eq(json_field(usage, "baseline_id"), Json::null())
}

///|
test "JSON counter trace exposes evidence and plan policies" {
  let events : Array[@moon-usage.Event] = [
    { id: "base", account: "a", meter: "m", time: 9, value: 100, },
    { id: "reset", account: "a", meter: "m", time: 11, value: 4, },
  ]
  let p : @moon-usage.Plan = { ..export_plan(), pricing: Volume, rounding: Up, }
  let b = @moon-usage.bill(events, "a", "m", 10, 20, Counter(RestartAtZero), p).unwrap()
  let decoded = @json.parse(b.to_json().stringify())
  assert_eq(
    json_field(json_field(decoded, "usage"), "aggregation"),
    Json("counter"),
  )
  assert_eq(
    json_field(json_field(decoded, "usage"), "reset_policy"),
    Json("restart_at_zero"),
  )
  assert_eq(
    json_field(json_field(decoded, "usage"), "counter_deltas"),
    Json([
      Json({
        "event_id": Json("reset"),
        "time": Json(11),
        "previous": Json(100),
        "reading": Json(4),
        "delta": Json(4),
        "reset": Json(true),
      }),
    ]),
  )
  assert_eq(json_field(json_field(decoded, "quote"), "pricing"), Json("volume"))
  assert_eq(json_field(json_field(decoded, "quote"), "rounding"), Json("up"))
}
