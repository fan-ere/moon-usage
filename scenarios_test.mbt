///|
test "API requests full billing workflow with retry and three tiers" {
  let events : Array[@moon-usage.Event] = [
    { id: "a", account: "api", meter: "requests", time: 11, value: 6000, },
    { id: "b", account: "api", meter: "requests", time: 15, value: 6500, },
    { id: "a", account: "api", meter: "requests", time: 11, value: 6000, },
  ]
  let p : @moon-usage.Plan = {
    currency: "CNY",
    pricing: Graduated,
    rounding: HalfEven,
    per_units: 1000,
    base_minor: 100,
    tiers: [
      { up_to: Some(1000), rate: 0, },
      { up_to: Some(10000), rate: 300, },
      { up_to: None, rate: 200, },
    ],
  }
  let b = @moon-usage.bill(events, "api", "requests", 10, 20, Sum, p).unwrap()
  assert_eq(b.usage.quantity, 12500)
  assert_eq(b.usage.duplicate_events, 1)
  assert_eq(b.quote.total_minor, 3300L)
  assert_eq(b.quote.lines.map(fn(line) { line.quantity }), [1000, 9000, 2500])
  assert_eq(b.quote.usage_numerator, 3200000L)
}

///|
test "storage snapshots full billing workflow uses peak and volume" {
  let events : Array[@moon-usage.Event] = [
    { id: "s1", account: "storage", meter: "capacity", time: 11, value: 80, },
    { id: "s2", account: "storage", meter: "capacity", time: 12, value: 120, },
    { id: "s3", account: "storage", meter: "capacity", time: 13, value: 90, },
  ]
  let p : @moon-usage.Plan = {
    currency: "CNY",
    pricing: Volume,
    rounding: Up,
    per_units: 1,
    base_minor: 0,
    tiers: [{ up_to: Some(100), rate: 5, }, { up_to: None, rate: 3, }],
  }
  let b = @moon-usage.bill(events, "storage", "capacity", 10, 20, Peak, p).unwrap()
  assert_eq(b.usage.quantity, 120)
  assert_eq(b.quote.total_minor, 360L)
  assert_eq(b.quote.lines.length(), 1)
  assert_eq(b.quote.lines[0].tier, 1)
}

///|
test "device cumulative readings full workflow has reset evidence" {
  let events : Array[@moon-usage.Event] = [
    {
      id: "baseline",
      account: "device",
      meter: "counter",
      time: 9,
      value: 1000,
    },
    { id: "d1", account: "device", meter: "counter", time: 11, value: 1030, },
    { id: "reset", account: "device", meter: "counter", time: 12, value: 4, },
    { id: "d2", account: "device", meter: "counter", time: 14, value: 12, },
  ]
  let p : @moon-usage.Plan = {
    currency: "CNY",
    pricing: Graduated,
    rounding: HalfEven,
    per_units: 1,
    base_minor: 0,
    tiers: [{ up_to: None, rate: 8, }],
  }
  let b = @moon-usage.bill(
    events,
    "device",
    "counter",
    10,
    20,
    Counter(RestartAtZero),
    p,
  ).unwrap()
  assert_eq(b.usage.quantity, 42)
  assert_eq(b.usage.baseline_id, Some("baseline"))
  assert_eq(b.usage.reset_events, 1)
  assert_eq(b.quote.total_minor, 336L)
  assert_eq(
    @moon-usage.bill(
      events,
      "device",
      "counter",
      10,
      20,
      Counter(RejectDecrease),
      p,
    ).unwrap_err(),
    @moon-usage.UsageError::CounterDecreased("reset"),
  )
}
